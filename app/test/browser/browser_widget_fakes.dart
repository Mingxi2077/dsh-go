// Fakes for the 网页 widget tests: a page that a test drives by hand (no
// platform WebView) and storage in memory.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/browser/browser_library.dart' show browserLibraryStorageProvider;
import 'package:dsh_app/browser/browser_page_controller.dart';
import 'package:dsh_app/browser/browser_downloads.dart';
import 'package:dsh_app/browser/browser_site_icons.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/ui/browser/browser_entry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

class FakeBrowserPage extends ChangeNotifier implements BrowserPageController {
  FakeBrowserPage({required Uri initialUrl, required this.onPageChanged}) : _url = initialUrl;

  @override
  final void Function(Uri url, String title) onPageChanged;
  @override
  void Function(BrowserDownloadRequest)? onDownloadRequested;

  Uri _url;
  @override
  Uri get url => _url;
  @override
  String title = '';
  @override
  bool loading = true;
  @override
  int progress = 0;
  @override
  bool canGoBack = false;
  @override
  bool canGoForward = false;
  @override
  bool rendererGone = false;
  @override
  String? error;
  @override
  bool get ready => !disposed && !rendererGone && !loading && error == null;

  /// Bumped by every navigation, as the real page's document revision.
  @override
  int revision = 0;

  bool disposed = false;
  bool initialized = false;
  bool finishDuringInitialization = false;
  final loads = <Uri>[];
  final extracts = <bool>[];
  int backs = 0;
  int reloads = 0;

  /// What the next extract gives (or throws): by `selection`.
  final results = <bool, FutureOr<BrowserPageContent> Function()>{};

  /// The page finished loading [title] (as onPageFinished does).
  void finish({String title = 'Example Domain', Uri? at}) {
    if (at != null) _url = at;
    this.title = title;
    loading = false;
    progress = 100;
    onPageChanged(_url, title);
    notifyListeners();
  }

  /// A notification with nothing changed (a progress tick, a title echo).
  void ping() => notifyListeners();

  /// A navigation started to [to].
  void navigate(Uri to) {
    revision++;
    _url = to;
    loading = true;
    title = '';
    onPageChanged(to, '');
    notifyListeners();
  }

  @override
  Future<void> initialize({required bool dark, int textZoom = 100}) async {
    initialized = true;
    if (finishDuringInitialization) finish();
  }

  @override
  void configureNavigation(String tabId) {
    // Fake implementation: just record that it was called
  }

  @override
  Future<void> load(Uri uri) async {
    loads.add(uri);
    navigate(uri);
  }

  @override
  Future<void> back() async => backs++;
  @override
  Future<void> forward() async {}
  @override
  Future<void> reload() async => reloads++;

  @override
  Future<BrowserPageContent> extract({bool selection = false}) async {
    extracts.add(selection);
    final result = results[selection];
    if (result == null) throw StateError(selection ? 'empty_selection' : 'empty_page');
    return result();
  }

  /// What the next snapshot gives (null: none), or a pending one to finish
  /// by hand; every capture asked for.
  Uint8List? preview;
  Completer<Uint8List?>? pendingPreview;
  int captures = 0;

  @override
  Future<Uint8List?> capturePreview({int width = 420}) async {
    captures++;
    final pending = pendingPreview;
    if (pending != null) return pending.future;
    return ready ? preview : null;
  }

  @override
  Future<Uint8List?> siteIcon() async {
    iconRequests++;
    final pending = pendingIcon;
    if (pending != null) return pending.future;
    return ready ? icon : null;
  }

  /// The favicon the page's WebView loaded (null: none yet), or a pending
  /// read to finish by hand; every read asked for.
  Uint8List? icon;
  Completer<Uint8List?>? pendingIcon;
  int iconRequests = 0;

  /// Every text zoom the page was given after it was made.
  final zooms = <int>[];

  @override
  Future<void> appearance({required bool dark, required int textZoom}) async => zooms.add(textZoom);

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemoryBrowserStorage implements BrowserStorage {
  MemoryBrowserStorage([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String raw) async => value = raw;
}

/// Pages made so far, newest last.
class FakePages {
  FakePages({this.finishDuringInitialization = false});
  final bool finishDuringInitialization;
  final made = <FakeBrowserPage>[];
  FakeBrowserPage get last => made.last;

  /// What was shared and opened in the system browser.
  final shared = <Uri>[];
  final external = <Uri>[];

  /// Favicons by host, and what pages handed the icon store.
  final icons = <String, Uint8List>{};
  late final siteIcons = FakeSiteIcons(icons);

  List<Override> overrides({MemoryBrowserStorage? storage, MemoryBrowserStorage? library}) => [
    browserStorageProvider.overrideWithValue(storage ?? MemoryBrowserStorage()),
    browserLibraryStorageProvider.overrideWithValue(library ?? MemoryBrowserStorage()),
    browserShareProvider.overrideWithValue((url, title) async => shared.add(url)),
    browserExternalOpenProvider.overrideWithValue((url) async => external.add(url)),
    browserPageFactoryProvider.overrideWithValue(({required initialUrl, required onPageChanged}) {
      final page = FakeBrowserPage(initialUrl: initialUrl, onPageChanged: onPageChanged);
      page.finishDuringInitialization = finishDuringInitialization;
      made.add(page);
      return page;
    }),
    // No favicon lookups leave a test; [icons] answers by site origin.
    browserSiteIconsProvider.overrideWithValue(siteIcons),
    browserViewBuilderProvider.overrideWithValue(
      (context, page) => const SizedBox.expand(key: ValueKey('fake-browser-view')),
    ),
  ];
}

BrowserPageContent pageContent({bool selection = false, String text = '第一段\n第二段', bool truncated = false}) =>
    BrowserPageContent(
      url: Uri.parse('https://example.com/docs'),
      title: 'Example Domain',
      text: text,
      selection: selection,
      truncated: truncated,
    );

/// The icon store without network or decoding: [icons] by host; remember
/// keeps bytes only while the caller's isCurrent still holds.
class FakeSiteIcons extends BrowserSiteIcons {
  FakeSiteIcons(this.icons) : super(fetch: (icon) async => icons[icon.host]);
  final Map<String, Uint8List> icons;
  final remembered = <Uri>[];
  int refusedAsStale = 0;

  @override
  Future<Uint8List?> load(Uri page) async => icons[page.host];

  @override
  Future<bool> remember(Uri page, Uint8List bytes, {bool Function()? isCurrent}) async {
    if (!(isCurrent?.call() ?? true)) {
      refusedAsStale++;
      return false;
    }
    remembered.add(page);
    icons[page.host] = bytes;
    return true;
  }
}
