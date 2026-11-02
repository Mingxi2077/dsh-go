import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../ui/plugins/islands/island_platform.dart';
import '../ui/web/web_view_guard.dart';
import 'browser_links.dart';
import 'browser_policy.dart';

/// URL checks only: no WebView, storage, networking, or credential exchange.
abstract final class BrowserAuthPolicy {
  static const maxUrlChars = 8192;
  static final _unsafe = RegExp(r'[\x00-\x20\x7f\\]');
  static final _callback = RegExp(r'^http://127\.0\.0\.1:([1-9][0-9]{0,4})/oauth/callback(?:\?[^#]*)?$');
  static final _forumCallback = RegExp(r'^dshgo://forum/auth\?payload=[^&#]+$');

  static bool allows(Uri url) => url.scheme == 'https' && !url.authority.contains('@') && BrowserPolicy.allows(url);

  static Uri? publicUrl(String raw) {
    if (raw.length > maxUrlChars || _unsafe.hasMatch(raw)) return null;
    // Uri parsing drops an empty userinfo marker; reject it before parsing.
    if (RegExp(r'^https://[^/?#]*@', caseSensitive: false).hasMatch(raw)) return null;
    final url = Uri.tryParse(raw);
    return url != null && allows(url) ? url : null;
  }

  /// The raw spelling is checked before Uri normalizes paths/escapes. A
  /// callback is never a permitted WebView URL, including in a subframe.
  static Uri? callback(BrowserAuthorization request, String raw, {required bool isMainFrame}) {
    if (!isMainFrame || !request.isCurrent() || raw.length > maxUrlChars || _unsafe.hasMatch(raw)) return null;
    final match = _callback.firstMatch(raw);
    if (match == null) return null;
    try {
      final origin = request.callbackOrigin;
      final port = int.parse(match.group(1)!);
      if (origin == null ||
          origin.scheme != 'http' ||
          origin.host != '127.0.0.1' ||
          origin.authority.contains('@') ||
          origin.hasQuery ||
          origin.hasFragment ||
          (origin.path.isNotEmpty && origin.path != '/') ||
          port < 1 ||
          port > 65535 ||
          origin.port != port) {
        return null;
      }
      final url = Uri.parse(raw);
      final expected = request.url.queryParametersAll['state'];
      if (expected != null) {
        final actual = url.queryParametersAll['state'];
        if (expected.length != 1 || actual == null || actual.length != 1 || actual.single != expected.single) {
          return null;
        }
      }
      // DeepSeek's authorize_id flow does not disclose state here. The engine
      // alone validates its callback state, PKCE, and authorization result.
      return url;
    } on FormatException {
      return null;
    }
  }

  /// This capability belongs only to a forum authorization producer. Check
  /// the original string: Uri would normalize scheme/host case and dot paths.
  static Uri? forumCallback(BrowserAuthorization request, String raw, {required bool isMainFrame}) {
    if (request.onForumRedirect == null || !isMainFrame || !request.isCurrent()) return null;
    return parseForumCallback(raw);
  }

  static Uri? parseForumCallback(String raw) {
    if (raw.length > maxUrlChars || _unsafe.hasMatch(raw)) return null;
    final match = _forumCallback.firstMatch(raw);
    if (match == null || match.end != raw.length || RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(raw)) return null;
    try {
      final uri = Uri.parse(raw);
      final payloads = uri.queryParametersAll['payload'];
      if (uri.queryParametersAll.length != 1 ||
          payloads == null ||
          payloads.length != 1 ||
          payloads.single.trim().isEmpty) {
        return null;
      }
      return uri;
    } on FormatException {
      return null;
    }
  }
}

/// A temporary authorization WebView, with no browser document/storage API.
///
/// The owner must remove WebViewWidget before calling dispose (for example,
/// after the frame removing it). Native destruction also waits for an in-flight
/// initialization/guard attachment. Completion stops work but does not destroy
/// a view still mounted by the owner, nor does this controller call cancel.
class BrowserAuthController extends ChangeNotifier {
  BrowserAuthController(
    this.request, {
    @visibleForTesting HttpClient Function()? createHttpClient,
    @visibleForTesting BrowserLinkHandler? externalOpen,
    @visibleForTesting Duration callbackTimeout = const Duration(seconds: 15),
  }) : _createHttpClient = createHttpClient ?? HttpClient.new,
       _externalOpen = externalOpen ?? BrowserLinks.external,
       _callbackTimeout = callbackTimeout,
       _currentUrl = request.url {
    if (!BrowserAuthPolicy.allows(request.url)) throw const FormatException('blocked_url');
    if (callbackTimeout <= Duration.zero) throw ArgumentError('invalid_callback_timeout');
    _webView = WebViewController(onPermissionRequest: (permission) => unawaited(_deny(permission)));
    _guard = WebViewGuard(onGone: (_) => _rendererLost());
    // Register immediately, including when initialize is never called.
    unawaited(request.completed.then<void>((_) => _end(), onError: (Object _, StackTrace _) => _end(failed: true)));
  }

  final BrowserAuthorization request;
  final HttpClient Function() _createHttpClient;
  final BrowserLinkHandler _externalOpen;
  final Duration _callbackTimeout;
  late final WebViewController _webView;
  late final WebViewGuard _guard;

  WebViewController get webView => _webView;
  bool get loading => _loading;
  int get progress => _progress;
  String? get error => _error;

  /// Last public HTTPS document; never the intercepted loopback callback.
  Uri get currentUrl => _currentUrl;

  /// Callback delivery or waiting for request.completed after delivery.
  /// HTTP success alone is not proof of successful authorization.
  bool get finishing => _finishing;

  bool _loading = true;
  int _progress = 0;
  String? _error;
  Uri _currentUrl;
  bool _finishing = false;
  bool _disposed = false;
  bool _ended = false;
  bool _rendererGone = false;
  bool _configured = false;
  bool _awaitingStart = true;
  int _revision = 0;
  HttpClient? _callbackClient;
  Object? _forumCallback;
  Future<void>? _initializing;
  Future<void>? _stopping;

  bool _checkCurrent() {
    if (_disposed || _ended) return false;
    if (!request.isCurrent()) {
      _end();
      return false;
    }
    return true;
  }

  bool get _canBrowse => _checkCurrent() && !_rendererGone && !_finishing;

  Future<void> initialize({required bool dark}) => _initializing ??= _initialize(dark: dark);

  Future<void> _initialize({required bool dark}) async {
    if (!_canBrowse) return;
    try {
      await webView.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!_canBrowse) return;
      await webView.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _navigate,
          onPageStarted: _started,
          onPageFinished: _finished,
          onUrlChange: (change) => _urlChanged(change.url),
          onProgress: (value) {
            if (!_canBrowse || !_loading || _error != null) return;
            _progress = value.clamp(0, 100);
            notifyListeners();
          },
          onWebResourceError: (failure) {
            if (!_canBrowse || failure.isForMainFrame == false) return;
            if (failure.url != null && failure.url != _currentUrl.toString()) return;
            _failure('load_failed');
          },
          onHttpAuthRequest: (auth) => auth.onCancel(),
          onSslAuthError: (ssl) => unawaited(ssl.cancel().catchError((Object _) {})),
        ),
      );
      if (!_canBrowse) return;
      final platform = webView.platform;
      if (platform is AndroidWebViewController) {
        await platform.setMixedContentMode(MixedContentMode.neverAllow);
        if (!_canBrowse) return;
        await platform.setAllowFileAccess(false);
        if (!_canBrowse) return;
        await platform.setAllowContentAccess(false);
        if (!_canBrowse) return;
        await platform.setGeolocationEnabled(false);
        if (!_canBrowse) return;
        await platform.setOnShowFileSelector((_) async => const <String>[]);
        if (!_canBrowse) return;
      }
      await _guard.attach(webView, dark: dark, textZoom: 100);
      if (!_canBrowse) return;
      _configured = true;
      await _loadOriginal();
    } on Object {
      _failure('load_failed');
    }
  }

  static Future<void> _deny(WebViewPermissionRequest permission) async {
    try {
      await permission.deny();
    } on Object {
      // Denial may race a native view being removed.
    }
  }

  NavigationDecision _navigate(NavigationRequest navigation) {
    if (!_canBrowse) return NavigationDecision.prevent;
    final forum = BrowserAuthPolicy.forumCallback(request, navigation.url, isMainFrame: navigation.isMainFrame);
    if (forum != null) {
      unawaited(_forwardForumCallback(forum));
      return NavigationDecision.prevent;
    }
    final callback = BrowserAuthPolicy.callback(request, navigation.url, isMainFrame: navigation.isMainFrame);
    if (callback != null) {
      unawaited(_forwardCallback(callback));
      return NavigationDecision.prevent;
    }
    final target = BrowserAuthPolicy.publicUrl(navigation.url);
    if (target == null) {
      if (navigation.isMainFrame) _failure('blocked_url');
      return NavigationDecision.prevent;
    }
    if (navigation.isMainFrame) _begin(target);
    // A listener can synchronously close or replace the authorization.
    return _canBrowse ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  void _begin(Uri target) {
    if (!_canBrowse) return;
    _revision++;
    _currentUrl = target;
    _awaitingStart = true;
    _loading = true;
    _progress = 0;
    _error = null;
    notifyListeners();
  }

  void _started(String raw) {
    if (!_canBrowse) return;
    final target = BrowserAuthPolicy.publicUrl(raw);
    if (target == null) {
      unawaited(_stopDocument());
      _failure('blocked_url');
      return;
    }
    _begin(target);
    _awaitingStart = false;
  }

  void _urlChanged(String? raw) {
    if (!_canBrowse) return;
    final target = BrowserAuthPolicy.publicUrl(raw ?? '');
    if (target == null) {
      unawaited(_stopDocument());
      _failure('blocked_url');
      return;
    }
    _currentUrl = target;
    notifyListeners();
  }

  void _finished(String raw) {
    if (!_canBrowse || _awaitingStart || _error != null || raw != _currentUrl.toString()) return;
    _loading = false;
    _progress = 100;
    notifyListeners();
  }

  void _failure(String code) {
    if (!_checkCurrent() || _rendererGone || _finishing) return;
    _error = code;
    _loading = false;
    notifyListeners();
  }

  Future<void> _forwardForumCallback(Uri callback) async {
    final handler = request.onForumRedirect;
    if (handler == null || !_canBrowse) return;
    final operation = _forumCallback = Object();
    bool active() => _checkCurrent() && !_rendererGone && identical(_forumCallback, operation);
    _finishing = true;
    _loading = false;
    _error = null;
    notifyListeners();
    try {
      if (!active()) return;
      final accepted = await handler(callback).timeout(_callbackTimeout);
      if (!active()) return;
      if (!accepted) {
        _forumCallback = null;
        _callbackFailed('callback_failed');
      }
      // The producer owns nonce/RSA verification and account success. Even
      // when accepted, wait for request.completed before ending this surface.
    } on TimeoutException {
      if (active()) {
        _forumCallback = null;
        _callbackFailed('callback_timeout');
      }
    } on Object {
      if (active()) {
        _forumCallback = null;
        _callbackFailed('callback_failed');
      }
    } finally {
      if (identical(_forumCallback, operation)) _forumCallback = null;
    }
  }

  Future<void> _forwardCallback(Uri callback) async {
    if (!_canBrowse) return;
    _finishing = true;
    _loading = false;
    _error = null;
    notifyListeners();
    HttpClient? client;
    try {
      if (!_checkCurrent()) return;
      client = _createHttpClient();
      _callbackClient = client;
      client.connectionTimeout = _callbackTimeout;
      client.findProxy = (_) => 'DIRECT';
      client.authenticate = (_, _, _) async => false;
      client.authenticateProxy = (_, _, _, _) async => false;
      bool active() => _checkCurrent() && !_rendererGone && identical(_callbackClient, client);
      await _deliver(client, callback, active).timeout(_callbackTimeout);
      if (!active()) return;
      // Stay finishing until the engine's completion signal. Do not retain
      // the code/state URL or infer success by executing its response body.
    } on TimeoutException {
      _callbackFailed('callback_timeout');
    } on Object {
      _callbackFailed('callback_failed');
    } finally {
      client?.close(force: true);
      if (identical(_callbackClient, client)) _callbackClient = null;
    }
  }

  Future<void> _deliver(HttpClient client, Uri callback, bool Function() active) async {
    if (!active()) return;
    final outgoing = await client.getUrl(callback);
    if (!active()) {
      outgoing.abort();
      return;
    }
    outgoing.followRedirects = false;
    outgoing.maxRedirects = 0;
    outgoing.persistentConnection = false;
    // This is a fresh client, unrelated to the app client and WebView cookies.
    for (final name in [
      HttpHeaders.authorizationHeader,
      HttpHeaders.proxyAuthorizationHeader,
      HttpHeaders.cookieHeader,
    ]) {
      outgoing.headers.removeAll(name);
    }
    final response = await outgoing.close();
    if (!active()) return;
    await response.drain<void>();
    if (!active()) return;
    if (response.statusCode < 200 || response.statusCode >= 400) throw const HttpException('callback_failed');
  }

  void _callbackFailed(String code) {
    if (!_checkCurrent() || _rendererGone) return;
    _finishing = false;
    _failure(code);
  }

  Future<void> _loadOriginal() async {
    if (!_canBrowse) return;
    _begin(request.url);
    final revision = _revision;
    if (!_canBrowse) return;
    try {
      await webView.loadRequest(request.url);
      if (!_checkCurrent()) return;
    } on Object {
      if (_canBrowse && revision == _revision) _failure('load_failed');
    }
  }

  /// Restart the original authorization URL; never reload a callback/token URL.
  Future<void> reload() async {
    if (!_canBrowse) return;
    await _initializing;
    if (!_canBrowse || !_configured) return;
    await _loadOriginal();
  }

  /// Explicit user fallback. Keeps the system's original WebView user agent.
  Future<bool> openExternal() async {
    if (!_checkCurrent()) return false;
    try {
      final opened = await _externalOpen(request.url);
      if (!_checkCurrent()) return false;
      if (!opened) _failure('external_open_failed');
      return opened;
    } on Object {
      _failure('external_open_failed');
      return false;
    }
  }

  Future<void> _stopDocument() async {
    if (_disposed || _rendererGone) return;
    try {
      await webView.runJavaScript('window.stop();');
    } on Object {
      // No scripts supplied by the page and no response HTML is executed.
    }
  }

  Future<void> _stopActivity() async {
    await _stopDocument();
    if (_disposed || _rendererGone) return;
    try {
      await webView.setJavaScriptMode(JavaScriptMode.disabled);
    } on Object {
      // The platform may already have removed the document.
    }
  }

  void _end({bool failed = false}) {
    if (_disposed || _ended) return;
    _ended = true;
    _forumCallback = null;
    _revision++;
    _callbackClient?.close(force: true);
    _callbackClient = null;
    _finishing = false;
    _loading = false;
    if (failed) _error = 'authorization_failed';
    _stopping = _stopActivity();
    notifyListeners();
  }

  void _rendererLost() {
    if (!_checkCurrent() || _rendererGone) return;
    _rendererGone = true;
    _forumCallback = null;
    _callbackClient?.close(force: true);
    _callbackClient = null;
    _finishing = false;
    _loading = false;
    _error = 'renderer_gone';
    notifyListeners();
  }

  Future<void> _destroyAfterInitialization() async {
    try {
      await _initializing;
      await _stopping;
      _guard.dispose();
      final id = WebViewGuard.identifierOf(webView);
      if (id != null) await IslandPlatform.instance.destroy(id);
    } on Object {
      // A lost renderer may already have removed this native view.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _forumCallback = null;
    _revision++;
    _callbackClient?.close(force: true);
    _callbackClient = null;
    _guard.dispose();
    unawaited(_destroyAfterInitialization());
    super.dispose();
  }
}
