import 'dart:async';

import 'package:dsh_app/browser/browser_links.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/support/fake_relay.dart';

const _google = RelayAuthProvider(id: 'google', displayName: 'Google');
const _github = RelayAuthProvider(id: 'github', displayName: 'GitHub');

class _ChangingProvidersRelay extends FakeRelayBackend {
  String? selected;
  int cancellations = 0;

  @override
  Future<List<RelayAuthProvider>> loginProviders() async => List.of(providers);

  @override
  Future<RelayLoginSession> login({String? providerId}) async {
    // Model discovery happening again when the backend creates the login.
    selected = providerId ?? providers.first.id;
    final session = await super.login(providerId: providerId);
    return RelayLoginSession(
      loginUrl: Uri.https('relay.example.com', '/login/$selected', {'state': 'attempt'}),
      completed: session.completed,
      onCancel: () {
        cancellations++;
        session.cancel();
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');

  for (final scenario in [
    (name: 'explicit Google', requested: 'google', initial: [_github, _google], expected: 'google'),
    (name: 'default Google after provider reorder', requested: null, initial: [_google, _github], expected: 'google'),
    (name: 'explicit GitHub', requested: 'github', initial: [_google, _github], expected: 'github'),
    (name: 'default GitHub after provider reorder', requested: null, initial: [_github, _google], expected: 'github'),
  ]) {
    test('${scenario.name} keeps its provider, browser policy and pending login aligned', () async {
      final previousPage = BrowserLinks.openPage;
      final previousAuthorization = BrowserLinks.openAuthorization;
      final systemCalls = <MethodCall>[];
      final authorizations = <BrowserAuthorization>[];
      final opened = Completer<void>();
      BrowserLinks.openPage = (_) async => fail('relay authorization must not enter the persistent browser');
      BrowserLinks.openAuthorization = (request) async {
        authorizations.add(request);
        if (!opened.isCompleted) opened.complete();
        return true;
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        systemCalls.add(call);
        if (!opened.isCompleted) opened.complete();
        return true;
      });
      addTearDown(() {
        BrowserLinks.openPage = previousPage;
        BrowserLinks.openAuthorization = previousAuthorization;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });

      final relay = _ChangingProvidersRelay()..providers = List.of(scenario.initial);
      final container = ProviderContainer(overrides: [relayBackendProvider.overrideWithValue(relay)]);
      addTearDown(container.dispose);
      final initial = await container.read(relayAccountProvider.future);
      expect(initial.providers.first.id, scenario.initial.first.id);
      relay.providers = scenario.initial.reversed.toList();

      final login = container.read(relayAccountProvider.notifier).login(providerId: scenario.requested);
      await opened.future.timeout(const Duration(seconds: 5));
      expect(relay.loginProviderIds, [scenario.expected], reason: 'pass the selected provider to the backend');
      expect(relay.selected, scenario.expected, reason: 'later discovery must not choose a different provider');
      final waiting = container.read(relayAccountProvider).value!;
      expect(waiting.loggingIn, isTrue);
      expect(waiting.signedIn, isFalse);
      expect(relay.pendingLogin!.isCompleted, isFalse);
      expect(relay.cancellations, 0);

      if (scenario.expected == 'google') {
        expect(authorizations, isEmpty, reason: 'Google must bypass the embedded authorization handler');
        expect(systemCalls, hasLength(1));
        final call = systemCalls.single;
        expect(call.method, 'launch');
        final arguments = call.arguments as Map;
        expect(arguments['url'], waiting.loginUrl.toString());
        expect(arguments['useWebView'], isFalse);
        expect(arguments['useSafariVC'], isFalse);
      } else {
        expect(systemCalls, isEmpty);
        final request = authorizations.single;
        expect(request.url, waiting.loginUrl);
        expect(request.preferSystem, isFalse);
        expect(request.isCurrent(), isTrue);
      }

      final user = RelayUser(id: 'signed-in', displayName: 'Test account', provider: scenario.expected);
      relay.pendingLogin!.complete(user);
      await login;
      final finished = container.read(relayAccountProvider).value!;
      expect(finished.user, same(user));
      expect(finished.loggingIn, isFalse);
      expect(finished.loginUrl, isNull);
      expect(finished.error, isNull);
      expect(finished.hosts, sampleRelayHosts);
      expect(relay.cancellations, 0, reason: 'opening either browser must not cancel a successful login');
      if (authorizations.isNotEmpty) {
        await authorizations.single.completed;
        expect(authorizations.single.isCurrent(), isFalse);
      }
    });
  }
}
