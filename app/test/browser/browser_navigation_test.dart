// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/browser/browser_navigation.dart';
import 'package:dsh_app/browser/browser_page_controller.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../web/support/fake_webview.dart';
import 'browser_backend_test.dart' show MemoryBrowserStorage;
import 'browser_controller_test.dart' show BrowserWebController, BrowserWebPlatform, DelayedGuardPlatform;

class NavigationPlatform extends BrowserNavigationPlatform {
  final calls = <String>[];
  final saved = <String, Uri>{};
  final keys = <int, String>{};
  Completer<void>? saveGate;
  Completer<void>? restoreGate;
  void Function(int id, Uri url)? onRestore;
  bool failSave = false;

  @override
  Future<bool> restore(int id, String key, int generation, Uri expectedUrl) async {
    calls.add('restore:$id');
    keys[id] = key;
    await restoreGate?.future;
    if (saved.remove(key) != expectedUrl) return false;
    onRestore?.call(id, expectedUrl);
    return true;
  }

  @override
  Future<void> save(int id, String key, int generation, Uri expectedUrl) async {
    calls.add('save:$id');
    await saveGate?.future;
    if (failSave) throw StateError('native_failure');
    saved[key] = expectedUrl;
  }

  @override
  Future<void> drop(String key) async {
    calls.add('drop:$key');
    saved.remove(key);
  }
}

class FirstAttachDelayedPlatform extends FakeIslandPlatform {
  final attaching = Completer<void>();
  final release = Completer<void>();
  bool first = true;
  @override
  Future<bool> attach(int webViewId, {required bool dark, required int textZoom}) async {
    if (first) {
      first = false;
      attaching.complete();
      await release.future;
    }
    return super.attach(webViewId, dark: dark, textZoom: textZoom);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scope = BrowserScope(hostKey: 'local:local', sessionId: 'chat');
  const remote = BrowserScope(hostKey: 'ssh:remote', sessionId: 'chat');
  final url = Uri.parse('https://example.com/docs');
  late BrowserNavigation previous;
  late BrowserNavigation navigation;
  late NavigationPlatform platform;
  late ProviderContainer container;
  late MemoryBrowserStorage storage;
  late BrowserWebPlatform web;
  late IslandPlatform previousIslands;
  late FakeIslandPlatform islands;
  final pages = <BrowserPageController>[];

  BrowserWorkspaceController workspace() => container.read(browserWorkspaceProvider.notifier);
  BrowserTab tab(String id) => container.read(browserWorkspaceProvider).tabs.singleWhere((t) => t.id == id);
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  BrowserPageController page(BrowserTab tab) {
    final page = BrowserPageController(initialUrl: tab.url!, onPageChanged: (_, _) {})..configureNavigation(tab.id);
    pages.add(page);
    return page;
  }

  Future<BrowserPageController> loaded(BrowserTab tab) async {
    final controller = page(tab);
    await controller.initialize(dark: false);
    final native = web.controllers.last;
    native.start();
    native.finish();
    await settle();
    expect(controller.ready, isTrue);
    return controller;
  }

  setUp(() {
    previous = BrowserNavigation.instance;
    platform = NavigationPlatform();
    BrowserNavigation.instance = navigation = BrowserNavigation(platform: platform);
    storage = MemoryBrowserStorage();
    container = ProviderContainer(overrides: [browserStorageProvider.overrideWithValue(storage)]);
    WebViewPlatform.instance = web = BrowserWebPlatform();
    previousIslands = IslandPlatform.instance;
    IslandPlatform.instance = islands = FakeIslandPlatform();
    platform.onRestore = (id, uri) {
      final native = web.controllers.singleWhere((c) => c.webViewIdentifier == id) as BrowserWebController;
      native.location = uri.toString();
      native.history = 3; // The platform owns opaque native history, never URL replay.
    };
  });

  tearDown(() async {
    for (final page in pages) {
      page.dispose();
    }
    pages.clear();
    container.dispose();
    await settle();
    BrowserNavigation.instance = previous;
    IslandPlatform.instance = previousIslands;
  });

  test('home back and forward keep the same tab and sanitized persistence', () async {
    final home = await workspace().openHome(scope);
    final privateUrl = Uri.parse('https://example.com/docs?token=SECRET#PRIVATE');
    await workspace().navigate(home.id, privateUrl);
    expect(tab(home.id).homeBack, isTrue);
    await workspace().returnHome(home.id);
    expect(tab(home.id).isHome, isTrue);
    expect(tab(home.id).forwardUrl, privateUrl);
    await workspace().updatePage(home.id, url: url, title: 'late page callback');
    expect(tab(home.id).isHome, isTrue);
    expect(storage.value, isNot(contains('SECRET')));
    expect(storage.value, isNot(contains('PRIVATE')));
    final restored = BrowserTab.fromJson(jsonDecode(storage.value!)['tabs'][0])!;
    expect(restored.forwardUrl, url);
    expect(restored.homeBack, isTrue);
    await workspace().resumeFromHome(home.id);
    expect(tab(home.id).url, privateUrl);
    expect(tab(home.id).forwardUrl, isNull);
    expect(container.read(browserWorkspaceProvider).tabs, hasLength(1));
  });

  test('direct links have no invented Home back entry and v1/v2 records remain readable', () async {
    final direct = await workspace().open(scope, url);
    expect(direct.homeBack, isFalse);
    await workspace().returnHome(direct.id);
    expect(tab(direct.id).url, url);
    final legacy = {...direct.toJson()}
      ..remove('homeBack')
      ..remove('forwardUrl');
    expect(BrowserTab.fromJson(legacy)!.homeBack, isFalse);
    final home = await workspace().openHome(scope);
    expect(BrowserTab.fromJson({...home.toJson(), 'forwardUrl': 'http://127.0.0.1/token'})!.forwardUrl, isNull);
  });

  test('dispose saves before destroying and restore never loads over native history', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    final firstId = web.controllers.first.webViewIdentifier;
    platform.saveGate = Completer<void>();
    first.dispose();
    final second = page(opened);
    final initializing = second.initialize(dark: false);
    await settle();
    expect(platform.calls, ['restore:$firstId', 'save:$firstId']);
    expect(islands.destroyed, isEmpty);
    expect(web.controllers.last.loads, isEmpty);
    platform.saveGate!.complete();
    await initializing;
    expect(islands.destroyed, [firstId]);
    expect(web.controllers.last.loads, isEmpty);
    expect(second.canGoBack, isTrue);
    expect(second.ready, isFalse); // A saved document is not a ready DOM.
    web.controllers.last.delegate!.onPageFinished!(url.toString());
    await settle();
    expect(second.ready, isTrue);
  });

  test('restored finish for another URL never enables content extraction', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    first.dispose();
    final second = page(opened);
    await second.initialize(dark: false);
    web.controllers.last.delegate!.onPageFinished!('https://evil.example/');
    await settle();
    expect(second.ready, isFalse);
    await expectLater(second.extract(), throwsStateError);
  });

  test('URL mismatch falls back to loading only the expected URL', () async {
    final opened = await workspace().open(scope, url);
    (await loaded(opened)).dispose();
    await settle();
    final next = url.replace(path: '/other');
    await workspace().navigate(opened.id, next);
    final second = page(tab(opened.id));
    await second.initialize(dark: false);
    expect(web.controllers.last.loads, [next]);
  });

  test('close and immediate undo cannot resurrect an in-flight old save', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    platform.saveGate = Completer<void>();
    first.dispose();
    await settle();
    final closed = await workspace().close(opened.id);
    await workspace().restoreTab(closed!);
    final replacement = page(tab(opened.id));
    await replacement.initialize(dark: false);
    expect(web.controllers.last.loads, [url]);
    expect(platform.keys.values.toSet(), hasLength(2));
    platform.saveGate!.complete();
    await settle();
    expect(platform.saved, isEmpty);
  });

  test('closed tab disposal cannot save, and unknown tab configure is inert', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    await workspace().close(opened.id);
    first.dispose();
    await settle();
    expect(platform.calls.where((c) => c.startsWith('save:')), isEmpty);
    final second = page(opened);
    await second.initialize(dark: false);
    expect(web.controllers.last.loads, [url]);
    expect(platform.calls.where((c) => c.startsWith('restore:')), hasLength(1));
  });

  test('a newer restored controller supersedes a late disposal of the same tab', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    final second = await loaded(opened);
    expect(first.ready, isFalse);
    first.dispose();
    second.dispose();
    await settle();
    expect(platform.calls.where((c) => c.startsWith('save:')), ['save:${web.controllers.last.webViewIdentifier}']);
  });

  test('scope deletion drops only that host, with no late undo', () async {
    final a = await workspace().open(scope, url);
    final b = await workspace().open(remote, url);
    (await loaded(a)).dispose();
    (await loaded(b)).dispose();
    await settle();
    expect(platform.saved, hasLength(2));
    await workspace().clear(scope);
    await settle();
    expect(platform.saved, hasLength(1));
    await expectLater(workspace().restoreTab(a), throwsStateError);
    final restored = page(b);
    await restored.initialize(dark: false);
    expect(web.controllers.last.loads, isEmpty);
  });

  test('home forward restores history, new navigation from home discards it', () async {
    final home = await workspace().openHome(scope);
    await workspace().navigate(home.id, url);
    final first = await loaded(tab(home.id));
    await workspace().returnHome(home.id);
    first.dispose();
    await workspace().resumeFromHome(home.id);
    final second = page(tab(home.id));
    await second.initialize(dark: false);
    expect(web.controllers.last.loads, isEmpty);
    web.controllers.last.delegate!.onPageFinished!(url.toString());
    await settle();
    await workspace().returnHome(home.id);
    second.dispose();
    // Entering even the same address is a new branch, not a forward action.
    await workspace().navigate(home.id, url);
    final third = page(tab(home.id));
    await third.initialize(dark: false);
    expect(web.controllers.last.loads, [url]);
  });

  test('reload in progress and failed loads never save', () async {
    final a = await workspace().open(scope, url);
    final first = await loaded(a);
    await first.reload();
    first.dispose();
    final b = await workspace().open(scope, url);
    final second = await loaded(b);
    web.controllers.last.fail();
    second.dispose();
    await settle();
    expect(platform.calls.where((c) => c.startsWith('save:')), isEmpty);
  });

  test('renderer loss invalidates the lease before disposal', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    islands.gone();
    await settle();
    first.dispose();
    await settle();
    expect(first.ready, isFalse);
    expect(platform.calls.where((c) => c.startsWith('save:')), isEmpty);
    expect(platform.saved, isEmpty);
  });

  test('dispose during guard attachment cannot deadlock pending restoration', () async {
    final opened = await workspace().open(scope, url);
    final delayed = DelayedGuardPlatform();
    IslandPlatform.instance = delayed;
    final first = page(opened);
    final initializing = first.initialize(dark: false);
    await delayed.attaching.future;
    first.dispose();
    delayed.release.complete();
    await initializing;
    await settle();
    expect(delayed.destroyed, [web.controllers.first.webViewIdentifier]);
    expect(platform.calls, isEmpty);
    expect(web.controllers.first.loads, isEmpty);
  });

  test('dispose during native restore never loads or saves a half-restored page', () async {
    final opened = await workspace().open(scope, url);
    platform.restoreGate = Completer<void>();
    final first = page(opened);
    final initializing = first.initialize(dark: false);
    await settle();
    first.dispose();
    platform.restoreGate!.complete();
    await initializing;
    await settle();
    expect(islands.destroyed, hasLength(1));
    expect(web.controllers.first.loads, isEmpty);
    expect(platform.calls.where((c) => c.startsWith('save:')), isEmpty);
  });

  test('release queued before restore cannot deadlock initialization or the replacement', () async {
    final opened = await workspace().open(scope, url);
    final delayed = FirstAttachDelayedPlatform();
    IslandPlatform.instance = delayed;
    final first = page(opened);
    final firstInitialization = first.initialize(dark: false);
    await delayed.attaching.future; // initialize has not reached restore().
    first.dispose(); // release is now the first queued operation.
    final replacement = page(opened);
    final secondInitialization = replacement.initialize(dark: false);
    await settle(); // replacement's restore queues behind release.
    expect(platform.calls, isEmpty);
    delayed.release.complete();
    await Future.wait([firstInitialization, secondInitialization]).timeout(const Duration(seconds: 2));
    expect(delayed.destroyed, [web.controllers.first.webViewIdentifier]);
    expect(platform.calls, ['restore:${web.controllers.last.webViewIdentifier}']);
    expect(web.controllers.first.loads, isEmpty);
    expect(web.controllers.last.loads, [url]);
  });

  test('renderer loss during pending native save purges before a replacement can restore', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    platform.saveGate = Completer<void>();
    first.dispose();
    await settle();
    islands.gone();
    await settle();
    final replacement = page(opened);
    final initializing = replacement.initialize(dark: false);
    platform.saveGate!.complete();
    await initializing;
    await settle();
    expect(platform.saved, isEmpty);
    expect(web.controllers.last.loads, [url]);
    expect(islands.destroyed, [web.controllers.first.webViewIdentifier]);
  });

  test('native save failure still destroys and does not poison subsequent restore', () async {
    final opened = await workspace().open(scope, url);
    final first = await loaded(opened);
    platform.failSave = true;
    first.dispose();
    final second = page(opened);
    await second.initialize(dark: false);
    expect(islands.destroyed, hasLength(1));
    expect(web.controllers.last.loads, [url]);
  });

  test('registry capacity is bounded and identical ids on new hosts cannot share snapshots', () async {
    final owner = Object();
    final entries = List.generate(
      81,
      (i) => BrowserTab(id: '$i', scope: scope, url: url, title: '', updatedAt: DateTime(2026)),
    );
    navigation.synchronize(owner, entries);
    expect(navigation.bind('79'), isNotNull);
    expect(navigation.bind('80'), isNull);
    final old = navigation.bind('0')!;
    await old.restore(901, url, isAlive: () => true);
    await old.release(
      initialized: Future.value(),
      identifier: () => 901,
      expectedUrl: url,
      save: true,
      destroy: () async {},
    );
    navigation.synchronize(owner, [BrowserTab(id: '0', scope: remote, url: url, title: '', updatedAt: DateTime(2026))]);
    final fresh = navigation.bind('0')!;
    expect(await fresh.restore(902, url, isAlive: () => true), isFalse);
    expect(platform.keys[901], isNot(platform.keys[902]));
    navigation.release(owner);
  });

  test('method channel sends only capability, view identity and expected URL', () async {
    const channel = MethodChannel('test/browser-navigation');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'browserNavigationRestore' ? true : null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final native = MethodChannelBrowserNavigationPlatform(channel);
    expect(await native.restore(1, 'key', 2, url), isTrue);
    await native.save(1, 'key', 2, url);
    await native.drop('key');
    expect(calls.map((c) => c.method), ['browserNavigationRestore', 'browserNavigationSave', 'browserNavigationDrop']);
    expect(calls[0].arguments, {'id': 1, 'key': 'key', 'generation': 2, 'url': url.toString()});
  });

  test('missing platform degrades to normal URL load', () async {
    final native = MethodChannelBrowserNavigationPlatform(const MethodChannel('test/missing-navigation'));
    expect(await native.restore(1, 'key', 1, url), isFalse);
    await native.save(1, 'key', 1, url);
    await native.drop('key');
  });
}
