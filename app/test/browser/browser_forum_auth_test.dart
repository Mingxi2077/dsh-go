// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/browser/browser_auth_controller.dart';
import 'package:dsh_app/browser/browser_links.dart';
import 'package:dsh_app/forum/discourse_client.dart';
import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/forum/forum_config.dart';
import 'package:dsh_app/forum/forum_crypto.dart';
import 'package:dsh_app/forum/forum_models.dart';
import 'package:dsh_app/forum/forum_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../forum/support.dart';
import '../web/support/fake_webview.dart';
import 'browser_auth_controller_test.dart' show AuthWebPlatform;

final _keys = ForumKeyPair.fromJson(fixture('rsa_key.json'))!;
const _session = 'session:$forumDefaultBaseUrl';
const _otherBase = 'https://other-forum.example.com';

class _Browser extends EmbeddedAccountBrowser {
  final requests = <BrowserAuthorization>[];
  bool opens = true;

  @override
  Future<bool> authorize(BrowserAuthorization request) async {
    requests.add(request);
    return opens;
  }

  @override
  Future<bool> open(Uri url) async => fail('forum authorization must not become an ordinary browser tab');
}

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() {
    entered.complete();
    return release.future;
  }
}

class _Store extends MemorySecretStore {
  final reads = <String, _Gate>{};
  final writes = <String, _Gate>{};
  final deletes = <String, _Gate>{};
  final written = <String>[];

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    await reads.remove(key)?.wait();
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    await writes.remove(key)?.wait();
    written.add(key);
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await deletes.remove(key)?.wait();
    await super.delete(key);
  }
}

class _HeldUserApi extends FakeForumApi {
  final response = Completer<ForumCurrentUser>();
  @override
  Future<ForumCurrentUser> currentUser() => response.future;
}

Uri _redirect(String nonce, {String key = 'forum-private-key'}) => Uri.parse(forumAuthRedirect).replace(
  queryParameters: {
    'payload': base64.encode(encryptForumPayload(utf8.encode(jsonEncode({'key': key, 'nonce': nonce})), _keys)),
  },
);

Future<void> _flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  late _Browser browser;
  late FakeForumApi api;
  late List<ProviderContainer> containers;

  ProviderContainer make({AccountBrowser? opener, Future<ForumKeyPair> Function()? factory}) {
    final container = ProviderContainer(
      overrides: [
        forumSecretStoreProvider.overrideWithValue(store),
        forumKeyPairFactoryProvider.overrideWithValue(factory ?? () async => _keys),
        accountBrowserProvider.overrideWithValue(opener ?? browser),
        forumApiFactoryProvider.overrideWithValue((_, _) => api),
      ],
    );
    containers.add(container);
    container.listen(forumAuthProvider, (_, _) {});
    return container;
  }

  void dispose(ProviderContainer container) {
    containers.remove(container);
    container.dispose();
  }

  Future<BrowserAuthorization> start(ProviderContainer container) async {
    await _flush();
    expect(await container.read(forumAuthProvider.notifier).signIn(), isTrue);
    return browser.requests.last;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _Store();
    browser = _Browser();
    api = FakeForumApi(signedIn: true, user: sampleUser);
    containers = [];
  });
  tearDown(() async {
    for (final container in containers) {
      container.dispose();
    }
    BrowserLinks.openAuthorization = null;
    BrowserLinks.openPage = null;
    await _flush();
  });

  test('forum creates an ephemeral capability and completes only after nonce-verified storage', () async {
    final container = make();
    final request = await start(container);
    expect(request.onForumRedirect, isNotNull);
    expect(request.callbackOrigin, isNull);
    expect(request.preferSystem, isFalse);
    expect(request.url.path, '/user-api-key/new');
    expect(request.url.queryParameters['auth_redirect'], forumAuthRedirect);
    expect(request.isCurrent(), isTrue);
    var completed = false;
    unawaited(request.completed.then((_) => completed = true));
    final nonce = request.url.queryParameters['nonce']!;
    expect((jsonDecode(store.values['pending']!) as Map)['nonce'], nonce);
    expect(completed, isFalse);
    expect(await request.onForumRedirect!(_redirect(nonce)), isTrue);
    await _flush();
    expect(completed, isTrue);
    expect(request.isCurrent(), isFalse);
    expect(container.read(forumAuthProvider).credentials!.key, 'forum-private-key');
    expect(container.read(forumAuthProvider).user, sampleUser);
    expect(store.values['pending'], isNull);
    expect((jsonDecode(store.values[_session]!) as Map)['key'], 'forum-private-key');
    await request.cancel();
    expect(container.read(forumAuthProvider).signedIn, isTrue);
  });

  test('bad nonce fails without consuming the pending login; a valid retry succeeds', () async {
    final container = make();
    final request = await start(container);
    expect(await request.onForumRedirect!(_redirect('wrong-nonce')), isFalse);
    expect(store.values[_session], isNull);
    expect(request.isCurrent(), isTrue);
    expect(container.read(forumAuthProvider).error, '登录没有完成，请重试');
    expect(await request.onForumRedirect!(_redirect(request.url.queryParameters['nonce']!)), isTrue);
    expect(container.read(forumAuthProvider).signedIn, isTrue);
  });

  test('new nonce completes the old page and old cancel/redirect cannot touch the new attempt', () async {
    final container = make();
    final first = await start(container);
    final second = await start(container);
    await first.completed;
    expect(first.isCurrent(), isFalse);
    expect(second.isCurrent(), isTrue);
    expect(second.id, isNot(same(first.id)));
    expect(first.url.queryParameters['nonce'], isNot(second.url.queryParameters['nonce']));
    final latestPending = store.values['pending'];
    await first.cancel();
    expect(await first.onForumRedirect!(_redirect(second.url.queryParameters['nonce']!)), isFalse);
    expect(store.values['pending'], latestPending);
    expect(store.values[_session], isNull);
    expect(second.isCurrent(), isTrue);
    await second.cancel();
    await second.completed;
    await _flush();
    expect(store.values['pending'], isNull);
    expect(container.read(forumAuthProvider).phase, ForumAuthPhase.signedOut);
  });

  test('late pending read cannot authenticate or delete a newer nonce', () async {
    final container = make();
    final first = await start(container);
    final gate = store.reads['pending'] = _Gate();
    final redirect = first.onForumRedirect!(_redirect(first.url.queryParameters['nonce']!));
    await gate.entered.future;
    final opening = container.read(forumAuthProvider.notifier).signIn();
    await first.completed;
    gate.release.complete();
    expect(await redirect, isFalse);
    expect(await opening, isTrue);
    final second = browser.requests.last;
    expect((jsonDecode(store.values['pending']!) as Map)['nonce'], second.url.queryParameters['nonce']);
    expect(store.values[_session], isNull);
    expect(second.isCurrent(), isTrue);
  });

  for (final change in ['new nonce', 'cancel', 'switch forum', 'dispose']) {
    test('session write completing after $change is rolled back before successor storage work', () async {
      final container = make();
      final request = await start(container);
      final previous = jsonEncode({'key': 'previous-key', 'client': 'existing-client'});
      store.values[_session] = previous;
      final gate = store.writes[_session] = _Gate();
      final redirect = request.onForumRedirect!(_redirect(request.url.queryParameters['nonce']!));
      await gate.entered.future;
      Future<bool>? opening;
      switch (change) {
        case 'new nonce':
          opening = container.read(forumAuthProvider.notifier).signIn();
        case 'cancel':
          await request.cancel();
        case 'switch forum':
          await container.read(forumBaseUrlProvider.notifier).set(_otherBase);
          await container.pump();
        case 'dispose':
          dispose(container);
      }
      await request.completed;
      gate.release.complete();
      expect(await redirect, isFalse);
      if (opening != null) expect(await opening, isTrue);
      await _flush();
      expect(store.values[_session], previous);
      expect(request.isCurrent(), isFalse);
      if (change == 'new nonce') {
        expect(browser.requests.last.isCurrent(), isTrue);
        expect(
          (jsonDecode(store.values['pending']!) as Map)['nonce'],
          browser.requests.last.url.queryParameters['nonce'],
        );
      } else if (change == 'cancel') {
        expect(store.values['pending'], isNull);
      } else if (change == 'switch forum') {
        expect(container.read(forumAuthProvider).signedIn, isFalse);
        expect(store.values['session:$_otherBase'], isNull);
      }
    });
  }

  test('retirement during pending deletion restores the transaction before a new nonce is saved', () async {
    final container = make();
    final first = await start(container);
    final gate = store.deletes['pending'] = _Gate();
    final redirect = first.onForumRedirect!(_redirect(first.url.queryParameters['nonce']!));
    await gate.entered.future;
    final opening = container.read(forumAuthProvider.notifier).signIn();
    gate.release.complete();
    expect(await redirect, isFalse);
    expect(await opening, isTrue);
    expect(store.values[_session], isNull);
    final next = browser.requests.last;
    expect((jsonDecode(store.values['pending']!) as Map)['nonce'], next.url.queryParameters['nonce']);
    expect(await next.onForumRedirect!(_redirect(next.url.queryParameters['nonce']!)), isTrue);
  });

  test('overlapping native and embedded callbacks commit only once and replay preserves the account', () async {
    final container = make();
    final request = await start(container);
    final gate = store.reads['pending'] = _Gate();
    final uri = _redirect(request.url.queryParameters['nonce']!);
    final first = request.onForumRedirect!(uri);
    await gate.entered.future;
    expect(await container.read(forumAuthProvider.notifier).handleRedirect(uri), isFalse);
    gate.release.complete();
    expect(await first, isTrue);
    expect(store.written.where((key) => key == _session), hasLength(1));
    expect(await container.read(forumAuthProvider.notifier).handleRedirect(uri), isFalse);
    expect(container.read(forumAuthProvider).signedIn, isTrue);
    expect(container.read(forumAuthProvider).error, isNull);
  });

  for (final otherForum in [false, true]) {
    test('cold-start redirect uses secure pending nonce/base (different active forum: $otherForum)', () async {
      final first = make();
      final request = await start(first);
      final uri = _redirect(request.url.queryParameters['nonce']!);
      dispose(first);
      await request.completed;
      expect(store.values['pending'], isNotNull, reason: 'process disposal must preserve cold-start verification');
      if (otherForum) SharedPreferences.setMockInitialValues({'forum.baseUrl': _otherBase});
      final restarted = make();
      await _flush();
      expect(await restarted.read(forumAuthProvider.notifier).handleRedirect(uri), isTrue);
      expect((jsonDecode(store.values[_session]!) as Map)['key'], 'forum-private-key');
      expect(restarted.read(forumAuthProvider).signedIn, !otherForum);
      expect(store.values['session:$_otherBase'], isNull);
      expect(store.values['pending'], isNull);
    });
  }

  test('an immediate cold-start redirect survives restoring a saved custom forum address', () async {
    final first = make();
    final request = await start(first);
    final uri = _redirect(request.url.queryParameters['nonce']!);
    dispose(first);
    SharedPreferences.setMockInitialValues({'forum.baseUrl': _otherBase});
    final restarted = make();
    expect(await restarted.read(forumAuthProvider.notifier).handleRedirect(uri), isTrue);
    await _flush();
    expect(restarted.read(forumBaseUrlProvider), _otherBase);
    expect(restarted.read(forumAuthProvider).signedIn, isFalse);
    expect((jsonDecode(store.values[_session]!) as Map)['key'], 'forum-private-key');
    expect(store.values['session:$_otherBase'], isNull);
    expect(store.values['pending'], isNull);
  });

  test('an immediate cold-start redirect signs in to its restored custom forum', () async {
    SharedPreferences.setMockInitialValues({'forum.baseUrl': _otherBase});
    final first = make();
    final request = await start(first);
    final uri = _redirect(request.url.queryParameters['nonce']!);
    dispose(first);
    SharedPreferences.setMockInitialValues({'forum.baseUrl': _otherBase});
    final restarted = make();
    expect(await restarted.read(forumAuthProvider.notifier).handleRedirect(uri), isTrue);
    await _flush();
    expect(restarted.read(forumAuthProvider).signedIn, isTrue);
    expect(store.values['session:$_otherBase'], isNotNull);
    expect(store.values[_session], isNull);
    expect(store.values['pending'], isNull);
  });

  for (final change in ['cancel', 'new nonce', 'dispose']) {
    test('a cold-start redirect waiting for preferences is retired by $change', () async {
      final first = make();
      final request = await start(first);
      final uri = _redirect(request.url.queryParameters['nonce']!);
      dispose(first);
      final restarted = make();
      final notifier = restarted.read(forumAuthProvider.notifier);
      final redirect = notifier.handleRedirect(uri);
      Future<bool>? opening;
      switch (change) {
        case 'cancel':
          notifier.cancel();
        case 'new nonce':
          opening = notifier.signIn();
        case 'dispose':
          dispose(restarted);
      }
      expect(await redirect, isFalse);
      if (opening != null) expect(await opening, isTrue);
      expect(store.values[_session], isNull);
      if (change == 'new nonce') expect(browser.requests.last.isCurrent(), isTrue);
    });
  }

  test('cancelling during RSA generation cannot publish a nonce or open a late page', () async {
    final keys = Completer<ForumKeyPair>();
    final entered = Completer<void>();
    final container = make(
      factory: () {
        entered.complete();
        return keys.future;
      },
    );
    await _flush();
    final opening = container.read(forumAuthProvider.notifier).signIn();
    await entered.future;
    container.read(forumAuthProvider.notifier).cancel();
    keys.complete(_keys);
    expect(await opening, isFalse);
    expect(browser.requests, isEmpty);
    expect(store.values['pending'], isNull);
    expect(store.values['rsa'], isNull);
  });

  test('pending write finishing after a forum switch is removed and never opened', () async {
    final container = make();
    await _flush();
    final gate = store.writes['pending'] = _Gate();
    final opening = container.read(forumAuthProvider.notifier).signIn();
    await gate.entered.future;
    await container.read(forumBaseUrlProvider.notifier).set(_otherBase);
    await container.pump();
    gate.release.complete();
    expect(await opening, isFalse);
    expect(browser.requests, isEmpty);
    expect(store.values['pending'], isNull);
  });

  test('a profile rejection from an older login cannot expire a new authorization', () async {
    final held = _HeldUserApi();
    api = held;
    final container = make();
    final request = await start(container);
    expect(await request.onForumRedirect!(_redirect(request.url.queryParameters['nonce']!)), isTrue);
    final next = await start(container);
    held.response.completeError(const ForumException(ForumErrorKind.forbidden));
    await _flush();
    expect(next.isCurrent(), isTrue);
    expect(container.read(forumAuthProvider).phase, ForumAuthPhase.waiting);
    expect(store.values[_session], isNotNull);
  });

  test('failed opening completes its surface and retry makes a new one', () async {
    browser.opens = false;
    final container = make();
    await _flush();
    expect(await container.read(forumAuthProvider.notifier).signIn(), isFalse);
    final first = browser.requests.single;
    await first.completed;
    expect(first.isCurrent(), isFalse);
    browser.opens = true;
    final second = await start(container);
    expect(second.id, isNot(same(first.id)));
    expect(second.isCurrent(), isTrue);
  });

  test('embedded WebView hands an encrypted forum payload straight to its producer', () async {
    final savedWeb = WebViewPlatform.instance;
    final savedIslands = IslandPlatform.instance;
    final web = AuthWebPlatform();
    WebViewPlatform.instance = web;
    IslandPlatform.instance = FakeIslandPlatform();
    BrowserAuthController? controller;
    addTearDown(() async {
      controller?.dispose();
      await _flush();
      if (savedWeb != null) WebViewPlatform.instance = savedWeb;
      IslandPlatform.instance = savedIslands;
    });
    BrowserLinks.openPage = (_) async => fail('must never enter ordinary browser');
    BrowserLinks.openAuthorization = (request) async {
      controller = BrowserAuthController(
        request,
        externalOpen: (_) async => fail('callback must not launch the OS'),
        createHttpClient: () => throw StateError('forum redirects must not use HTTP forwarding'),
      );
      await controller!.initialize(dark: false);
      return true;
    };
    final container = make(opener: const EmbeddedAccountBrowser());
    await _flush();
    expect(await container.read(forumAuthProvider.notifier).signIn(), isTrue);
    final auth = controller!.request;
    final decision = await web.controller.navigation.navigation!(
      NavigationRequest(url: _redirect(auth.url.queryParameters['nonce']!).toString(), isMainFrame: true),
    );
    expect(decision, NavigationDecision.prevent);
    await auth.completed;
    await _flush();
    expect(container.read(forumAuthProvider).signedIn, isTrue);
    expect(controller!.finishing, isFalse);
    expect(controller!.error, isNull);
    expect(web.controller.loads, [auth.url]);
    expect(controller!.currentUrl, auth.url);
  });
}
