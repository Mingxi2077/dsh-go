import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../ui/plugins/islands/island_platform.dart';
import '../ui/web/web_file_chooser.dart';
import '../ui/web/web_view_guard.dart';
import 'browser_content.dart';
import 'browser_downloads.dart';
import 'browser_models.dart';
import 'browser_navigation.dart';
import 'browser_policy.dart';
import 'browser_visuals.dart';

export 'browser_models.dart' show BrowserPageContent;

/// One external web document. Never installs a JavaScript channel or the DSH
/// web bridges. The UI removes WebViewWidget before disposing this controller.
class BrowserPageController extends ChangeNotifier implements BrowserDocument {
  BrowserPageController({required Uri initialUrl, required this.onPageChanged}) : _url = initialUrl {
    if (!BrowserPolicy.allows(initialUrl)) throw const FormatException('blocked_url');
    webView = WebViewController(onPermissionRequest: (request) => unawaited(request.deny()));
    _guard = WebViewGuard(
      onGone: (_) {
        // Keep observing renderer loss while a disposed view awaits its save.
        _navigation?.invalidate();
        if (_disposed) return;
        _revision++;
        rendererGone = true;
        loading = false;
        error = 'renderer_gone';
        _files.invalidate();
        notifyListeners();
      },
    );
  }

  final void Function(Uri url, String title) onPageChanged;
  void Function(BrowserDownloadRequest request)? onDownloadRequested;
  final _downloads = BrowserDownloadPlatform.instance;
  int? _downloadViewId;
  late final WebViewController webView;
  late final WebViewGuard _guard;
  final _files = WebFileChooser();
  Uri _url;
  Uri get url => _url;
  String title = '';
  bool loading = true;
  int progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;
  bool rendererGone = false;
  String? error;
  bool _disposed = false;
  int _revision = 0;
  int _previewRequest = 0;
  int _iconRequest = 0;
  Future<void>? _initializing;
  BrowserNavigationLease? _navigation;
  bool _restoring = false;
  bool _awaitingStart = true;
  bool _loadFinished = false;
  bool _movingHistory = false;
  Uri? _startedUrl;
  @override
  int get revision => _revision;
  @override
  bool get ready =>
      !_disposed &&
      !rendererGone &&
      !_restoring &&
      !_awaitingStart &&
      _loadFinished &&
      !loading &&
      error == null &&
      (_navigation?.current ?? true);

  /// Ordinary workspace tabs only. Call before initialize; constructor/factory
  /// callers that omit this retain their original load-and-destroy behavior.
  void configureNavigation(String tabId) {
    if (_disposed || _initializing != null) throw StateError('navigation_already_initialized');
    _navigation ??= BrowserNavigation.instance.bind(tabId);
  }

  Future<void> initialize({required bool dark, int textZoom = 100}) =>
      _initializing ??= _initialize(dark: dark, textZoom: textZoom);

  Future<void> _initialize({required bool dark, required int textZoom}) async {
    if (_disposed) return;
    try {
      await webView.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (_disposed) return;
      await webView.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (_disposed || rendererGone) return NavigationDecision.prevent;
            final target = Uri.tryParse(request.url);
            if (target == null || !BrowserPolicy.allows(target)) {
              if (request.isMainFrame) _failure('blocked_url');
              return NavigationDecision.prevent;
            }
            if (request.isMainFrame) {
              final fragmentOnly = target.removeFragment() == _url.removeFragment() && target.fragment != _url.fragment;
              _begin(target, waitingForStart: true);
              _movingHistory = fragmentOnly;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (raw) {
            if (_disposed || rendererGone) return;
            final target = Uri.tryParse(raw);
            if (target == null || !BrowserPolicy.allows(target)) {
              unawaited(webView.runJavaScript('window.stop()').catchError((Object _) {}));
              _failure('blocked_url');
            } else {
              _begin(target);
              _startedUrl = target;
            }
          },
          onProgress: (value) {
            if (_disposed || rendererGone) return;
            progress = value;
            notifyListeners();
          },
          onUrlChange: (change) {
            if (_disposed || rendererGone) return;
            final target = Uri.tryParse(change.url ?? '');
            if (target == null || !BrowserPolicy.allows(target)) {
              _failure('blocked_url');
              return;
            }
            // Also retire reads on same-URL pushState/popstate: history may
            // have changed even when the displayed address did not.
            _revision++;
            _files.invalidate();
            _url = target;
            // A same-document history traversal has no onPageStarted or
            // onPageFinished. Its new URL plus document.readyState completes
            // it; a full navigation still waits for the document to finish.
            if (_movingHistory) {
              _awaitingStart = false;
              _loadFinished = true;
              _movingHistory = false;
            }
            _report();
            unawaited(_refreshMetadata());
          },
          onPageFinished: (raw) => unawaited(_finished(raw)),
          onWebResourceError: (failure) {
            if (failure.url != null && failure.url != _url.toString()) return;
            if (failure.isForMainFrame ?? true) _failure('load_failed');
          },
          onHttpAuthRequest: (request) => request.onCancel(),
          onSslAuthError: (error) => error.cancel(),
        ),
      );
      if (_disposed) return;
      await _files.attach(webView);
      if (_disposed) return;
      await _guard.attach(webView, dark: dark, textZoom: textZoom);
      if (_disposed) return;
      final downloadId = WebViewGuard.identifierOf(webView);
      if (downloadId != null) {
        _downloadViewId = downloadId;
        await _downloads.attach(downloadId, (request) => unawaited(_downloadOffered(request)));
      }
      // dispose may already have queued release waiting for _initializing.
      // Do not enqueue restore behind that release: return first, with no
      // asynchronous gap between this check and the restore enqueue below.
      if (_disposed) return;
      final navigation = _navigation;
      final id = WebViewGuard.identifierOf(webView);
      if (navigation != null && id != null) {
        _restoring = true;
        // This is a fresh WebView: a restored page may finish without a start
        // callback. It still needs its own finish plus readyState and URL checks.
        _awaitingStart = false;
        final restored = await navigation.restore(id, _url, isAlive: () => !_disposed && !rendererGone);
        _restoring = false;
        if (_disposed || rendererGone || !navigation.current) return;
        if (restored) {
          await _refreshMetadata();
          return; // loadRequest here would overwrite POST/SPA history.
        }
      }
      if (!_disposed) await load(_url);
    } on Object {
      _failure('load_failed');
    }
  }

  void _begin(Uri target, {bool waitingForStart = false}) {
    if (_disposed || rendererGone) return;
    _revision++;
    _files.invalidate();
    _url = target;
    _awaitingStart = waitingForStart;
    _loadFinished = false;
    _movingHistory = false;
    title = '';
    loading = true;
    progress = 0;
    error = null;
    _report();
  }

  Future<void> _downloadOffered(BrowserDownloadRequest request) async {
    final generation = _revision;
    bool current() => !_disposed && !rendererGone && generation == _revision;
    if (current() && loading && request.url == _url) {
      // Attachment responses never commit a document or send onPageFinished.
      // End the page spinner and restore the document WebView actually kept.
      // A blank/attachment-only view remains unavailable for quoting.
      loading = false;
      progress = 0;
      _awaitingStart = true;
      _loadFinished = false;
      notifyListeners();
      try {
        final actual = Uri.tryParse(await webView.currentUrl() ?? '');
        if (current() && actual != null && actual != request.url && BrowserPolicy.allows(actual)) {
          final state = await webView.runJavaScriptReturningResult('document.readyState');
          if (current() && (state == 'complete' || state == '"complete"')) {
            _url = actual;
            _awaitingStart = false;
            _loadFinished = true;
            await _refreshMetadata();
          }
        }
      } on Object {
        // Download consent remains usable even when document metadata is gone.
      }
    }
    if (current() && onDownloadRequested != null) {
      onDownloadRequested!(request);
    } else {
      await _downloads.callNative<void>('reject', {'id': request.id}).catchError((Object _) {});
    }
  }

  Future<void> _finished(String raw) async {
    if (_disposed || rendererGone || _awaitingStart) return;
    if (raw != _url.toString() && raw != _startedUrl?.toString()) return;
    if (error != null) {
      await _refreshHistory();
      return;
    }
    _loadFinished = true;
    await _refreshMetadata();
  }

  Future<void> _refreshMetadata() async {
    if (_disposed || rendererGone) return;
    if (error != null) {
      await _refreshHistory();
      return;
    }
    final generation = _revision;
    bool current() => !_disposed && !rendererGone && generation == _revision && error == null;
    try {
      final actual = await webView.currentUrl();
      if (!current() || actual != _url.toString()) return;
      final pageTitle = await webView.getTitle();
      if (!current()) return;
      final back = await webView.canGoBack();
      if (!current()) return;
      final forward = await webView.canGoForward();
      if (!current()) return;
      final documentState = _loadFinished ? await webView.runJavaScriptReturningResult('document.readyState') : null;
      if (!current()) return;
      title = cleanBrowserTitle(pageTitle ?? '');
      canGoBack = back;
      canGoForward = forward;
      if (_loadFinished && !_awaitingStart && (documentState == 'complete' || documentState == '"complete"')) {
        loading = false;
        progress = 100;
      }
      _report();
    } on Object {
      if (current()) _failure('load_failed');
    }
  }

  /// Failed documents still occupy native history. Keep Back/Forward usable
  /// without making the failed document ready for extraction or clearing its
  /// error. A new navigation or renderer loss retires these asynchronous reads.
  Future<void> _refreshHistory() async {
    if (_disposed || rendererGone) return;
    final generation = _revision;
    final expectedUrl = _url;
    bool current() => !_disposed && !rendererGone && generation == _revision;
    try {
      final actual = await webView.currentUrl();
      if (!current() || actual != expectedUrl.toString()) return;
      final back = await webView.canGoBack();
      if (!current()) return;
      final forward = await webView.canGoForward();
      if (!current()) return;
      canGoBack = back;
      canGoForward = forward;
      notifyListeners();
    } on Object {
      // Preserve the original load error if its renderer cannot answer.
    }
  }

  void _report() {
    if (_disposed || !(_navigation?.current ?? true)) return;
    onPageChanged(_url, title);
    notifyListeners();
  }

  void _failure(String code) {
    if (_disposed || rendererGone) return;
    error = code;
    loading = false;
    _revision++;
    _files.invalidate();
    notifyListeners();
    unawaited(_refreshHistory());
  }

  Future<void> load(Uri uri) async {
    if (!BrowserPolicy.allows(uri)) throw const FormatException('blocked_url');
    if (_disposed || rendererGone) throw StateError('renderer_gone');
    final fragmentOnly = uri.removeFragment() == _url.removeFragment() && uri.fragment != _url.fragment;
    _begin(uri, waitingForStart: true);
    _movingHistory = fragmentOnly;
    final generation = _revision;
    try {
      await webView.loadRequest(uri);
    } on Object {
      if (generation == _revision) _failure('load_failed');
    }
  }

  Future<void> _move(Future<void> Function() action, {bool history = false}) async {
    if (_disposed || rendererGone) return;
    _revision++;
    final generation = _revision;
    _awaitingStart = true;
    _loadFinished = false;
    _movingHistory = history;
    _files.invalidate();
    error = null;
    loading = true;
    progress = 0;
    notifyListeners();
    try {
      await action();
    } on Object {
      if (generation == _revision) _failure('load_failed');
    }
  }

  Future<void> back() async {
    if (canGoBack) await _move(webView.goBack, history: true);
  }

  Future<void> forward() async {
    if (canGoForward) await _move(webView.goForward, history: true);
  }

  Future<void> reload() => _move(webView.reload);

  /// Only the currently loaded document may supply a thumbnail or favicon.
  /// A navigation, close, or renderer loss retires any pending native result.
  Future<Uint8List?> _visual({int? width}) async {
    if (!ready) return null;
    // Newer captures win even within the same document (e.g. after scrolling).
    // Icons and previews have independent sequences so they can run together.
    final request = width == null ? ++_iconRequest : ++_previewRequest;
    final generation = _revision;
    final expectedUrl = _url;
    final id = WebViewGuard.identifierOf(webView);
    if (id == null) return null;
    try {
      final platform = BrowserVisualPlatform.instance;
      final bytes =
          await (width == null
                  ? platform.icon(id, expectedUrl)
                  : platform.capture(id, expectedUrl, width.clamp(160, 600)))
              .timeout(const Duration(milliseconds: 900));
      if (!ready || generation != _revision || expectedUrl != _url) return null;
      if (request != (width == null ? _iconRequest : _previewRequest)) return null;
      return bytes != null && bytes.isNotEmpty && bytes.length <= BrowserVisualPlatform.maxBytes ? bytes : null;
    } on Object {
      return null;
    }
  }

  Future<Uint8List?> capturePreview({int width = 420}) => _visual(width: width);
  Future<Uint8List?> siteIcon() => _visual();

  Future<BrowserPageContent> extract({bool selection = false}) => BrowserContentReader.read(this, selection: selection);
  Future<void> appearance({required bool dark, required int textZoom}) async {
    if (_disposed || rendererGone) return;
    await _guard.setDark(dark);
    if (!_disposed) await _guard.setTextZoom(textZoom);
  }

  @override
  Future<String?> currentUrl() => webView.currentUrl();
  @override
  Future<Object> runJavaScriptReturningResult(String script) => webView.runJavaScriptReturningResult(script);

  Future<void> _destroyAfterInitialization() async {
    // A pending attach must finish before destruction; otherwise it could
    // register a client/listener on an already-destroyed view. Also destroy a
    // view disposed before guard.attach, when the guard does not yet know its id.
    try {
      await _initializing;
      final downloadId = _downloadViewId;
      _downloadViewId = null;
      if (downloadId != null) await _downloads.detach(downloadId);
      _guard.dispose();
      final id = WebViewGuard.identifierOf(webView);
      if (id != null) await IslandPlatform.instance.destroy(id);
    } on Object {
      // The native renderer may already have removed this view.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    final save = ready;
    _disposed = true;
    onDownloadRequested = null;
    _revision++;
    _files.dispose();
    final navigation = _navigation;
    if (navigation == null) {
      _guard.dispose();
      unawaited(_destroyAfterInitialization());
    } else {
      unawaited(
        navigation.release(
          initialized: _initializing ?? Future.value(),
          identifier: () => WebViewGuard.identifierOf(webView),
          expectedUrl: _url,
          save: save,
          destroy: _destroyAfterInitialization,
        ),
      );
    }
    super.dispose();
  }
}
