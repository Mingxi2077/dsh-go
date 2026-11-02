import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final legacyRaw = jsonEncode({
    'same': {'t': 'Unassigned private text', 'at': 1},
    'new': {'t': 'Unassigned new-chat text', 'at': 2},
    'empty': {'t': '  ', 'at': 3},
  });
  setUp(() => SharedPreferences.setMockInitialValues({DraftStore.legacyPreferenceKey: legacyRaw}));

  test('legacy texts are read-only, unassigned and survive normal v2 mutations', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final state = container.read(draftStoreProvider);
    expect(state.loaded, isTrue);
    expect(state.drafts, isEmpty);
    expect(state.legacyDrafts['same']?.text, 'Unassigned private text');
    expect(state.legacyDrafts['new']?.text, 'Unassigned new-chat text');
    expect(state.legacyDrafts['same']?.updatedAt, DateTime.fromMillisecondsSinceEpoch(1));
    expect(() => state.legacyDrafts.clear(), throwsUnsupportedError);

    final key = draftStorageKey(hostKey: 'ssh:A', sessionId: 'same');
    store.save(key, 'new scoped text', const []);
    store.clear(key);
    store.forget(key);
    await store.flush();
    expect(container.read(draftStoreProvider).legacyDrafts, same(state.legacyDrafts));
    expect(container.read(draftStoreProvider).drafts, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DraftStore.legacyPreferenceKey), legacyRaw);
    expect(jsonDecode(prefs.getString(DraftStore.preferenceKey)!), isEmpty);
  });

  for (final session in <String?>[null, 'same']) {
    test('confirmed import appends to latest A draft, preserves attachments/B/quotes and persists: $session', () async {
      final container = ProviderContainer();
      final a = draftStorageKey(hostKey: 'ssh:A', sessionId: session);
      final b = draftStorageKey(hostKey: 'ssh:B', sessionId: session);
      final legacyKey = session ?? 'new';
      String? preview;
      try {
        final store = container.read(draftStoreProvider.notifier);
        await store.flush();
        preview = container.read(draftStoreProvider).legacyDrafts[legacyKey]!.text;
        final file = DraftAttachment(name: 'A.txt', bytes: Uint8List.fromList([1, 2]));
        store.save(a, 'edited while preview is open', [file]);
        store.save(b, 'B private draft', const []);
        container.read(composerQuoteProvider.notifier).set(a, 'A quote');
        container.read(composerQuoteProvider.notifier).set(b, 'B quote');
        final quotes = container.read(composerQuoteProvider);

        expect(store.importLegacy(legacyKey: legacyKey, expectedText: preview, targetKey: a), isTrue);
        final drafts = container.read(draftStoreProvider).drafts;
        expect(drafts[a]?.text, 'edited while preview is open\n\n$preview');
        expect(drafts[a]?.attachments, [file]);
        expect(drafts[b]?.text, 'B private draft');
        expect(container.read(composerQuoteProvider), same(quotes));
        expect(container.read(draftStoreProvider).legacyDrafts[legacyKey]?.text, preview);
        await store.flush();
        expect((await SharedPreferences.getInstance()).getString(DraftStore.legacyPreferenceKey), legacyRaw);
      } finally {
        container.dispose();
      }

      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      await restored.read(draftStoreProvider.notifier).flush();
      expect(restored.read(draftStoreProvider).drafts[a]?.text, 'edited while preview is open\n\n$preview');
      expect(restored.read(draftStoreProvider).drafts[b]?.text, 'B private draft');
      expect(restored.read(draftStoreProvider).legacyDrafts[legacyKey]?.text, preview);
    });
  }

  test('import into an empty target uses only the confirmed text and never infers a host', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final target = draftStorageKey(hostKey: 'relay:chosen-host', sessionId: null);
    expect(store.importLegacy(legacyKey: 'same', expectedText: 'Unassigned private text', targetKey: target), isTrue);
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts.keys, [target]);
    expect(drafts[target]?.text, 'Unassigned private text');
    expect(drafts[target]?.attachments, isEmpty);
  });

  test('not-loaded, changed preview, missing, empty, unscoped and forgotten targets do not import', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(draftStoreProvider.notifier);
    final target = draftStorageKey(hostKey: 'ssh:A', sessionId: 'same');
    expect(store.importLegacy(legacyKey: 'same', expectedText: 'Unassigned private text', targetKey: target), isFalse);
    await store.flush();
    final before = container.read(draftStoreProvider);
    for (final args in [
      (legacy: 'same', text: 'different preview', target: target),
      (legacy: 'missing', text: 'Unassigned private text', target: target),
      (legacy: 'empty', text: '  ', target: target),
      (legacy: 'same', text: 'Unassigned private text', target: 'same'),
      (legacy: 'same', text: 'Unassigned private text', target: 'new'),
      (legacy: 'same', text: 'Unassigned private text', target: '[1,"ssh:A","same"]'),
      (legacy: 'same', text: 'Unassigned private text', target: '[2,"","same"]'),
    ]) {
      expect(store.importLegacy(legacyKey: args.legacy, expectedText: args.text, targetKey: args.target), isFalse);
      expect(container.read(draftStoreProvider), same(before));
    }
    store.forget(target);
    expect(store.importLegacy(legacyKey: 'same', expectedText: 'Unassigned private text', targetKey: target), isFalse);
    await store.flush();
    expect(container.read(draftStoreProvider).drafts, isEmpty);
    expect((await SharedPreferences.getInstance()).getString(DraftStore.legacyPreferenceKey), legacyRaw);
  });

  test('broken v2 cannot hide legacy recovery and malformed v1 entries do not hide valid entries', () async {
    final legacy = jsonEncode({
      'bad': {'t': 1, 'at': 'wrong'},
      'invalid-date': {'t': 'bad date', 'at': 9000000000000000},
      'good': {'t': 'recoverable', 'at': 1},
    });
    SharedPreferences.setMockInitialValues({DraftStore.preferenceKey: '{', DraftStore.legacyPreferenceKey: legacy});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(draftStoreProvider.notifier).flush();
    expect(container.read(draftStoreProvider).drafts, isEmpty);
    expect(container.read(draftStoreProvider).legacyDrafts.keys, ['good']);
    expect(container.read(draftStoreProvider).legacyDrafts['good']?.text, 'recoverable');
    expect((await SharedPreferences.getInstance()).getString(DraftStore.legacyPreferenceKey), legacy);
  });

  test('broken v1 cannot hide v2 drafts and is preserved verbatim', () async {
    final target = draftStorageKey(hostKey: 'ssh:A', sessionId: 'same');
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        target: {'t': 'scoped', 'at': 1},
      }),
      DraftStore.legacyPreferenceKey: '{',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(draftStoreProvider.notifier).flush();
    expect(container.read(draftStoreProvider).drafts[target]?.text, 'scoped');
    expect(container.read(draftStoreProvider).legacyDrafts, isEmpty);
    expect((await SharedPreferences.getInstance()).getString(DraftStore.legacyPreferenceKey), '{');
  });
}
