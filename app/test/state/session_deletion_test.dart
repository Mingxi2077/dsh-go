import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/session_deletion_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';
import 'read_list_refresh_test.dart' show SwitchConnection, switchConnectionProvider;

class _SwitchHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  void set(HostRef host) => state = host;
}

class _Backend implements SessionDeletionBackend {
  bool support = true;
  final calls = <String>[];
  final failures = <String, Object>{};
  final gates = <String, Completer<void>>{};
  void Function(String)? afterDelete;

  @override
  Future<bool> supported(DshClient client) async => support;
  @override
  Future<void> delete(DshClient client, String sessionId) async {
    calls.add(sessionId);
    if (gates[sessionId] case final gate?) await gate.future;
    if (failures[sessionId] case final error?) throw error;
    afterDelete?.call(sessionId);
  }
}

class _BrowserStorage implements BrowserStorage {
  String? value;
  bool failWrite = false;
  Completer<void>? nextWrite;
  Completer<void>? writeStarted;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    final pending = nextWrite;
    nextWrite = null;
    if (pending != null) {
      writeStarted?.complete();
      await pending.future;
    }
    if (failWrite) throw StateError('browser_storage_failed');
    this.value = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ProviderContainer, FakeWorkspaceHost, _Backend)> start({bool running = false}) async {
    final host = FakeWorkspaceHost();
    host.seedSession('s1', 'First', DateTime.now(), running: running);
    host.seedSession('s2', 'Second', DateTime.now());
    final connection = workspaceHost(host);
    await connection.client.mux.start();
    final backend = _Backend();
    final container = ProviderContainer(
      overrides: [
        switchConnectionProvider.overrideWith(() => SwitchConnection(connection)),
        activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        activeHostProvider.overrideWith(_SwitchHost.new),
        readListIdentityProvider.overrideWithValue(null),
        sessionDeletionBackendProvider.overrideWithValue(backend),
        browserStorageProvider.overrideWithValue(_BrowserStorage()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await connection.client.close();
    });
    await container.read(sessionsProvider.future);
    await container.read(drawerViewProvider.notifier).ready();
    backend.afterDelete = (id) => host.sessions.removeWhere((s) => s['sessionId'] == id);
    return (container, host, backend);
  }

  SessionDeletionOwner owner(ProviderContainer container) {
    final value = SessionDeletionOwner.capture(container)!;
    addTearDown(value.close);
    return value;
  }

  test('only acknowledged rows, selection and drafts are cleared; failed row stays', () async {
    final (container, _, backend) = await start();
    final drafts = container.read(draftStoreProvider.notifier);
    final firstKey = draftStorageKey(hostKey: 'local:local', sessionId: 's1');
    final secondKey = draftStorageKey(hostKey: 'local:local', sessionId: 's2');
    drafts.save(firstKey, 'private draft', const []);
    drafts.save(secondKey, 'keep draft', const []);
    container.read(composerQuoteProvider.notifier).set(firstKey, 'quote');
    container.read(currentSessionProvider.notifier).select('s1');
    await container.read(drawerViewProvider.notifier).createFolder('Folder', sessionIds: ['s1', 's2']);
    backend.failures['s2'] = const DshRemoteException('writer-held', 'private details');
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(result.deleted, ['s1']);
    expect(result.failures, {'s2': 'writer-held'});
    expect(result.retired, isFalse);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s2']);
    expect(container.read(currentSessionProvider), isNull);
    expect(container.read(draftStoreProvider).drafts.containsKey(firstKey), isFalse);
    expect(container.read(draftStoreProvider).drafts[secondKey]?.text, 'keep draft');
    expect(container.read(composerQuoteProvider).containsKey(firstKey), isFalse);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, ['s2']);
    expect(container.read(sessionDeletionBusyProvider), isFalse);
  });

  test('deleting A preserves B with the same session id and both new-chat drafts and quotes', () async {
    final (container, _, _) = await start();
    final drafts = container.read(draftStoreProvider.notifier);
    final quotes = container.read(composerQuoteProvider.notifier);
    final a = draftStorageKey(hostKey: 'local:local', sessionId: 's1');
    final b = draftStorageKey(hostKey: 'ssh:pc', sessionId: 's1');
    final aNew = draftStorageKey(hostKey: 'local:local', sessionId: null);
    final bNew = draftStorageKey(hostKey: 'ssh:pc', sessionId: null);
    final expected = {a: 'A session', b: 'B session', aNew: 'A new', bNew: 'B new'};
    for (final entry in expected.entries) {
      drafts.save(entry.key, entry.value, const []);
      quotes.set(entry.key, 'quote ${entry.value}');
    }
    await drafts.flush();

    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.deleted, ['s1']);
    expect(result.failures, isEmpty);
    expected.remove(a);
    expect({for (final e in container.read(draftStoreProvider).drafts.entries) e.key: e.value.text}, expected);
    expect(container.read(composerQuoteProvider), {for (final e in expected.entries) e.key: 'quote ${e.value}'});

    drafts.save(a, 'late A save', const []);
    drafts.save(b, 'B remains writable', const []);
    await drafts.flush();
    expect(container.read(draftStoreProvider).drafts[a], isNull);
    expect(container.read(draftStoreProvider).drafts[b]?.text, 'B remains writable');
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString(DraftStore.preferenceKey)!) as Map;
    expect(saved.containsKey(a), isFalse);
    expect(saved[b]['t'], 'B remains writable');
    expect(saved[aNew]['t'], 'A new');
    expect(saved[bNew]['t'], 'B new');
  });

  test('running row and pending archive never reach destructive backend', () async {
    final (container, _, backend) = await start(running: true);
    final pending = container.read(sessionsProvider.notifier).scheduleArchive(['s2']);
    addTearDown(pending.release);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(result.failures, {'s1': 'session-active', 's2': 'archive-pending'});
    expect(backend.calls, isEmpty);
    pending.cancel();
  });

  test('deleting A frees tab capacity and discards only its browser references, preserving B same-id scope', () async {
    final (container, _, _) = await start();
    final browser = container.read(browserWorkspaceProvider.notifier);
    final inbox = container.read(browserReferenceInboxProvider.notifier);
    const a = BrowserScope(hostKey: 'local:local', sessionId: 's1');
    const b = BrowserScope(hostKey: 'ssh:pc', sessionId: 's1');
    const aNew = BrowserScope(hostKey: 'local:local');
    const bNew = BrowserScope(hostKey: 'ssh:pc');
    const aOther = BrowserScope(hostKey: 'local:local', sessionId: 's2');
    final url = Uri.parse('https://example.com/');
    const scopes = [a, b, aNew, bNew, aOther];
    for (var i = 0; i < BrowserWorkspaceController.maxTabs; i++) {
      await browser.open(scopes[i % scopes.length], url.replace(path: '/$i'));
    }
    for (final scope in scopes) {
      inbox.add(
        BrowserReference(
          scope: scope,
          content: BrowserPageContent(
            url: url,
            title: 'Reference',
            text: scope.key,
            selection: false,
            truncated: false,
          ),
        ),
      );
    }
    const extra = BrowserScope(hostKey: 'ssh:extra', sessionId: 'extra');
    await expectLater(browser.open(extra, url), throwsStateError);
    final before = container.read(browserWorkspaceProvider);
    final kept = before.tabs.where((tab) => tab.scope != a).map((tab) => tab.id).toList();

    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.deleted, ['s1']);
    expect(result.failures, isEmpty);
    final after = container.read(browserWorkspaceProvider);
    expect(after.tabs.map((tab) => tab.id), kept);
    expect(after.activeIds, {...before.activeIds}..remove(a.key));
    expect(inbox.take(a), isNull);
    for (final scope in [b, aNew, bNew, aOther]) {
      expect(inbox.take(scope)?.content.text, scope.key);
    }
    final persisted = jsonDecode((container.read(browserStorageProvider) as _BrowserStorage).value!) as Map;
    expect((persisted['tabs'] as List).map((tab) => tab['id']), kept);
    expect((await browser.open(extra, url)).scope, extra);
  });

  test('browser persistence failure preserves acknowledged deletion and remaining local cleanup', () async {
    final (container, _, _) = await start();
    const a = BrowserScope(hostKey: 'local:local', sessionId: 's1');
    const b = BrowserScope(hostKey: 'ssh:pc', sessionId: 's1');
    final browser = container.read(browserWorkspaceProvider.notifier);
    final url = Uri.parse('https://example.com/');
    await browser.open(a, url);
    final kept = await browser.open(b, url);
    await container.read(drawerViewProvider.notifier).createFolder('Folder', sessionIds: ['s1', 's2']);
    (container.read(browserStorageProvider) as _BrowserStorage).failWrite = true;

    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.deleted, ['s1']);
    expect(result.failures, isEmpty);
    expect(container.read(browserWorkspaceProvider).tabs.single.id, kept.id);
    expect(container.read(browserWorkspaceProvider).persistenceFailed, isTrue);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, ['s2']);
    expect(container.read(sessionsProvider).value!.map((session) => session.sessionId), ['s2']);
  });

  test('host departure during browser cleanup cannot delete B tabs or references or continue the batch', () async {
    final (container, _, backend) = await start();
    const a = BrowserScope(hostKey: 'local:local', sessionId: 's1');
    const b = BrowserScope(hostKey: 'ssh:pc', sessionId: 's1');
    final browser = container.read(browserWorkspaceProvider.notifier);
    final inbox = container.read(browserReferenceInboxProvider.notifier);
    final url = Uri.parse('https://example.com/');
    await browser.open(a, url);
    final kept = await browser.open(b, url);
    for (final scope in [a, b]) {
      inbox.add(
        BrowserReference(
          scope: scope,
          content: BrowserPageContent(url: url, title: '', text: scope.key, selection: false, truncated: false),
        ),
      );
    }
    final storage = container.read(browserStorageProvider) as _BrowserStorage;
    final release = Completer<void>();
    final started = Completer<void>();
    storage.nextWrite = release;
    storage.writeStarted = started;
    final deleting = container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    await started.future;
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(const HostRef.ssh('pc'));
    release.complete();
    final result = await deleting;
    expect(result.deleted, ['s1']);
    expect(result.failures, isEmpty);
    expect(result.retired, isTrue);
    expect(backend.calls, ['s1']);
    expect(container.read(browserWorkspaceProvider).tabs.single.id, kept.id);
    expect(inbox.take(a), isNull);
    expect(inbox.take(b)?.content.text, b.key);
  });

  test('unsupported Host preserves all rows and sends no deletion', () async {
    final (container, _, backend) = await start();
    backend.support = false;
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.failures, {'s1': 'unavailable'});
    expect(backend.calls, isEmpty);
    expect(container.read(sessionsProvider).value, hasLength(2));
  });

  test('host A -> B -> A irrevocably retires an old deletion authority', () async {
    final (container, _, backend) = await start();
    final captured = owner(container);
    expect(captured.current, isTrue);
    final hosts = container.read(activeHostProvider.notifier) as _SwitchHost;
    hosts.set(HostRef.ssh('pc'));
    hosts.set(HostRef.local);
    expect(captured.current, isFalse);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    expect(result.retired, isTrue);
    expect(backend.calls, isEmpty);
  });

  test('late response after owner departure cannot clear new selection or send next item', () async {
    final (container, _, backend) = await start();
    backend.gates['s1'] = Completer<void>();
    final operation = container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls, ['s1']);
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(HostRef.ssh('pc'));
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(HostRef.local);
    container.read(currentSessionProvider.notifier).select('s2');
    backend.gates['s1']!.complete();
    final result = await operation;
    expect(result.retired, isTrue);
    expect(backend.calls, ['s1']);
    expect(container.read(currentSessionProvider), 's2');
  });

  test('late success after switching to B clears only captured A scope and preserves B UI', () async {
    final (container, hostA, backend) = await start();
    const a = BrowserScope(hostKey: 'local:local', sessionId: 's1');
    const b = BrowserScope(hostKey: 'ssh:pc', sessionId: 's1');
    const aNext = BrowserScope(hostKey: 'local:local', sessionId: 's2');
    final drafts = container.read(draftStoreProvider.notifier);
    final quotes = container.read(composerQuoteProvider.notifier);
    final browser = container.read(browserWorkspaceProvider.notifier);
    final inbox = container.read(browserReferenceInboxProvider.notifier);
    final url = Uri.parse('https://example.com/');
    for (final scope in [a, b, aNext]) {
      final key = draftStorageKey(hostKey: scope.hostKey, sessionId: scope.sessionId);
      drafts.save(key, 'draft ${scope.key}', const []);
      quotes.set(key, 'quote ${scope.key}');
      await browser.open(scope, url);
      inbox.add(
        BrowserReference(
          scope: scope,
          content: BrowserPageContent(url: url, title: '', text: scope.key, selection: false, truncated: false),
        ),
      );
    }
    final before = container.read(browserWorkspaceProvider);
    final kept = before.tabs.where((tab) => tab.scope != a).map((tab) => tab.id).toList();
    final hostB = FakeWorkspaceHost();
    hostB.seedSession('s1', 'B same id', DateTime.now());
    hostB.seedSession('s2', 'B other', DateTime.now());
    final connectionB = workspaceHost(hostB);
    addTearDown(connectionB.client.close);
    await connectionB.client.mux.start();

    final reply = Completer<void>();
    backend.gates['s1'] = reply;
    final operation = container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls, ['s1']);
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(const HostRef.ssh('pc'));
    container.read(switchConnectionProvider.notifier).set(connectionB);
    container.read(currentSessionProvider.notifier).select('s1');
    final sessionsB = await container.read(sessionsProvider.future);
    await container.read(drawerViewProvider.notifier).ready();
    await container.read(drawerViewProvider.notifier).createFolder('B folder', sessionIds: ['s1', 's2']);

    reply.complete();
    final result = await operation;
    final after = container.read(browserWorkspaceProvider);
    expect(after.tabs.map((tab) => tab.id), kept);
    expect(after.activeIds, {...before.activeIds}..remove(a.key));
    expect(container.read(browserReferenceInboxProvider).map((reference) => reference.scope), [b, aNext]);
    final aKey = draftStorageKey(hostKey: a.hostKey, sessionId: a.sessionId);
    expect(container.read(draftStoreProvider).drafts[aKey], isNull);
    expect(container.read(composerQuoteProvider)[aKey], isNull);
    for (final scope in [b, aNext]) {
      final key = draftStorageKey(hostKey: scope.hostKey, sessionId: scope.sessionId);
      expect(container.read(draftStoreProvider).drafts[key]?.text, 'draft ${scope.key}');
      expect(container.read(composerQuoteProvider)[key], 'quote ${scope.key}');
    }
    expect(result.deleted, ['s1']);
    expect(result.failures, isEmpty);
    expect(result.retired, isTrue);
    expect(backend.calls, ['s1'], reason: 'the retired batch must not delete its next session');
    expect(hostA.sessions.map((session) => session['sessionId']), ['s2']);
    expect(hostB.sessions.map((session) => session['sessionId']), ['s1', 's2']);
    expect(container.read(currentSessionProvider), 's1');
    expect(container.read(sessionsProvider).value, sessionsB);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, ['s1', 's2']);
    expect(container.read(sessionDeletionBusyProvider), isFalse);

    await drafts.flush();
    final savedDrafts = jsonDecode((await SharedPreferences.getInstance()).getString(DraftStore.preferenceKey)!) as Map;
    expect(savedDrafts.containsKey(aKey), isFalse);
    expect(savedDrafts, hasLength(2));
    final savedBrowser = jsonDecode((container.read(browserStorageProvider) as _BrowserStorage).value!) as Map;
    expect((savedBrowser['tabs'] as List).map((tab) => tab['id']), kept);
  });

  test('duplicate intent is busy and does not send twice', () async {
    final (container, _, backend) = await start();
    backend.gates['s1'] = Completer<void>();
    final captured = owner(container);
    final operation = container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    await Future<void>.delayed(Duration.zero);
    final duplicate = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    expect(duplicate.failures, {'s1': 'busy'});
    expect(backend.calls, ['s1']);
    backend.gates['s1']!.complete();
    await operation;
  });

  test('lost or invalid response stops batch without retry; remaining items not attempted', () async {
    final (container, _, backend) = await start();
    backend.failures['s1'] = const DshTransportException('reply lost');
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(backend.calls, ['s1']);
    expect(result.failures, {'s1': 'connection-lost', 's2': 'not-attempted'});
    expect(container.read(sessionsProvider).value, hasLength(2));
  });

  test('late old inventory cannot resurrect a confirmed deletion', () async {
    final (container, _, backend) = await start();
    backend.afterDelete = null; // Fake stale session/list continues serving the old row.
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.deleted, ['s1']);
    await container.read(sessionsProvider.notifier).refresh();
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s2']);
  });

  test('deleted final folder member is removed even with empty remaining inventory', () async {
    final (container, _, _) = await start();
    await container.read(drawerViewProvider.notifier).createFolder('Last', sessionIds: ['s1', 's2']);
    await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(container.read(sessionsProvider).value, isEmpty);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, isEmpty);
  });

  test('late restore and outgoing screen saves cannot resurrect a forgotten draft', () async {
    final a = draftStorageKey(hostKey: 'local:local', sessionId: 's1');
    final b = draftStorageKey(hostKey: 'ssh:pc', sessionId: 's1');
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        a: {'t': 'saved A', 'at': 1},
        b: {'t': 'saved B', 'at': 2},
      }),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(draftStoreProvider.notifier);
    store.forget(a);
    store.save(a, 'outgoing screen', const []);
    await store.flush();
    expect(container.read(draftStoreProvider).drafts.containsKey(a), isFalse);
    expect(container.read(draftStoreProvider).drafts[b]?.text, 'saved B');
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(DraftStore.preferenceKey)!), {
      b: {'t': 'saved B', 'at': 2},
    });
  });
}
