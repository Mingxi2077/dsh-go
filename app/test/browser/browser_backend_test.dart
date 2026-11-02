import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/browser/browser_policy.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryBrowserStorage implements BrowserStorage {
  String? value;
  Future<String?>? delayedRead;
  Completer<void>? nextWrite;
  bool failWrite = false;
  final writes = <String>[];
  @override
  Future<String?> read() async => delayedRead == null ? value : await delayedRead;
  @override
  Future<void> write(String raw) async {
    final wait = nextWrite;
    nextWrite = null;
    if (wait != null) await wait.future;
    if (failWrite) throw StateError('disk');
    value = raw;
    writes.add(raw);
  }
}

void main() {
  const local = BrowserScope(hostKey: 'local:local', sessionId: 'chat');
  const remote = BrowserScope(hostKey: 'ssh:desk', sessionId: 'chat');
  final example = Uri.parse('https://example.com/docs');

  test('addresses accept public HTTP(S) and reject executable, local, credentialed and disguised IP URLs', () {
    expect(
      BrowserPolicy.parseAddress(' github.com/ccch1mneyyy/dsh-go '),
      Uri.parse('https://github.com/ccch1mneyyy/dsh-go'),
    );
    expect(BrowserPolicy.parseAddress('https://example.com/?q=hello%20world'), isNotNull);
    expect(BrowserPolicy.parseAddress('http://8.8.8.8/'), isNotNull);
    for (final raw in [
      'javascript:alert(1)',
      'data:text/html,hi',
      'file:///sdcard/key',
      'content://private/id',
      'intent://go',
      'dshgo://open/settings',
      'https://user:password@example.com',
      'https://example.com\\@localhost',
      'http://localhost:3080/?token=secret',
      'http://app.localhost.',
      'http://192.168.1.1',
      'http://10.0.1.2',
      'http://172.16.3.4',
      'http://169.254.169.254',
      'http://100.64.0.1',
      'http://[::1]',
      'http://[::ffff:127.0.0.1]',
      'http://2130706433',
      'http://127.1',
      'http://0177.0.0.1',
      'http://0x7f000001',
      'https://office.lan',
      'some search words',
      'https://example.com:0',
      'https://example.com:65536',
      'https://example.com:999999999999999999999999/',
    ]) {
      expect(BrowserPolicy.parseAddress(raw), isNull, reason: raw);
    }
    expect(
      BrowserPolicy.savedUrl(Uri.parse('https://example.com/a%3Fb?access_token=secret#code')),
      Uri.parse('https://example.com/a%3Fb'),
    );
  });

  late ProviderContainer container;
  late MemoryBrowserStorage storage;
  BrowserWorkspaceController controller() => container.read(browserWorkspaceProvider.notifier);
  setUp(() {
    storage = MemoryBrowserStorage();
    container = ProviderContainer(overrides: [browserStorageProvider.overrideWithValue(storage)]);
  });
  tearDown(() => container.dispose());

  test('equal session ids on different hosts remain isolated, including references', () async {
    final first = await controller().open(local, example);
    final second = await controller().open(remote, Uri.parse('https://github.com/'));
    expect(container.read(browserWorkspaceProvider).selectedFor(local)?.id, first.id);
    expect(container.read(browserWorkspaceProvider).selectedFor(remote)?.id, second.id);
    await controller().clear(local);
    expect(container.read(browserWorkspaceProvider).tabs.single.id, second.id);
    final inbox = container.read(browserReferenceInboxProvider.notifier);
    inbox.add(
      BrowserReference(
        scope: remote,
        content: BrowserPageContent(url: example, title: 'Reference', text: 'Data', selection: true, truncated: false),
      ),
    );
    expect(inbox.take(local), isNull);
    expect(inbox.take(remote)?.content.text, 'Data');
    expect(inbox.take(remote), isNull);
    inbox.add(
      BrowserReference(
        scope: local,
        content: BrowserPageContent(
          url: example,
          title: 'Local',
          text: 'Local data',
          selection: false,
          truncated: false,
        ),
      ),
    );
    inbox.add(
      BrowserReference(
        scope: remote,
        content: BrowserPageContent(
          url: example,
          title: 'Remote',
          text: 'Remote data',
          selection: false,
          truncated: false,
        ),
      ),
    );
    inbox.discard(local);
    expect(inbox.take(local), isNull);
    expect(inbox.take(remote)?.content.text, 'Remote data');
  });

  test('persistence stores paths and titles but never query parameters or fragments', () async {
    final tab = await controller().open(local, Uri.parse('https://example.com/doc?token=SECRET#PRIVATE'));
    await controller().updatePage(tab.id, title: 'Title\nwith control\u202e');
    expect(storage.value, isNot(contains('SECRET')));
    expect(storage.value, isNot(contains('PRIVATE')));
    final persisted = jsonDecode(storage.value!)['tabs'][0];
    expect(persisted['url'], 'https://example.com/doc');
    expect(persisted['title'], 'Title with control');
    expect(container.read(browserWorkspaceProvider).tabs.single.url!.query, 'token=SECRET');
  });

  test('opening before restore finishes retains both saved and newly opened tabs', () async {
    final pending = Completer<String?>();
    storage.delayedRead = pending.future;
    final saved = BrowserTab(id: 'old', scope: local, url: example, title: 'old', updatedAt: DateTime(2026));
    final opening = controller().open(remote, example);
    pending.complete(
      jsonEncode({
        'v': 1,
        'tabs': [saved.toJson()],
      }),
    );
    final opened = await opening;
    expect(container.read(browserWorkspaceProvider).tabs.map((t) => t.id), ['old', opened.id]);
  });

  test('a late update after closing a tab cannot recreate it', () async {
    final tab = await controller().open(local, example);
    await controller().close(tab.id);
    await controller().updatePage(tab.id, title: 'late', url: Uri.parse('https://example.com/late'));
    expect(container.read(browserWorkspaceProvider).tabs, isEmpty);
    expect(jsonDecode(storage.value!)['tabs'], isEmpty);
  });

  test('native start pages restore without becoming a web URL and navigate in the same tab', () async {
    final home = await controller().openHome(local);
    expect(home.isHome, isTrue);
    expect(home.url, isNull);
    expect((await controller().showHome(local)).id, home.id);
    expect(container.read(browserWorkspaceProvider).tabs, hasLength(1));
    final encoded = jsonDecode(storage.value!);
    expect(encoded['v'], 2);
    expect(encoded['tabs'][0]['home'], isTrue);
    expect(BrowserTab.fromJson(encoded['tabs'][0])!.isHome, isTrue);
    await controller().navigate(home.id, example);
    final tab = container.read(browserWorkspaceProvider).tabs.single;
    expect(tab.id, home.id);
    expect(tab.url, example);
    expect(tab.isHome, isFalse);
    final anotherHome = await controller().showHome(local);
    expect(anotherHome.id, isNot(home.id));
    expect(container.read(browserWorkspaceProvider).tabs, hasLength(2));
  });

  test('closed tabs undo once, close-all permits new tabs, deleted scopes reject stale undo', () async {
    final a = await controller().open(local, example);
    final b = await controller().open(remote, example);
    final closed = await controller().close(a.id);
    expect(closed!.id, a.id);
    await controller().restoreTab(closed);
    await controller().restoreTab(closed);
    expect(container.read(browserWorkspaceProvider).tabs, hasLength(2));
    await controller().closeAll(local);
    await controller().openHome(local);
    expect(container.read(browserWorkspaceProvider).tabsFor(local).single.isHome, isTrue);
    await controller().clear(local);
    await expectLater(controller().restoreTab(closed), throwsStateError);
    await expectLater(controller().openHome(local), throwsStateError);
    expect(container.read(browserWorkspaceProvider).tabs.single.id, b.id);
  });

  test('old saved pages and new saved searches restore together with selected start page', () async {
    storage.value = jsonEncode({
      'v': 1,
      'tabs': [BrowserTab(id: 'old', scope: local, url: example, title: 'Old', updatedAt: DateTime(2026)).toJson()],
    });
    await controller().ready;
    await controller().open(local, Uri.parse('https://www.bing.com/search?q=Go+browser&token=SECRET#SECRET'));
    final home = await controller().openHome(local);
    final restored = ProviderContainer(overrides: [browserStorageProvider.overrideWithValue(storage)]);
    addTearDown(restored.dispose);
    await restored.read(browserWorkspaceProvider.notifier).ready;
    final tabs = restored.read(browserWorkspaceProvider);
    expect(tabs.tabs, hasLength(3));
    expect(tabs.selectedFor(local)!.id, home.id);
    expect(tabs.selectedFor(local)!.isHome, isTrue);
    expect(tabs.tabs[1].url!.queryParameters, {'q': 'Go browser'});
    expect(storage.value, isNot(contains('SECRET')));
  });

  test('serialized writes cannot restore a closed tab over a newer snapshot', () async {
    final tab = await controller().open(local, example);
    final gate = Completer<void>();
    storage.nextWrite = gate;
    final update = controller().updatePage(tab.id, title: 'old title');
    await Future<void>.delayed(Duration.zero);
    final close = controller().close(tab.id);
    gate.complete();
    await Future.wait([update, close]);
    expect(jsonDecode(storage.value!)['tabs'], isEmpty);
  });

  test('corrupt records are skipped and persistence failure remains visible until repaired', () async {
    storage.value = jsonEncode({
      'v': 1,
      'tabs': [
        {'id': 'bad'},
        {
          ...BrowserTab(id: 'port', scope: local, url: example, title: '', updatedAt: DateTime(2026)).toJson(),
          'url': 'https://example.com:999999999999999999999999/',
        },
        BrowserTab(
          id: 'local-url',
          scope: local,
          url: Uri.parse('http://127.0.0.1:3080'),
          title: '',
          updatedAt: DateTime(2026),
        ).toJson(),
        BrowserTab(id: 'good', scope: local, url: example, title: '', updatedAt: DateTime(2026)).toJson(),
      ],
    });
    await controller().ready;
    expect(container.read(browserWorkspaceProvider).tabs.single.id, 'good');
    storage.failWrite = true;
    await controller().close('good');
    expect(container.read(browserWorkspaceProvider).persistenceFailed, isTrue);
    storage.failWrite = false;
    await controller().flush();
    expect(container.read(browserWorkspaceProvider).persistenceFailed, isFalse);
  });

  test('tab limit rejects a new tab without evicting existing work', () async {
    for (var i = 0; i < BrowserWorkspaceController.maxTabsPerScope; i++) {
      await controller().open(local, example.replace(path: '/$i'));
    }
    await expectLater(controller().open(local, example), throwsStateError);
    expect(container.read(browserWorkspaceProvider).tabsFor(local).length, BrowserWorkspaceController.maxTabsPerScope);
  });
}
