import 'dart:async';

import 'package:dsh_app/browser/browser_links.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart';
import '../plugins/support/fake_plugin_host.dart';
import '../remote/support/fake_relay.dart';

class _RecordingAccountBrowser extends EmbeddedAccountBrowser {
  final requests = <BrowserAuthorization>[];
  Future<bool> Function(BrowserAuthorization)? onAuthorize;

  @override
  Future<bool> authorize(BrowserAuthorization request) async {
    requests.add(request);
    return onAuthorize == null ? true : await onAuthorize!(request);
  }
}

class _OriginAccountApi extends FakeAccountApi {
  _OriginAccountApi(this.callbackOrigin);
  @override
  final String callbackOrigin;
}

/// A real DshAccountApi/mux, with explicit ready and account-watch frames.
class _AccountCarrier extends FakePluginCarrier {
  _AccountCarrier() {
    handlers['account/getState'] = (_) => snapshot;
    handlers['account/startSignIn'] = (_) => snapshot = waiting;
    handlers['account/cancelSignIn'] = (args) => {
      'status': 'signed-out',
      'attempt': {'id': args['attemptId'], 'phase': 'cancelled'},
    };
  }

  static const waiting = {
    'status': 'signed-out',
    'attempt': {'id': 'att-1', 'phase': 'waiting-browser', 'authorizeUrl': authorizeUrl},
  };
  Map<String, Object?> snapshot = {'status': 'signed-out'};
  final links = <_AccountLink>[];

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final next = _AccountLink(this, links.length);
    links.add(next);
    return next;
  }
}

class _AccountLink extends FakeMuxLink {
  _AccountLink(this.carrier, this.index);
  final _AccountCarrier carrier;
  final int index;
  late DshMuxFrameHandler frame;
  String? events;
  String? account;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      events = streamId;
      if (index == 0) scheduleMicrotask(ready);
    } else if (endpoint == 'account/watch') {
      account = streamId;
      if (index == 0) scheduleMicrotask(confirm);
    }
  }

  void ready() => frame({
    'type': 'item',
    'streamId': events!,
    'value': {
      'type': 'ready',
      'clientId': 'auth-generation-$index',
      'host': {'home': '/root'},
    },
  });

  void confirm() => frame({'type': 'item', 'streamId': account!, 'value': carrier.snapshot});
}

Future<void> flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    BrowserLinks.openPage = null;
    BrowserLinks.openAuthorization = null;
  });

  test('DeepSeek uses an ephemeral attempt, watches success while the page is open, retires its callback', () async {
    final api = FakeAccountApi();
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: const EmbeddedAccountBrowser()),
    );
    addTearDown(container.dispose);
    container.listen(accountProvider, (_, _) {});
    await flush();
    final opened = <BrowserAuthorization>[];
    BrowserLinks.openAuthorization = (request) async {
      opened.add(request);
      return true;
    };
    BrowserLinks.openPage = (_) async => fail('authorization must not enter ordinary history');
    final account = container.read(accountProvider.notifier);
    final result = account.signIn();
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
    await flush();
    final request = opened.single;
    expect(request.callbackOrigin, Uri.parse(api.callbackOrigin));
    expect(request.isCurrent(), isTrue);
    await account.reopenBrowser();
    expect(opened.last.id, same(request.id));
    api.emit(signedInView(attempt: attempt(SignInPhase.succeeded)));
    expect(await result, SignInResult.success);
    await request.completed;
    expect(request.isCurrent(), isFalse);
    await request.cancel();
    expect(api.calls.where((call) => call.startsWith('cancelSignIn')), isEmpty);
  });

  test('closing a temporary DeepSeek page cancels only that attempt', () async {
    final api = FakeAccountApi();
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: const EmbeddedAccountBrowser()),
    );
    addTearDown(container.dispose);
    container.listen(accountProvider, (_, _) {});
    await flush();
    late BrowserAuthorization request;
    BrowserLinks.openAuthorization = (value) async {
      request = value;
      return true;
    };
    final result = container.read(accountProvider.notifier).signIn();
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
    await flush();
    await request.cancel();
    expect(await result, SignInResult.cancelled);
    await request.completed;
    expect(request.isCurrent(), isFalse);
    expect(api.calls, contains('cancelSignIn:att-1'));
  });

  test('relay login uses the temporary page and completes without waiting for a route pop', () async {
    final relay = FakeRelayBackend();
    final container = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(MemorySecretStore()),
        relayBackendProvider.overrideWithValue(relay),
      ],
    );
    addTearDown(container.dispose);
    await container.read(relayAccountProvider.future);
    final opened = Completer<BrowserAuthorization>();
    BrowserLinks.openAuthorization = (request) async {
      opened.complete(request);
      return true;
    };
    final result = container.read(relayAccountProvider.notifier).login(providerId: 'github');
    final request = await opened.future;
    expect(request.callbackOrigin, isNull);
    expect(request.isCurrent(), isTrue);
    relay.pendingLogin!.complete(sampleRelayUser);
    await result;
    await request.completed;
    expect(container.read(relayAccountProvider).value!.signedIn, isTrue);
    expect(request.isCurrent(), isFalse);
  });

  for (final sameUrl in [true, false]) {
    test('replacement attempt retires its predecessor and opens again (same URL: $sameUrl)', () async {
      final api = FakeAccountApi();
      final browser = _RecordingAccountBrowser();
      final container = ProviderContainer(
        overrides: accountOverrides(api: api, browser: browser),
      );
      addTearDown(container.dispose);
      container.listen(accountProvider, (_, _) {});
      await flush();
      final account = container.read(accountProvider.notifier);
      final result = account.signIn();
      await flush();
      api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
      await flush();
      final first = browser.requests.single;
      var firstEnded = false;
      var runEnded = false;
      unawaited(first.completed.then((_) => firstEnded = true));
      unawaited(result.then((_) => runEnded = true));

      final nextUrl = sameUrl ? authorizeUrl : 'https://platform.deepseek.com/dsh/authorize?authorize_id=a-2';
      api.emit(
        signedOutView(
          attempt: attempt(SignInPhase.waitingBrowser, id: 'att-2', url: nextUrl),
        ),
      );
      await flush();
      expect(firstEnded, isTrue, reason: 'the router must be notified without waiting for the whole run');
      expect(first.isCurrent(), isFalse);
      expect(runEnded, isFalse);
      expect(browser.requests, hasLength(2));
      final second = browser.requests.last;
      expect(second.id, isNot(same(first.id)));
      expect(second.url, Uri.parse(nextUrl));
      expect(second.isCurrent(), isTrue);
      await first.cancel();
      expect(api.calls.where((call) => call.startsWith('cancelSignIn')), isEmpty);
      expect(second.isCurrent(), isTrue);
      await account.reopenBrowser();
      expect(browser.requests.last.id, same(second.id), reason: 'one surface per unchanged attempt');

      api.emit(signedInView(attempt: attempt(SignInPhase.succeeded, id: 'att-2')));
      expect(await result, SignInResult.success);
      await second.completed;
      expect(second.isCurrent(), isFalse);
    });
  }

  test('replacement initializing attempt cannot reopen the previous authorize URL', () async {
    final api = FakeAccountApi();
    final browser = _RecordingAccountBrowser();
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: browser),
    );
    addTearDown(container.dispose);
    container.listen(accountProvider, (_, _) {});
    await flush();
    final account = container.read(accountProvider.notifier);
    final result = account.signIn();
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
    await flush();
    final first = browser.requests.single;
    api.emit(signedOutView(attempt: attempt(SignInPhase.initializing, id: 'att-2')));
    await flush();
    expect(first.isCurrent(), isFalse);
    expect(container.read(accountProvider).authorizeUrl, isNull);
    await account.reopenBrowser();
    expect(browser.requests, hasLength(1));
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser, id: 'att-2')));
    await flush();
    expect(browser.requests, hasLength(2));
    expect(browser.requests.last.id, isNot(same(first.id)));
    await account.cancel();
    expect(await result, SignInResult.cancelled);
  });

  test('late browser-open failure from an old attempt cannot change its replacement', () async {
    final api = FakeAccountApi();
    final browser = _RecordingAccountBrowser();
    final opened = Completer<bool>();
    browser.onAuthorize = (_) => browser.requests.length == 1 ? opened.future : Future.value(true);
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: browser),
    );
    addTearDown(container.dispose);
    container.listen(accountProvider, (_, _) {});
    await flush();
    final account = container.read(accountProvider.notifier);
    final result = account.signIn();
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser, id: 'att-2')));
    await flush();
    expect(browser.requests, hasLength(2));
    opened.complete(false);
    await flush();
    expect(container.read(accountProvider).browserHint, BrowserHint.none);
    expect(browser.requests.last.isCurrent(), isTrue);
    await account.cancel();
    expect(await result, SignInResult.cancelled);
  });

  test('pending cancellation of an old attempt cannot settle the replacement attempt', () async {
    final api = FakeAccountApi();
    final browser = _RecordingAccountBrowser();
    final cancelled = Completer<AccountView>();
    api.onCancel = (_) => cancelled.future;
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: browser),
    );
    addTearDown(container.dispose);
    container.listen(accountProvider, (_, _) {});
    await flush();
    final account = container.read(accountProvider.notifier);
    final result = account.signIn();
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
    await flush();
    final first = browser.requests.single;
    final closing = first.cancel();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser, id: 'att-2')));
    await flush();
    expect(browser.requests, hasLength(2));
    cancelled.complete(signedOutView(attempt: attempt(SignInPhase.cancelled)));
    await closing;
    expect(container.read(accountProvider).attemptId, 'att-2');
    expect(browser.requests.last.isCurrent(), isTrue);
    expect(api.calls.where((call) => call.startsWith('cancelSignIn')), ['cancelSignIn:att-1']);
    api.emit(signedInView(attempt: attempt(SignInPhase.succeeded, id: 'att-2')));
    expect(await result, SignInResult.success);
  });

  test('API replacement retires authorization even when attempt ID and URL are unchanged', () async {
    final api = FakeAccountApi();
    final browser = _RecordingAccountBrowser();
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: browser),
    );
    addTearDown(container.dispose);
    container.listen(accountProvider, (_, _) {});
    await flush();
    final account = container.read(accountProvider.notifier);
    final result = account.signIn();
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
    await flush();
    final first = browser.requests.single;
    var ended = false;
    unawaited(first.completed.then((_) => ended = true));
    final replacement = FakeAccountApi(initial: api.current);
    container.read(apiSwitchProvider.notifier).set(replacement);
    await flush();
    expect(ended, isTrue);
    expect(first.isCurrent(), isFalse);
    expect(browser.requests, hasLength(2));
    expect(browser.requests.last.id, isNot(same(first.id)));
    expect(browser.requests.last.isCurrent(), isTrue);
    await first.cancel();
    expect(replacement.calls.where((call) => call.startsWith('cancelSignIn')), isEmpty);
    replacement.emit(signedInView(attempt: attempt(SignInPhase.succeeded)));
    expect(await result, SignInResult.success);
  });

  test('mux replacement retires the page and waits for a fresh account view before reopening', () async {
    final carrier = _AccountCarrier();
    final client = DshClient.withCarrier(carrier, muxOptions: const MuxOptions(retryCaps: [Duration.zero]));
    final api = DshAccountApi(client, callbackOrigin: 'http://127.0.0.1:3080');
    final browser = _RecordingAccountBrowser();
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: browser),
    );
    addTearDown(() async {
      container.dispose();
      await client.close();
    });
    container.listen(accountProvider, (_, _) {});
    await flush();
    final account = container.read(accountProvider.notifier);
    final result = account.signIn();
    await flush();
    final first = browser.requests.single;
    var ended = false;
    unawaited(first.completed.then((_) => ended = true));
    client.mux.reconnect();
    expect(first.isCurrent(), isFalse, reason: 'reject even before the asynchronous mux-state notification');
    await first.cancel();
    await flush();
    expect(ended, isTrue);
    expect(carrier.links, hasLength(2));
    await account.reopenBrowser();
    expect(browser.requests, hasLength(1));
    carrier.links.last.ready();
    await flush();
    await account.reopenBrowser();
    expect(browser.requests, hasLength(1), reason: 'a ready connection is not a fresh account snapshot');
    carrier.links.last.confirm();
    await flush();
    expect(browser.requests, hasLength(2));
    final second = browser.requests.last;
    expect(second.id, isNot(same(first.id)));
    expect(second.isCurrent(), isTrue);
    await first.cancel();
    expect(carrier.argsOf('account/cancelSignIn'), isEmpty);
    await second.cancel();
    expect(await result, SignInResult.cancelled);
    expect(carrier.argsOf('account/cancelSignIn'), [
      {'attemptId': 'att-1'},
    ]);
  });

  test('provider disposal completes the authorization independently of its pending opener', () async {
    final api = FakeAccountApi();
    final browser = _RecordingAccountBrowser();
    final opened = Completer<bool>();
    browser.onAuthorize = (_) => opened.future;
    final container = ProviderContainer(
      overrides: accountOverrides(api: api, browser: browser),
    );
    container.listen(accountProvider, (_, _) {});
    await flush();
    final result = container.read(accountProvider.notifier).signIn();
    await flush();
    api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
    await flush();
    final request = browser.requests.single;
    container.dispose();
    await request.completed;
    expect(await result, SignInResult.cancelled);
    expect(request.isCurrent(), isFalse);
    await request.cancel();
    opened.complete(false);
    await flush();
    expect(api.calls.where((call) => call.startsWith('cancelSignIn')), isEmpty);
  });

  test('only exact IPv4 loopback HTTP origins with valid explicit ports use the embedded page', () async {
    for (final (origin, embedded) in [
      ('http://127.0.0.1:3080', true),
      ('http://127.0.0.1:3080/', true),
      ('http://127.0.0.1:1', true),
      ('http://127.0.0.1:80', true),
      ('http://127.0.0.1:65535', true),
      ('http://localhost:3080', false),
      ('http://[::1]:3080', false),
      ('http://127.0.0.1', false),
      ('http://127.0.0.1:0', false),
      ('http://127.0.0.1:65536', false),
      ('http://127.0.0.1:03080', false),
      ('https://127.0.0.1:3080', false),
      ('http://127.0.0.2:3080', false),
      ('http://127.0.0.1:3080/oauth/callback', false),
      ('http://user@127.0.0.1:3080', false),
      ('http://@127.0.0.1:3080', false),
      ('http://127.0.0.1:3080?token=private', false),
      ('http://127.0.0.1:3080#', false),
    ]) {
      final api = _OriginAccountApi(origin);
      final browser = _RecordingAccountBrowser();
      final container = ProviderContainer(
        overrides: accountOverrides(api: api, browser: browser),
      );
      try {
        container.listen(accountProvider, (_, _) {});
        await flush();
        final account = container.read(accountProvider.notifier);
        final result = account.signIn();
        await flush();
        api.emit(signedOutView(attempt: attempt(SignInPhase.waitingBrowser)));
        await flush();
        final request = browser.requests.single;
        expect(request.preferSystem, !embedded, reason: origin);
        expect(request.url, Uri.parse(authorizeUrl), reason: 'fallback must retain the original authorize URL');
        expect(request.callbackOrigin, Uri.tryParse(origin));
        await account.cancel();
        expect(await result, SignInResult.cancelled);
        await request.completed;
      } finally {
        container.dispose();
      }
    }
  });
}
