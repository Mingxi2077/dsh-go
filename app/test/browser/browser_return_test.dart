import 'dart:typed_data';

import 'package:dsh_app/browser/browser_return.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browser_backend_test.dart' show MemoryBrowserStorage;

void main() {
  const host = HostRef.local;
  const scope = BrowserScope(hostKey: 'local:local', sessionId: 'chat');
  final url = Uri.parse('https://example.com/article');
  late ProviderContainer container;
  late BrowserWorkspaceController workspace;
  late BrowserReturnController returns;
  setUp(() {
    container = ProviderContainer(overrides: [browserStorageProvider.overrideWithValue(MemoryBrowserStorage())]);
    workspace = container.read(browserWorkspaceProvider.notifier);
    returns = container.read(browserReturnProvider.notifier);
  });
  tearDown(() => container.dispose());
  bool remember(BrowserTab tab, {String sessionId = 'chat', Uint8List? preview}) =>
      returns.remember(host: host, sessionId: sessionId, tabId: tab.id, url: url, title: 'Article', preview: preview);

  test('only the exact tab and host/session can create a return tag', () async {
    final tab = await workspace.open(scope, url);
    expect(remember(tab, sessionId: 'other'), isFalse);
    expect(remember(tab), isTrue);
    expect(container.read(browserReturnProvider).itemFor(scope)?.tabId, tab.id);
    expect(
      container.read(browserReturnProvider).itemFor(const BrowserScope(hostKey: 'ssh:desk', sessionId: 'chat')),
      isNull,
    );
  });
  test('closing or deleting clears the tag, undo does not resurrect it', () async {
    final tab = await workspace.open(scope, url);
    expect(remember(tab), isTrue);
    await workspace.close(tab.id);
    expect(container.read(browserReturnProvider).itemFor(scope), isNull);
    await workspace.restoreTab(tab);
    expect(container.read(browserReturnProvider).itemFor(scope), isNull);
    expect(remember(tab), isTrue);
    await workspace.clear(scope);
    expect(container.read(browserReturnProvider).itemFor(scope), isNull);
  });
  test('dismiss only removes the side tag and oversized previews are omitted', () async {
    final tab = await workspace.open(scope, url);
    expect(remember(tab, preview: Uint8List(BrowserReturnController.maxPreviewBytes + 1)), isTrue);
    expect(container.read(browserReturnProvider).itemFor(scope)?.preview, isNull);
    returns.dismiss(scope);
    expect(container.read(browserReturnProvider).itemFor(scope), isNull);
    expect(container.read(browserWorkspaceProvider).tabs.single.id, tab.id);
  });
  test('new tabs never evict an existing return tag, previews have a separate budget', () async {
    final preview = Uint8List(BrowserReturnController.maxPreviewBytes)
      ..setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
    for (var i = 0; i < 10; i++) {
      final nextScope = BrowserScope(hostKey: 'local:local', sessionId: '$i');
      final tab = await workspace.open(nextScope, url);
      expect(remember(tab, sessionId: '$i', preview: preview), isTrue);
    }
    final state = container.read(browserReturnProvider);
    expect(state.items.length, 10);
    expect(
      state.items.values.fold<int>(0, (sum, item) => sum + (item.preview?.length ?? 0)),
      lessThanOrEqualTo(BrowserReturnController.maxTotalPreviewBytes),
    );
    expect(
      container.read(browserReturnProvider).itemFor(const BrowserScope(hostKey: 'local:local', sessionId: '0')),
      isNotNull,
    );
  });
  test('same-tab refresh deduplicates; dismissal and closing affect only that tab', () async {
    final first = await workspace.open(scope, url);
    final second = await workspace.open(scope, url);
    expect(remember(first), isTrue);
    final old = container.read(browserReturnProvider).itemFor(scope, tabId: first.id);
    expect(remember(second), isTrue);
    expect(remember(first), isTrue);
    final state = container.read(browserReturnProvider);
    expect(state.itemsFor(scope).map((item) => item.tabId), [first.id, second.id]);
    expect(identical(state.itemFor(scope, tabId: first.id), old), isFalse);
    returns.dismiss(scope, tabId: second.id);
    expect(container.read(browserReturnProvider).itemsFor(scope).single.tabId, first.id);
    expect(remember(second), isTrue);
    await workspace.close(first.id);
    expect(container.read(browserReturnProvider).itemsFor(scope).single.tabId, second.id);
  });
}
