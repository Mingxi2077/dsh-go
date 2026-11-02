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

  testWidgets('child stays mounted when badge appears and disappears', (tester) async {
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);

    var childInitCount = 0;
    var childDisposeCount = 0;

    Widget buildChild() => _ChildLifecycle(
      key: const ValueKey('chat-child'),
      onInit: () => childInitCount++,
      onDispose: () => childDisposeCount++,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(body: BrowserReturnDock(child: buildChild())),
        ),
      ),
    );

    expect(childInitCount, 1);
    expect(childDisposeCount, 0);

    // Remember a return item.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab = await workspace.open(scope, Uri.parse('https://example.com/page'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab.id,
      url: Uri.parse('https://example.com/page'),
      title: 'Example Page',
    );

    await tester.pumpAndSettle();

    // Child should still be mounted exactly once.
    expect(childInitCount, 1);
    expect(childDisposeCount, 0);
    expect(find.byKey(const ValueKey('chat-child')), findsOneWidget);

    // Dismiss the badge.
    returns.dismiss(scope);
    await tester.pumpAndSettle();

    // Child should still be mounted exactly once.
    expect(childInitCount, 1);
    expect(childDisposeCount, 0);
    expect(find.byKey(const ValueKey('chat-child')), findsOneWidget);
  });

  testWidgets('collapsed badge has 44dp hit area on-screen', (tester) async {
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

    // Remember a return item.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab = await workspace.open(scope, Uri.parse('https://example.com/page'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab.id,
      url: Uri.parse('https://example.com/page'),
      title: 'Example Page',
    );

    await tester.pumpAndSettle();

    // Find the outermost GestureDetector that wraps the badge container.
    final badgeGesture = find
        .byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.behavior == HitTestBehavior.opaque && widget.onTap != null,
        )
        .first;
    expect(badgeGesture, findsOneWidget);

    // Verify it's at least 44dp wide.
    final box = tester.getSize(badgeGesture);
    expect(box.width, greaterThanOrEqualTo(44.0));

    // Tap to expand.
    await tester.tap(badgeGesture);
    await tester.pumpAndSettle();

    // Should now be expanded - check inner ClipRRect width.
    final clipRRect = find.descendant(
      of: find.byWidgetPredicate((w) => w is AnimatedBuilder),
      matching: find.byType(ClipRRect),
    );
    final clipBox = tester.getSize(clipRRect.first);
    expect(clipBox.width, greaterThan(200.0));
  });

  testWidgets('expanded panel fits without overflow during animation and at 1.3 text scale', (tester) async {
    final container = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(1.3)),
              child: BrowserReturnDock(
                child: Container(key: const ValueKey('chat'), color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );

    // Remember a return item.
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final returns = container.read(browserReturnProvider.notifier);
    final tab = await workspace.open(scope, Uri.parse('https://example.com/page'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab.id,
      url: Uri.parse('https://example.com/page'),
      title: 'Example Page',
    );

    await tester.pumpAndSettle();

    // Find the badge gesture detector.
    final badgeGesture = find
        .byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.behavior == HitTestBehavior.opaque && widget.onTap != null,
        )
        .first;

    // Tap to expand and check overflow at multiple animation frames.
    await tester.tap(badgeGesture);

    // 16ms
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull, reason: '16ms frame should not overflow');

    // 48ms
    await tester.pump(const Duration(milliseconds: 32));
    expect(tester.takeException(), isNull, reason: '48ms frame should not overflow');

    // 80ms
    await tester.pump(const Duration(milliseconds: 32));
    expect(tester.takeException(), isNull, reason: '80ms frame should not overflow');

    // 120ms
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.takeException(), isNull, reason: '120ms frame should not overflow');

    // Finish animation
    await tester.pumpAndSettle();

    // No overflow when fully expanded.
    expect(tester.takeException(), isNull, reason: 'Fully expanded should not overflow');
  });

  testWidgets('badge hides when switching sessions', (tester) async {
    // Test that the badge only appears for the correct session.
    final container1 = ProviderContainer(
      overrides: [
        browserStorageProvider.overrideWithValue(MemoryBrowserStorage()),
        currentSessionProvider.overrideWith(() => _FakeCurrentSession('chat')),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container1,
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

    // Remember a return item for 'chat'.
    final workspace = container1.read(browserWorkspaceProvider.notifier);
    final returns = container1.read(browserReturnProvider.notifier);
    final tab = await workspace.open(scope, Uri.parse('https://example.com/page'));
    returns.remember(
      host: host,
      sessionId: 'chat',
      tabId: tab.id,
      url: Uri.parse('https://example.com/page'),
      title: 'Example Page',
    );

    await tester.pumpAndSettle();

    // Badge should be visible (the specific badge AnimatedBuilder is inside a Stack).
    final badgeBuilder = find.descendant(
      of: find.byType(BrowserReturnDock),
      matching: find.byWidgetPredicate((w) => w is AnimatedBuilder && w.animation is AnimationController),
    );
    expect(badgeBuilder, findsOneWidget);

    container1.dispose();

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
}

/// A widget that tracks its lifecycle for testing.
class _ChildLifecycle extends StatefulWidget {
  const _ChildLifecycle({super.key, required this.onInit, required this.onDispose});

  final VoidCallback onInit;
  final VoidCallback onDispose;

  @override
  State<_ChildLifecycle> createState() => _ChildLifecycleState();
}

class _ChildLifecycleState extends State<_ChildLifecycle> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(color: Colors.white);
}
