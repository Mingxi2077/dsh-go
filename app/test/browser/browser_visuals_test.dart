// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dsh_app/browser/browser_page_controller.dart';
import 'package:dsh_app/browser/browser_visuals.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../web/support/fake_webview.dart';

class _WebPlatform extends FakeWebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = _WebController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      _Navigation(params);
}

class _WebController extends FakeWebViewController {
  _WebController(super.params);
  @override
  Future<void> setOnPlatformPermissionRequest(void Function(PlatformWebViewPermissionRequest) callback) async {}
  @override
  Future<String?> getTitle() async => 'Page';
  @override
  Future<bool> canGoForward() async => false;
  @override
  Future<Object> runJavaScriptReturningResult(String script) async => 'complete';
}

class _Navigation extends FakeNavigationDelegate {
  _Navigation(super.params);
  UrlChangeCallback? changed;
  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async => changed = callback;
}

class _Visuals extends BrowserVisualPlatform {
  final captures = <({int id, Uri url, int width, Completer<Uint8List?> result})>[];
  final icons = <({int id, Uri url, Completer<Uint8List?> result})>[];
  @override
  Future<Uint8List?> capture(int id, Uri expectedUrl, int width) {
    final result = Completer<Uint8List?>();
    captures.add((id: id, url: expectedUrl, width: width, result: result));
    return result.future;
  }

  @override
  Future<Uint8List?> icon(int id, Uri expectedUrl) {
    final result = Completer<Uint8List?>();
    icons.add((id: id, url: expectedUrl, result: result));
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final url = Uri.parse('https://example.com/page');
  final image = Uint8List.fromList([137, 80, 78, 71]);
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('native image channel', () {
    const channel = MethodChannel('test/browser-images');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final platform = MethodChannelBrowserVisualPlatform(channel);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('uses native view identity and expected URL, clamps preview width', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return image;
      });
      expect(await platform.capture(42, url, 9999), image);
      expect(await platform.capture(42, url, -1), image);
      expect(await platform.icon(42, url), image);
      expect(calls.map((c) => c.method), ['browserPreview', 'browserPreview', 'browserSiteIcon']);
      expect(calls[0].arguments, {'id': 42, 'url': url.toString(), 'width': 600});
      expect(calls[1].arguments['width'], 160);
      expect(calls[2].arguments, {'id': 42, 'url': url.toString()});
    });

    test('missing plugin, native failure and malformed or oversized replies return null', () async {
      expect(await platform.capture(1, url, 420), isNull);
      messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'gone'));
      expect(await platform.icon(1, url), isNull);
      for (final value in [
        null,
        'wrong type',
        <int>[1, 2],
        Uint8List(0),
        Uint8List(BrowserVisualPlatform.maxBytes + 1),
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        expect(await platform.capture(1, url, 420), isNull);
      }
      messenger.setMockMethodCallHandler(channel, (_) async => Uint8List(BrowserVisualPlatform.maxBytes));
      expect((await platform.icon(1, url))!.length, BrowserVisualPlatform.maxBytes);
    });
  });

  group('document image ownership', () {
    late _WebPlatform web;
    late FakeIslandPlatform islands;
    late _Visuals visuals;
    late BrowserVisualPlatform originalVisuals;
    late IslandPlatform originalIslands;
    WebViewPlatform? originalWeb;
    final pages = <BrowserPageController>[];

    Future<BrowserPageController> make({bool finish = true}) async {
      final page = BrowserPageController(initialUrl: url, onPageChanged: (_, _) {});
      pages.add(page);
      await page.initialize(dark: false);
      if (finish) {
        web.controllers.last.start();
        web.controllers.last.finish();
        await settle();
        expect(page.ready, isTrue);
      }
      return page;
    }

    setUp(() {
      originalWeb = WebViewPlatform.instance;
      originalIslands = IslandPlatform.instance;
      originalVisuals = BrowserVisualPlatform.instance;
      WebViewPlatform.instance = web = _WebPlatform();
      IslandPlatform.instance = islands = FakeIslandPlatform();
      BrowserVisualPlatform.instance = visuals = _Visuals();
    });
    tearDown(() async {
      for (final page in pages) {
        page.dispose();
      }
      pages.clear();
      await settle();
      BrowserVisualPlatform.instance = originalVisuals;
      IslandPlatform.instance = originalIslands;
      if (originalWeb != null) WebViewPlatform.instance = originalWeb;
    });

    test('loading pages never ask native code for images', () async {
      final page = await make(finish: false);
      expect(await page.capturePreview(), isNull);
      expect(await page.siteIcon(), isNull);
      expect(visuals.captures, isEmpty);
      expect(visuals.icons, isEmpty);
    });

    test('preview and icon can complete independently for the same view', () async {
      final page = await make();
      final capture = page.capturePreview(width: 10000);
      final icon = page.siteIcon();
      expect(visuals.captures.single.id, web.controller.webViewIdentifier);
      expect(visuals.captures.single.url, url);
      expect(visuals.captures.single.width, 600);
      visuals.icons.single.result.complete(image);
      expect(await icon, image);
      visuals.captures.single.result.complete(image);
      expect(await capture, image);
    });

    for (final kind in ['preview', 'icon']) {
      test('later $kind request retires an older reply within the same revision', () async {
        final page = await make();
        final first = kind == 'preview' ? page.capturePreview() : page.siteIcon();
        final second = kind == 'preview' ? page.capturePreview() : page.siteIcon();
        final replies = kind == 'preview'
            ? visuals.captures.map((c) => c.result).toList()
            : visuals.icons.map((c) => c.result).toList();
        replies[1].complete(image);
        expect(await second, image);
        replies[0].complete(image);
        expect(await first, isNull);
      });
    }

    for (final change in [
      'navigate-away-and-back',
      'reload',
      'same-url-history',
      'failure',
      'renderer-loss',
      'dispose',
    ]) {
      test('$change invalidates both pending image kinds', () async {
        final page = await make();
        final capture = page.capturePreview();
        final icon = page.siteIcon();
        switch (change) {
          case 'navigate-away-and-back':
            await page.load(url.replace(path: '/other'));
            await page.load(url);
            web.controller.start();
            web.controller.finish();
          case 'reload':
            await page.reload();
            web.controller.start();
            web.controller.finish();
          case 'same-url-history':
            (web.controller.delegate! as _Navigation).changed!(UrlChange(url: url.toString()));
          case 'failure':
            web.controller.fail();
          case 'renderer-loss':
            islands.gone();
          case 'dispose':
            page.dispose();
        }
        await settle();
        visuals.captures.single.result.complete(image);
        visuals.icons.single.result.complete(image);
        expect(await capture, isNull);
        expect(await icon, isNull);
      });
    }

    test('one controller does not invalidate another controller with the same URL', () async {
      final first = await make();
      final second = await make();
      final a = first.capturePreview();
      final b = second.capturePreview();
      first.dispose();
      visuals.captures[0].result.complete(image);
      visuals.captures[1].result.complete(image);
      expect(await a, isNull);
      expect(await b, image);
    });

    test('native exceptions and invalid byte sizes are contained', () async {
      final page = await make();
      final failed = page.capturePreview();
      visuals.captures.last.result.completeError(StateError('destroyed'));
      expect(await failed, isNull);
      for (final bytes in [Uint8List(0), Uint8List(BrowserVisualPlatform.maxBytes + 1)]) {
        final pending = page.capturePreview();
        visuals.captures.last.result.complete(bytes);
        expect(await pending, isNull);
      }
    });

    test('timed-out capture returns null and does not displace a later result', () async {
      final page = await make();
      final first = page.capturePreview();
      expect(await first, isNull);
      final second = page.capturePreview();
      visuals.captures[1].result.complete(image);
      expect(await second, image);
      visuals.captures[0].result.complete(image);
      await settle();
    });
  });
}
