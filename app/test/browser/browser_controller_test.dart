// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dsh_app/browser/browser_downloads.dart';
import 'package:dsh_app/browser/browser_page_controller.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../web/support/fake_webview.dart';

class BrowserWebPlatform extends FakeWebViewPlatform {
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      BrowserNavigationDelegate(params);
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = BrowserWebController(params);
    controllers.add(controller);
    return controller;
  }
}

class BrowserWebController extends FakeWebViewController {
  BrowserWebController(super.params);
  String? location;
  Completer<String?>? pendingLocation;
  Completer<String?>? pendingTitle;
  int forwardQueries = 0;
  Completer<bool>? pendingBack;
  @override
  Future<bool> canGoBack() async {
    final pending = pendingBack;
    pendingBack = null;
    return pending == null ? await super.canGoBack() : await pending.future;
  }

  @override
  Future<String?> currentUrl() async {
    final pending = pendingLocation;
    pendingLocation = null;
    return pending == null ? location ?? await super.currentUrl() : pending.future;
  }

  @override
  Future<Object> runJavaScriptReturningResult(String script) async =>
      script == 'document.readyState' ? 'complete' : await super.runJavaScriptReturningResult(script);
  @override
  Future<void> setOnPlatformPermissionRequest(void Function(PlatformWebViewPermissionRequest) callback) async {}
  @override
  Future<String?> getTitle() async {
    final pending = pendingTitle;
    pendingTitle = null;
    return pending == null ? 'Example' : await pending.future;
  }

  @override
  Future<bool> canGoForward() async {
    forwardQueries++;
    return false;
  }
}

class BrowserNavigationDelegate extends FakeNavigationDelegate {
  BrowserNavigationDelegate(super.params);
  UrlChangeCallback? onUrlChange;
  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async => onUrlChange = callback;
}

class DelayedGuardPlatform extends FakeIslandPlatform {
  final attaching = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> attach(int webViewId, {required bool dark, required int textZoom}) async {
    attaching.complete();
    await release.future;
    return super.attach(webViewId, dark: dark, textZoom: textZoom);
  }
}

class DownloadOffers extends BrowserDownloadPlatform {
  void Function(BrowserDownloadRequest)? listener;
  final rejected = <String>[];
  @override
  Future<void> attach(int id, void Function(BrowserDownloadRequest) callback) async => listener = callback;
  @override
  Future<void> detach(int id) async => listener = null;
  @override
  Future<T?> callNative<T>(String method, [Map<String, Object?>? args]) async {
    if (method == 'reject') rejected.add(args!['id']! as String);
    return null;
  }
}

void main() {
  late BrowserWebPlatform web;
  late FakeIslandPlatform islands;
  late IslandPlatform realIslands;
  final url = Uri.parse('https://example.com/');
  BrowserPageController make() => BrowserPageController(initialUrl: url, onPageChanged: (_, _) {});
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    WebViewPlatform.instance = web = BrowserWebPlatform();
    realIslands = IslandPlatform.instance;
    IslandPlatform.instance = islands = FakeIslandPlatform();
  });
  tearDown(() => IslandPlatform.instance = realIslands);

  for (final previous in ['https://example.com/', 'about:blank']) {
    test('download navigation ends spinner and only restores a real document: $previous', () async {
      final realDownloads = BrowserDownloadPlatform.instance;
      final downloads = BrowserDownloadPlatform.instance = DownloadOffers();
      addTearDown(() => BrowserDownloadPlatform.instance = realDownloads);
      final page = make();
      await page.initialize(dark: false);
      final native = web.controller as BrowserWebController;
      final target = Uri.parse('https://example.com/attachment.json');
      await page.load(target);
      native.location = previous;
      var offered = false;
      page.onDownloadRequested = (_) {
        offered = true;
        expect(page.loading, isFalse);
        expect(page.ready, previous != 'about:blank');
      };
      downloads.listener!(BrowserDownloadRequest(id: 'one', url: target, filename: 'attachment.json'));
      await settle();
      expect(offered, isTrue);
      expect(page.url.toString(), previous == 'about:blank' ? target.toString() : previous);
      if (previous == 'about:blank') await expectLater(page.extract(), throwsStateError);
      page.dispose();
      await settle();
    });
  }

  test('late download metadata cannot replace a newer navigation or open stale consent', () async {
    final realDownloads = BrowserDownloadPlatform.instance;
    final downloads = BrowserDownloadPlatform.instance = DownloadOffers();
    addTearDown(() => BrowserDownloadPlatform.instance = realDownloads);
    final page = make();
    await page.initialize(dark: false);
    final native = web.controller as BrowserWebController;
    final target = Uri.parse('https://example.com/attachment.json');
    await page.load(target);
    final read = native.pendingLocation = Completer<String?>();
    var offered = false;
    page.onDownloadRequested = (_) => offered = true;
    downloads.listener!(BrowserDownloadRequest(id: 'old', url: target, filename: 'attachment.json'));
    final newer = Uri.parse('https://example.com/newer');
    await page.load(newer);
    read.complete(url.toString());
    await settle();
    expect(page.url, newer);
    expect(page.loading, isTrue);
    expect(page.ready, isFalse);
    expect(offered, isFalse);
    expect(downloads.rejected, ['old']);
    page.dispose();
    await settle();
  });

  test('initialization guards external page without adding JavaScript channels', () async {
    final page = make();
    await page.initialize(dark: true, textZoom: 130);
    expect(web.controller.channels, isEmpty);
    expect(islands.attached.single.dark, isTrue);
    expect(islands.attached.single.textZoom, 130);
    expect(web.controller.loads, [url]);
    web.controller.start();
    web.controller.finish();
    await settle();
    expect(page.ready, isTrue);
    page.dispose();
    await settle();
    expect(islands.destroyed, [web.controller.webViewIdentifier]);
  });

  test('dispose before initialize destroys the allocated native view exactly once', () async {
    final page = make();
    page.dispose();
    page.dispose();
    await settle();
    expect(islands.destroyed, [web.controller.webViewIdentifier]);
    expect(islands.attached, isEmpty);
    expect(web.controller.loads, isEmpty);
  });

  test('dispose during guard attachment waits for attachment then destroys without loading', () async {
    final delayed = DelayedGuardPlatform();
    IslandPlatform.instance = delayed;
    final page = make();
    final initialization = page.initialize(dark: false);
    await delayed.attaching.future;
    page.dispose();
    expect(delayed.destroyed, isEmpty);
    delayed.release.complete();
    await initialization;
    await settle();
    expect(delayed.destroyed, [web.controller.webViewIdentifier]);
    expect(web.controller.loads, isEmpty);
    delayed.gone();
    await settle();
  });

  test('reload immediately disables extraction before native navigation callbacks', () async {
    final page = make();
    await page.initialize(dark: false);
    web.controller.start();
    web.controller.finish();
    await settle();
    expect(page.ready, isTrue);
    await page.reload();
    await expectLater(page.extract(), throwsStateError);
    expect(page.loading, isTrue);
    page.dispose();
    await settle();
  });

  test('error from an older URL cannot fail a newly loaded page', () async {
    final page = make();
    await page.initialize(dark: false);
    await page.load(Uri.parse('https://example.com/new'));
    web.controller.delegate!.onWebResourceError!(
      WebResourceError(errorCode: -2, description: 'old request failed', isForMainFrame: true, url: url.toString()),
    );
    web.controller.start();
    web.controller.finish();
    await settle();
    expect(page.ready, isTrue);
    expect(page.error, isNull);
    page.dispose();
    await settle();
  });

  test('a failed destination still allows back to the successful previous page', () async {
    final page = make();
    await page.initialize(dark: false);
    final native = web.controller;
    native.start();
    native.finish();
    await settle();
    expect(page.canGoBack, isFalse);
    await page.load(Uri.parse('https://example.com/failing'));
    native.history = 1;
    native.start();
    native.fail();
    native.finish();
    await settle();
    expect(page.loading, isFalse);
    expect(page.error, 'load_failed');
    expect(page.ready, isFalse);
    expect(page.canGoBack, isTrue);
    await page.back();
    expect(native.goBacks, 1);
    page.dispose();
    await settle();
  });

  test('history read from a failed page cannot overwrite a newer navigation', () async {
    final page = make();
    await page.initialize(dark: false);
    final native = web.controller as BrowserWebController;
    native.start();
    final oldBack = native.pendingBack = Completer<bool>();
    native.fail();
    await settle();
    await page.load(Uri.parse('https://example.com/newer'));
    native.start();
    native.finish();
    await settle();
    oldBack.complete(true);
    await settle();
    expect(page.ready, isTrue);
    expect(page.error, isNull);
    expect(page.canGoBack, isFalse);
    page.dispose();
    await settle();
  });

  test('renderer loss disables extraction and ignores late finished callback', () async {
    final page = make();
    await page.initialize(dark: false);
    islands.gone();
    await settle();
    web.controller.start();
    web.controller.finish();
    await settle();
    expect(page.rendererGone, isTrue);
    expect(page.ready, isFalse);
    await expectLater(page.extract(), throwsStateError);
    page.dispose();
    await settle();
  });

  test('old same-URL finish cannot complete reload before its start event', () async {
    final page = make();
    await page.initialize(dark: false);
    web.controller.start();
    web.controller.finish();
    await settle();
    expect(page.ready, isTrue);
    await page.reload();
    web.controller.finish();
    await settle();
    expect(page.ready, isFalse);
    web.controller.start();
    web.controller.finish();
    await settle();
    expect(page.ready, isTrue);
    page.dispose();
    await settle();
  });

  test('SPA URL changes refresh history and complete same-document back', () async {
    final page = make();
    await page.initialize(dark: false);
    web.controller.start();
    web.controller.finish();
    await settle();
    final native = web.controller as BrowserWebController;
    final navigation = native.delegate! as BrowserNavigationDelegate;
    native.location = 'https://example.com/second';
    native.history = 1;
    navigation.onUrlChange!(UrlChange(url: native.location));
    await settle();
    expect(page.canGoBack, isTrue);
    await page.back();
    expect(page.ready, isFalse);
    native.location = url.toString();
    navigation.onUrlChange!(UrlChange(url: native.location));
    await settle();
    expect(page.ready, isTrue);
    expect(page.canGoBack, isFalse);
    page.dispose();
    await settle();
  });

  test('SPA change during metadata read finishes the current URL', () async {
    final page = make();
    await page.initialize(dark: false);
    final native = web.controller as BrowserWebController;
    final pending = Completer<String?>();
    native.pendingTitle = pending;
    native.start();
    native.finish();
    await settle();
    native.location = 'https://example.com/spa';
    (native.delegate! as BrowserNavigationDelegate).onUrlChange!(UrlChange(url: native.location));
    await settle();
    pending.complete('obsolete');
    await settle();
    expect(page.ready, isTrue);
    expect(page.title, 'Example');
    expect(page.url.toString(), native.location);
    page.dispose();
    await settle();
  });

  test('same-URL history entries refresh back capability', () async {
    final page = make();
    await page.initialize(dark: false);
    web.controller.start();
    web.controller.finish();
    await settle();
    final native = web.controller as BrowserWebController;
    native.history = 1;
    (native.delegate! as BrowserNavigationDelegate).onUrlChange!(UrlChange(url: url.toString()));
    await settle();
    expect(page.canGoBack, isTrue);
    await page.back();
    (native.delegate! as BrowserNavigationDelegate).onUrlChange!(UrlChange(url: url.toString()));
    await settle();
    expect(page.canGoBack, isFalse);
    expect(page.ready, isTrue);
    page.dispose();
    await settle();
  });

  test('address-bar fragment navigation completes without a document start', () async {
    final page = make();
    await page.initialize(dark: false);
    web.controller.start();
    web.controller.finish();
    await settle();
    final fragment = url.replace(fragment: 'section');
    await page.load(fragment);
    (web.controller.delegate! as BrowserNavigationDelegate).onUrlChange!(UrlChange(url: fragment.toString()));
    await settle();
    expect(page.ready, isTrue);
    page.dispose();
    await settle();
  });

  test('dispose during metadata read makes no further native queries', () async {
    final page = make();
    await page.initialize(dark: false);
    final native = web.controller as BrowserWebController;
    final pending = Completer<String?>();
    native.pendingTitle = pending;
    native.start();
    native.finish();
    await settle();
    page.dispose();
    pending.complete('late');
    await settle();
    expect(native.forwardQueries, 0);
  });
}
