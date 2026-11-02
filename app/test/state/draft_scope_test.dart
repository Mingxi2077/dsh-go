import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/pets/pet_signals.dart' show petPendingProvider;
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/star_prompt.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  void set(HostRef host) => state = host;
}

class _Session extends CurrentSessionController {
  @override
  String? build() => null;

  void set(String? sessionId) => state = sessionId;
}

class _IdlePhone extends PhoneTaskSeenController {
  @override
  ({bool active, Duration? lastActive}) build() => (active: false, lastActive: null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const aHost = 'local:local';
  const bHost = 'ssh:pc';

  test('storage keys distinguish hosts, new chats, literal new ids and embedded delimiters', () {
    final keys = [
      for (final host in [aHost, bHost])
        for (final session in [null, 'new', 'same']) draftStorageKey(hostKey: host, sessionId: session),
      draftStorageKey(hostKey: 'ssh:a:b', sessionId: 'c'),
      draftStorageKey(hostKey: 'ssh:a', sessionId: 'b:c'),
    ];
    expect(keys.toSet(), hasLength(keys.length));
    expect(draftStorageKey(hostKey: aHost, sessionId: 'same'), draftStorageKey(hostKey: aHost, sessionId: 'same'));
  });

  for (final session in <String?>[null, 'same']) {
    test('A/B text, attachments and quotes stay separate for session=$session', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final store = container.read(draftStoreProvider.notifier);
      final quotes = container.read(composerQuoteProvider.notifier);
      final a = draftStorageKey(hostKey: aHost, sessionId: session);
      final b = draftStorageKey(hostKey: bHost, sessionId: session);
      final fileA = DraftAttachment(name: 'A.txt', bytes: Uint8List.fromList([1]));
      final fileB = DraftAttachment(name: 'B.txt', bytes: Uint8List.fromList([2]));
      store.save(a, 'A private reference', [fileA]);
      store.save(b, 'B private reference', [fileB]);
      quotes.set(a, 'A quoted passage');
      quotes.set(b, 'B quoted passage');
      await store.flush();

      final drafts = container.read(draftStoreProvider).drafts;
      expect(drafts[a]?.text, 'A private reference');
      expect(drafts[a]?.attachments, [fileA]);
      expect(drafts[b]?.text, 'B private reference');
      expect(drafts[b]?.attachments, [fileB]);
      expect(container.read(composerQuoteProvider), {a: 'A quoted passage', b: 'B quoted passage'});

      store.clear(a);
      quotes.clear(a);
      expect(container.read(draftStoreProvider).drafts[a], isNull);
      expect(container.read(draftStoreProvider).drafts[b]?.text, 'B private reference');
      expect(container.read(draftStoreProvider).drafts[b]?.attachments, [fileB]);
      expect(container.read(composerQuoteProvider), {b: 'B quoted passage'});
    });
  }

  test('moving A new-chat quote preserves B new-chat and same-id quotes', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final quotes = container.read(composerQuoteProvider.notifier);
    final aNew = draftStorageKey(hostKey: aHost, sessionId: null);
    final a = draftStorageKey(hostKey: aHost, sessionId: 'same');
    final bNew = draftStorageKey(hostKey: bHost, sessionId: null);
    final b = draftStorageKey(hostKey: bHost, sessionId: 'same');
    quotes.set(aNew, 'A new quote');
    quotes.set(bNew, 'B new quote');
    quotes.set(b, 'B session quote');
    quotes.move(aNew, a);
    expect(container.read(composerQuoteProvider), {a: 'A new quote', bNew: 'B new quote', b: 'B session quote'});
  });

  test('v2 restores A/B sessions and new chats without mixing or changing legacy v1', () async {
    final legacy = jsonEncode({
      'same': {'t': 'legacy private session', 'at': 1},
      'new': {'t': 'legacy private new chat', 'at': 2},
    });
    SharedPreferences.setMockInitialValues({'chat_drafts_v1': legacy});
    final expected = {
      for (final host in [aHost, bHost])
        for (final session in <String?>[null, 'same'])
          draftStorageKey(hostKey: host, sessionId: session): '$host / $session',
    };
    final first = ProviderContainer();
    try {
      final store = first.read(draftStoreProvider.notifier);
      final file = DraftAttachment(name: 'private.txt', bytes: Uint8List.fromList([1, 2, 3]));
      for (final entry in expected.entries) {
        store.save(entry.key, entry.value, [file]);
      }
      await store.flush();
    } finally {
      first.dispose();
    }

    expect(DraftStore.preferenceKey, 'chat_drafts_v2');
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString(DraftStore.preferenceKey)!) as Map;
    expect(saved.keys, unorderedEquals(expected.keys));
    expect(prefs.getString('chat_drafts_v1'), legacy);

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(draftStoreProvider.notifier).flush();
    final state = restored.read(draftStoreProvider);
    expect(state.loaded, isTrue);
    expect({for (final e in state.drafts.entries) e.key: e.value.text}, expected);
    expect(state.drafts.values.every((draft) => draft.attachments.isEmpty), isTrue);
    expect(prefs.getString('chat_drafts_v1'), legacy);
  });

  test('legacy v1 alone is never assigned to either host or copied into v2', () async {
    final legacy = jsonEncode({
      'same': {'t': 'unknown owner session', 'at': 1},
      'new': {'t': 'unknown owner new chat', 'at': 2},
    });
    SharedPreferences.setMockInitialValues({'chat_drafts_v1': legacy});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(draftStoreProvider.notifier).flush();
    expect(container.read(draftStoreProvider).loaded, isTrue);
    expect(container.read(draftStoreProvider).drafts, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('chat_drafts_v1'), legacy);
    expect(jsonDecode(prefs.getString(DraftStore.preferenceKey)!), isEmpty);
  });

  test('editing A before v2 restore preserves B with the same session id', () async {
    final a = draftStorageKey(hostKey: aHost, sessionId: 'same');
    final b = draftStorageKey(hostKey: bHost, sessionId: 'same');
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        a: {'t': 'saved A', 'at': 1},
        b: {'t': 'saved B', 'at': 2},
      }),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(draftStoreProvider.notifier);
    store.save(a, 'new A', const []);
    await store.flush();
    expect(container.read(draftStoreProvider).drafts[a]?.text, 'new A');
    expect(container.read(draftStoreProvider).drafts[b]?.text, 'saved B');
  });

  for (final session in <String?>[null, 'same']) {
    test('star prompt reads only the active host draft for session=$session', () async {
      final container = ProviderContainer(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          currentSessionProvider.overrideWith(_Session.new),
          phoneTaskSeenProvider.overrideWith(_IdlePhone.new),
          petPendingProvider.overrideWithValue(const []),
        ],
      );
      addTearDown(container.dispose);
      (container.read(currentSessionProvider.notifier) as _Session).set(session);
      final hosts = container.read(activeHostProvider.notifier) as _Host;
      final store = container.read(draftStoreProvider.notifier);
      final a = draftStorageKey(hostKey: aHost, sessionId: session);
      final b = draftStorageKey(hostKey: bHost, sessionId: session);
      store.save(a, 'A private draft', const []);
      await store.flush();
      final subscription = container.listen(starPromptSceneProvider, (_, _) {});
      addTearDown(subscription.close);
      expect(container.read(starPromptSceneProvider).composing, isTrue);
      hosts.set(const HostRef.ssh('pc'));
      expect(container.read(starPromptSceneProvider).composing, isFalse);
      store.save(b, '', [
        DraftAttachment(name: 'B.txt', bytes: Uint8List.fromList([2])),
      ]);
      expect(container.read(starPromptSceneProvider).composing, isTrue);
      hosts.set(HostRef.local);
      store.clear(a);
      expect(container.read(starPromptSceneProvider).composing, isFalse);
      expect(container.read(draftStoreProvider).drafts[b]?.attachments, hasLength(1));
    });
  }
}
