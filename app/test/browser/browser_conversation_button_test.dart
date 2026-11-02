import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/browser/browser_conversation_activity.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/ui/browser/browser_conversation_button.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_conversation_activity_test.dart' show conversationState;
import 'browser_widget_fakes.dart';

const _target = (host: HostRef.local, sessionId: 'chat');
const _running = ValueKey('browser-conversation-running');
const _completed = ValueKey('browser-conversation-completed');
const _spin = ValueKey('browser-conversation-spin');

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('running and completed remain one accessible, 44dp clickable return button', (tester) async {
    final harness = ChatHarness(
      session: 'chat',
      states: {'chat': conversationState(running: true, start: 1)},
      extra: [chatOnScreenProvider.overrideWith(() => FlagController(false))],
    );
    var taps = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: BrowserConversationButton(target: _target, tooltip: '返回会话', active: true, onPressed: () => taps++),
          ),
        ),
        overrides: harness.overrides,
      ),
    );
    await tester.pump();
    final button = find.byType(BrowserConversationButton);
    expect(tester.getSize(button), const Size(44, 44));
    expect(find.byKey(_running), findsOneWidget);
    expect(find.bySemanticsLabel('返回会话，任务进行中'), findsOneWidget);
    await tester.tap(button);
    expect(taps, 1);
    harness.controllers['chat']!.emit(conversationState(start: 1, end: 6));
    await tester.pump();
    expect(find.byKey(_running), findsNothing);
    expect(find.byKey(_completed), findsOneWidget);
    expect(find.bySemanticsLabel('返回会话，任务已完成'), findsOneWidget);
    await tester.tap(button);
    expect(taps, 2);
    expect(tester.getSize(button), const Size(44, 44));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('loop pauses for hidden, background, TickerMode and reduced motion without losing status', (
    tester,
  ) async {
    final harness = ChatHarness(session: 'chat', states: {'chat': conversationState(running: true, start: 1)});
    final controls = ValueNotifier((active: true, ticks: true, reduced: false));
    late ProviderContainer container;
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return ValueListenableBuilder(
              valueListenable: controls,
              builder: (context, options, _) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: options.reduced),
                child: TickerMode(
                  enabled: options.ticks,
                  child: Scaffold(
                    body: Center(
                      child: BrowserConversationButton(
                        target: _target,
                        tooltip: '返回会话',
                        active: options.active,
                        onPressed: () {},
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        overrides: harness.overrides,
      ),
    );
    double phase() {
      final spin = find.byKey(_spin);
      return spin.evaluate().isEmpty ? 0 : tester.widget<RotationTransition>(spin).turns.value;
    }

    Future<void> checkMotion(bool moving) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      final before = phase();
      await tester.pump(const Duration(milliseconds: 250));
      expect(phase(), moving ? isNot(before) : before);
      expect(find.byKey(_running), findsOneWidget);
      expect(find.byKey(_completed), findsNothing);
    }

    await checkMotion(true);
    controls.value = (active: false, ticks: true, reduced: false);
    await checkMotion(false);
    controls.value = (active: true, ticks: false, reduced: false);
    await checkMotion(false);
    controls.value = (active: true, ticks: true, reduced: true);
    await checkMotion(false);
    controls.value = (active: true, ticks: true, reduced: false);
    await checkMotion(true);
    container.read(appForegroundProvider.notifier).set(false);
    await checkMotion(false);
    container.read(appForegroundProvider.notifier).set(true);
    await checkMotion(true);
    await tester.pumpWidget(const SizedBox.shrink());
    controls.dispose();
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('browser retains completion while editing; fifth button integration, $brightness', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(720, 1600);
      mockClipboard(tester);
      final pages = FakePages(finishDuringInitialization: true);
      final harness = ChatHarness(
        session: 'chat',
        states: {'chat': conversationState(running: true, start: 1)},
        extra: [chatOnScreenProvider.overrideWith(() => FlagController(false))],
      );
      final boundaryKey = GlobalKey();
      late ProviderContainer container;
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true, textScaler: TextScaler.linear(1.3)),
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: const BrowserPage(host: HostRef.local, sessionId: 'chat'),
                ),
              );
            },
          ),
          brightness: brightness,
          overrides: [...harness.overrides, ...pages.overrides()],
        ),
      );
      await pumpFrames(tester, 6);
      expect(find.byKey(_running), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('browser-return-to-chat')), matching: find.byKey(_running)),
        findsOneWidget,
      );
      await _capture(tester, boundaryKey, 'running-${brightness.name}');
      await tester.tap(find.byType(TextField).first);
      await pumpFrames(tester, 5);
      expect(find.byKey(const ValueKey('browser-return-to-chat')), findsNothing);
      harness.controllers['chat']!.emit(conversationState(start: 1, end: 6));
      await pumpFrames(tester, 2);
      expect(container.read(browserConversationActivityProvider(_target)), BrowserConversationActivity.completed);
      // System back leaves editing without leaving the browser.
      await tester.binding.handlePopRoute();
      await pumpFrames(tester, 5);
      expect(find.byKey(_completed), findsOneWidget);
      expect(find.byKey(_running), findsNothing);
      await _capture(tester, boundaryKey, 'completed-${brightness.name}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['BROWSER_ACTIVITY_CAPTURE_DIR'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}
