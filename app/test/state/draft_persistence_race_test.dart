// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/draft_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences() : super.empty();

  Completer<void>? gate;
  final entered = Completer<void>();
  int writes = 0;
  bool fail = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final hold = gate;
    gate = null;
    writes++;
    if (!entered.isCompleted) entered.complete();
    if (hold != null) await hold.future;
    if (fail) {
      fail = false;
      throw StateError('controlled disk error');
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = draftStorageKey(hostKey: 'local:local', sessionId: 'a');
  final other = draftStorageKey(hostKey: 'ssh:other', sessionId: 'a');
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  for (final action in ['clear', 'type then erase', 'clear then type']) {
    test('$action before startup restoration never resurrects the old draft', () async {
      SharedPreferences.setMockInitialValues({
        DraftStore.preferenceKey: jsonEncode({
          key: {'t': 'old text', 'at': 1},
          other: {'t': 'other host text', 'at': 2},
        }),
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final store = c.read(draftStoreProvider.notifier);
      if (action == 'type then erase') {
        store.save(key, 'new typing', []);
        store.save(key, '', []);
      } else {
        store.clear(key);
        if (action == 'clear then type') store.save(key, 'replacement', []);
      }
      await store.flush();
      final drafts = c.read(draftStoreProvider).drafts;
      expect(drafts[key]?.text, action == 'clear then type' ? 'replacement' : isNull);
      expect(drafts[other]?.text, 'other host text');
      final persisted = jsonDecode((await SharedPreferences.getInstance()).getString(DraftStore.preferenceKey)!);
      expect(persisted[key]?['t'], action == 'clear then type' ? 'replacement' : isNull);
    });
  }

  test('unchanged empty display before restore does not erase an unseen saved draft', () async {
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        key: {'t': 'saved', 'at': 1},
      }),
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final store = c.read(draftStoreProvider.notifier);
    store.save(key, '', []);
    await store.flush();
    expect(c.read(draftStoreProvider).drafts[key]?.text, 'saved');
  });

  for (final failed in [false, true]) {
    test('overlapping draft writes preserve the latest deletion after first write failure=$failed', () async {
      final disk = _DelayedPreferences();
      SharedPreferencesStorePlatform.instance = disk;
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final store = c.read(draftStoreProvider.notifier);
      final gate = disk.gate = Completer<void>();
      disk.fail = failed;
      store.save(key, 'old pending write', []);
      final first = store.flush();
      await disk.entered.future;
      store.clear(key);
      final second = store.flush();
      await Future<void>.delayed(Duration.zero);
      final simultaneous = disk.writes;
      gate.complete();
      await Future.wait([first, second]);
      expect(simultaneous, 1, reason: 'the newer snapshot must wait for the older platform write');
      final physical = await disk.getAll();
      final saved = jsonDecode(physical['flutter.${DraftStore.preferenceKey}']! as String) as Map;
      expect(saved.containsKey(key), isFalse);
    });
  }
}
