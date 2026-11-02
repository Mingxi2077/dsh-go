import 'package:dsh_app/browser/browser_return.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/browser/browser_return_dock.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browser_widget_fakes.dart';

/// A fake CurrentSessionController that returns a fixed session ID.
class _FakeCurrentSession extends CurrentSessionController {
  _FakeCurrentSession(this.session);
  final String? session;
  @override
  String? build() => session;
}

void main() {
  const host = HostRef.local;
  const scope = BrowserScope(hostKey: 'local:local', sessionId: 'chat');

  testWidgets('expanded tags fit above a keyboard and tiny remaining space hides safely', (tester) async {
    tester.view.physicalSize = const Size(1080, 2100);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);
    Widget screen(double keyboard) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 700),
            textScaler: const TextScaler.linear(1.3),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: const BrowserReturnDock(child: Scaffold(body: SizedBox.expand())),
        ),
      ),
    );
    await tester.pumpWidget(screen(420));
    final workspace = container.read(browserWorkspaceProvider.notifier);
    for (var i = 0; i < 3; i++) {
      final url = Uri.parse('https://example.com/$i');
      final tab = await workspace.open(scope, url);
      container
          .read(browserReturnProvider.notifier)
          .remember(host: host, sessionId: 'chat', tabId: tab.id, url: url, title: 'A longer page title $i');
    }
    await tester.pumpAndSettle();
    final badge = find
        .byWidgetPredicate((w) => w is GestureDetector && w.behavior == HitTestBehavior.opaque && w.onTap != null)
        .first;
    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final panel = find.descendant(of: find.byType(BrowserReturnDock), matching: find.byType(ClipRRect)).first;
    expect(tester.getRect(panel).bottom, lessThanOrEqualTo(280));
    await tester.pumpWidget(screen(670));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows multiple return items in a list when expanded', (tester) async {
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: BrowserReturnDock(
              child: Container(key: const ValueKey('chat'), color: Colors.white),
            ),
          ),
        ),
      ),
    );

    // Remember two return items.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab1 = await workspace.open(scope, Uri.parse('https://example.com/page1'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab1.id,
      url: Uri.parse('https://example.com/page1'),
      title: 'Page One',
    );
    final tab2 = await workspace.open(scope, Uri.parse('https://example.com/page2'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab2.id,
      url: Uri.parse('https://example.com/page2'),
      title: 'Page Two',
    );

    await tester.pumpAndSettle();

    // Badge should be collapsed with a count badge showing "2".
    final countBadge = find.text('2');
    expect(countBadge, findsOneWidget);

    // Tap to expand.
    final badgeGesture = find
        .byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.behavior == HitTestBehavior.opaque && widget.onTap != null,
        )
        .first;
    await tester.tap(badgeGesture);
    await tester.pumpAndSettle();

    // Should now show a list with both items.
    expect(find.text('Page One'), findsOneWidget);
    expect(find.text('Page Two'), findsOneWidget);
  });

  testWidgets('removing one item keeps the other visible', (tester) async {
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: BrowserReturnDock(
              child: Container(key: const ValueKey('chat'), color: Colors.white),
            ),
          ),
        ),
      ),
    );

    // Remember two return items.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab1 = await workspace.open(scope, Uri.parse('https://example.com/page1'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab1.id,
      url: Uri.parse('https://example.com/page1'),
      title: 'Page One',
    );
    final tab2 = await workspace.open(scope, Uri.parse('https://example.com/page2'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab2.id,
      url: Uri.parse('https://example.com/page2'),
      title: 'Page Two',
    );

    await tester.pumpAndSettle();

    // Expand the list.
    final badgeGesture = find
        .byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.behavior == HitTestBehavior.opaque && widget.onTap != null,
        )
        .first;
    await tester.tap(badgeGesture);
    await tester.pumpAndSettle();

    // Remove the first item.
    final removeButton1 = find.byKey(ValueKey('return-remove-${tab1.id}'));
    expect(removeButton1, findsOneWidget);
    await tester.tap(removeButton1);
    await tester.pumpAndSettle();

    // Only Page Two should remain.
    expect(find.text('Page One'), findsNothing);
    expect(find.text('Page Two'), findsOneWidget);
  });

  testWidgets('scope isolation: items only appear for their own scope', (tester) async {
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: BrowserReturnDock(
              child: Container(key: const ValueKey('chat'), color: Colors.white),
            ),
          ),
        ),
      ),
    );

    // Remember one return item for 'chat'.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab = await workspace.open(scope, Uri.parse('https://example.com/page'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab.id,
      url: Uri.parse('https://example.com/page'),
      title: 'Chat Page',
    );

    await tester.pumpAndSettle();

    // Badge should be visible.
    final badgeBuilder = find.descendant(
      of: find.byType(BrowserReturnDock),
      matching: find.byWidgetPredicate((w) => w is AnimatedBuilder && w.animation is AnimationController),
    );
    expect(badgeBuilder, findsOneWidget);

    container.dispose();

    // Now switch to a different session in a new container.
    final container2 = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('other')),
      ],
    );
    addTearDown(container2.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container2,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: BrowserReturnDock(
              child: Container(key: const ValueKey('chat'), color: Colors.white),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Badge should no longer be visible (no badge AnimatedBuilder).
    final noBadge = find.descendant(
      of: find.byType(BrowserReturnDock),
      matching: find.byWidgetPredicate((w) => w is AnimatedBuilder && w.animation is AnimationController),
    );
    expect(noBadge, findsNothing);
  });

  testWidgets('expanding/updating items does not reset the expanded state', (tester) async {
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: BrowserReturnDock(
              child: Container(key: const ValueKey('chat'), color: Colors.white),
            ),
          ),
        ),
      ),
    );

    // Remember one return item.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab1 = await workspace.open(scope, Uri.parse('https://example.com/page1'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab1.id,
      url: Uri.parse('https://example.com/page1'),
      title: 'Page One',
    );

    await tester.pumpAndSettle();

    // Expand the badge.
    final badgeGesture = find
        .byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.behavior == HitTestBehavior.opaque && widget.onTap != null,
        )
        .first;
    await tester.tap(badgeGesture);
    await tester.pumpAndSettle();

    // Should be expanded showing "Page One".
    expect(find.text('Page One'), findsOneWidget);

    // Add another item while expanded.
    final tab2 = await workspace.open(scope, Uri.parse('https://example.com/page2'));
    await workspace.updatePage(tab2.id, url: Uri.parse('https://example.com/page2'), title: 'Page Two');
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab2.id,
      url: Uri.parse('https://example.com/page2'),
      title: 'Page Two',
    );

    await tester.pumpAndSettle();

    // Should still be expanded, now showing both items in the list.
    expect(find.text('Page One'), findsOneWidget);
    expect(find.text('Page Two'), findsOneWidget);
  });

  testWidgets('open failure does not remove existing items', (tester) async {
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: BrowserReturnDock(
              child: Container(key: const ValueKey('chat'), color: Colors.white),
            ),
          ),
        ),
      ),
    );

    // Remember one return item.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab = await workspace.open(scope, Uri.parse('https://example.com/page'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab.id,
      url: Uri.parse('https://example.com/page'),
      title: 'Page One',
    );

    await tester.pumpAndSettle();

    // Expand the badge.
    final badgeGesture = find
        .byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.behavior == HitTestBehavior.opaque && widget.onTap != null,
        )
        .first;
    await tester.tap(badgeGesture);
    await tester.pumpAndSettle();

    // A host switch before the next frame makes the old button stale, but
    // the original tab and its return item still belong to their own host.
    container.read(activeHostProvider.notifier).select(const HostRef.ssh('other'));
    final openButton = find.byKey(ValueKey('return-open-${tab.id}'));
    expect(openButton, findsOneWidget);
    await tester.tap(openButton);
    await tester.pumpAndSettle();

    // A stale open must not remove a valid return item from the old host.
    final items = container.read(browserReturnProvider.select((s) => s.itemsFor(scope)));
    expect(items.length, 1);
    expect(items.first.tabId, tab.id);
  });
}
