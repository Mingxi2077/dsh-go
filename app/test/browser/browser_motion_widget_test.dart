// The browser's motion refresh (docs/design/browser-motion-refresh.md):
// 首页's one field keeps its IME session from rest to editing and back, with
// a plain-text keyboard that has suggestions on; 标签页 is a two-across card
// overview the page's snapshot flies into, snapshots belong to the page and
// document they were taken of, back and picks leave it, and reduced motion
// skips the flight. The page is a hand-driven fake: no WebView.

import 'dart:async';

import 'package:dsh_app/browser/browser_library.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

const _scope = BrowserScope(hostKey: 'local:local');
final _field = find.byKey(const ValueKey('browser-address-field'));
final _box = find.byKey(const ValueKey('browser-home-search'));
final _overview = find.byKey(const ValueKey('browser-tabs-overview'));
final _liveView = find.byKey(const ValueKey('fake-browser-view'));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  FakePages pages, {
  Uri? url,
  bool reduceMotion = false,
  bool narrow = false,
  double textScale = 1.0,
}) async {
  usePhoneView(tester);
  if (narrow) {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
  }
  mockClipboard(tester);
  final page = BrowserPage(host: HostRef.local, initialUrl: url);
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion, textScaler: TextScaler.linear(textScale)),
          child: page,
        ),
      ),
      overrides: pages.overrides(),
    ),
  );
  await pumpFrames(tester, 3);
  return ProviderScope.containerOf(tester.element(find.byType(BrowserPage)));
}

List<BrowserTab> _tabs(ProviderContainer c) => c.read(browserWorkspaceProvider).tabsFor(_scope);

/// Two finished pages, A then B (B open), A with a snapshot.
Future<(ProviderContainer, FakeBrowserPage, FakeBrowserPage)> _twoPages(
  WidgetTester tester,
  FakePages pages, {
  bool reduceMotion = false,
}) async {
  final c = await _pump(tester, pages, url: Uri.parse('https://a.example.com/'), reduceMotion: reduceMotion);
  final a = pages.last..finish(title: 'A 页');
  await c.read(browserWorkspaceProvider.notifier).open(_scope, Uri.parse('https://b.example.com/'));
  await pumpFrames(tester, 2);
  final b = pages.last..finish(title: 'B 页');
  await pumpFrames(tester, 2);
  return (c, a, b);
}

Finder previewIn(String tabId) => find.descendant(
  of: find.byKey(ValueKey('browser-tab-$tabId')),
  matching: find.byKey(const ValueKey('browser-tab-preview')),
);

/// Waits for overview to appear after tap, accounting for _capture and _decodePreviews.
Future<void> waitForOverview(WidgetTester tester, {int maxAttempts = 50}) async {
  for (var i = 0; i < maxAttempts; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (_overview.evaluate().isNotEmpty) return;
  }
  fail('Overview did not appear within ${maxAttempts * 16}ms');
}

Future<void> openOverview(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('browser-tabs')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 320));
  await pumpFrames(tester, 5);
}

// Exit now includes a final snapshot fade after the page grows to full size.
Future<void> waitForOverviewExit(WidgetTester tester) async {
  for (var i = 0; i < 25 && _overview.evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
  expect(_overview, findsNothing);
}

Future<void> searchFromHome(WidgetTester tester, String address) async {
  await tester.tap(_box);
  await pumpFrames(tester, 2);
  await tester.enterText(_field, address);
  await tester.testTextInput.receiveAction(TextInputAction.go);
  await pumpFrames(tester, 3);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('首页: one field, plain text with suggestions; composing survives the glide down and back', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages);
    expect(find.byType(TextField), findsOneWidget);
    final rest = tester.getRect(_box);
    final state = tester.state<EditableTextState>(find.byType(EditableText));

    await tester.tap(_box);
    await tester.pump();
    // The IME client: never a visible-password field, never obscured.
    final args = tester.testTextInput.setClientArgs!;
    expect((args['inputType'] as Map)['name'], 'TextInputType.text');
    expect(args['enableSuggestions'], isTrue);
    expect(args['obscureText'], isFalse);
    expect(args['inputAction'], 'TextInputAction.go');

    // Pinyin mid-composition while the box is still moving.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'tian',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    final mid = tester.getRect(_box);
    expect(mid.top, greaterThan(rest.top), reason: 'on its way down');
    expect(mid.top, lessThan(rest.top + 200), reason: 'not jumped to the bottom yet');
    await pumpFrames(tester, 5);
    final editing = tester.getRect(_box);
    expect(editing.top, greaterThan(mid.top), reason: 'continued monotonically down');
    expect(find.byType(TextField), findsOneWidget, reason: 'the same field moved, no second one appeared');
    expect(identical(tester.state<EditableTextState>(find.byType(EditableText)), state), isTrue);
    final value = tester.widget<TextField>(_field).controller!.value;
    expect(value.text, 'tian');
    expect(value.composing, const TextRange(start: 0, end: 4));
    expect(find.byKey(const ValueKey('browser-toolbar')), findsNothing, reason: 'the capsule gives way');

    // Committing the composition (天气) offers to search it.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '天气', selection: TextSelection.collapsed(offset: 2)),
    );
    await pumpFrames(tester, 2);
    expect(find.byKey(const ValueKey('browser-suggestion-go')), findsOneWidget);

    // Back: the box glides home, the field empties, nothing was opened.
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, 5);
    expect(tester.getRect(_box).top, moreOrLessEquals(rest.top, epsilon: 0.5));
    expect(identical(tester.state<EditableTextState>(find.byType(EditableText)), state), isTrue);
    expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('browser-toolbar')), findsOneWidget);
    expect(find.byType(BrowserPage), findsOneWidget, reason: 'back left editing, not the browser');
    expect(pages.made, isEmpty);
  });

  testWidgets('首页 → editing: the box moves monotonically down through 0/80/160/240/360/420 ms, never reversing', (
    tester,
  ) async {
    final pages = FakePages();
    await _pump(tester, pages);
    addTearDown(tester.view.resetViewInsets);
    final rest = tester.getRect(_box).top;

    await tester.tap(_box);
    await tester.pump();
    // Sample at 0, then cumulative intervals: 80, 160, 240, 360, 420 ms.
    final samples = <double>[];
    samples.add(tester.getRect(_box).top);
    for (final delta in [80, 80, 80, 120, 60]) {
      await tester.pump(Duration(milliseconds: delta));
      samples.add(tester.getRect(_box).top);
    }
    // 0 ms should be approximately at rest (< 1px change).
    expect((samples[0] - rest).abs(), lessThan(1), reason: '0 ms: starts from rest, no jump');
    // From 80 ms onward, strictly monotonic downward.
    for (int i = 2; i < samples.length; i++) {
      expect(samples[i], greaterThanOrEqualTo(samples[i - 1]), reason: 'monotonic at frame $i (never reversed)');
    }

    // Keyboard arrives late: the box lifts smoothly, not jumping.
    final beforeKeyboard = tester.getRect(_box).top;
    tester.view.viewInsets = FakeViewPadding(bottom: 1400.0);
    await tester.pump();
    final startLift = tester.getRect(_box).top;
    expect((startLift - beforeKeyboard).abs(), lessThan(1), reason: 'keyboard correction starts continuously');
    // Wait 80ms for stable timer.
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 16));
    final lifting = tester.getRect(_box).top;
    expect(lifting, lessThan(startLift), reason: 'next frame lifts higher');
    await pumpFrames(tester, 3);
    expect(tester.getRect(_box).top, lessThan(lifting), reason: 'continues smoothly up');
  });

  testWidgets('首页 editing: wordmark and history have real intermediate opacity, not 0/1 jumps', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages);
    await c.read(browserLibraryProvider.notifier).recordVisit(Uri.parse('https://example.com/'), '测试历史');
    await pumpFrames(tester, 2);

    await tester.tap(_box);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    // wordmark: Interval(.15, .5, Curves.easeIn), at 220/420 = 0.524, fully faded
    final wordmark = find.ancestor(of: find.text('Dsh'), matching: find.byType(FadeTransition));
    expect(wordmark, findsOneWidget);
    final wordmarkOpacity = tester.widget<FadeTransition>(wordmark).opacity.value;
    expect(wordmarkOpacity, lessThan(0.1), reason: 'wordmark faded out at 220ms');

    // history: Interval(.3, 1, Curves.easeOut), at 220/420 = 0.524, (0.524-.3)/(1-.3) ≈ 0.32
    final history = find.ancestor(of: find.text('测试历史'), matching: find.byType(FadeTransition));
    expect(history, findsOneWidget);
    final historyOpacity = tester.widget<FadeTransition>(history).opacity.value;
    expect(historyOpacity, greaterThan(0.1), reason: 'history has started fading in');
    expect(historyOpacity, lessThan(0.9), reason: 'history not yet fully visible at 220ms');
  });

  testWidgets('首页: keyboard collapsing does not drag the box down', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages);
    addTearDown(tester.view.resetViewInsets);

    // Enter editing with keyboard.
    await tester.tap(_box);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();
    await pumpFrames(tester, 5);
    final editingTop = tester.getRect(_box).top;
    expect(find.byType(TextField), findsOneWidget, reason: 'field visible in editing mode');

    // Keyboard starts collapsing: 320 → 240 → 100 → 0.
    // Box should NOT follow keyboard down; it stays at editingTop (frozen at peak).
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    final at240 = tester.getRect(_box).top;
    expect(at240, lessThanOrEqualTo(editingTop + 1), reason: 'box frozen when keyboard collapses to 240');

    tester.view.viewInsets = const FakeViewPadding(bottom: 100);
    await tester.pump();
    final at100 = tester.getRect(_box).top;
    expect(at100, lessThanOrEqualTo(editingTop + 1), reason: 'box still frozen at 100');

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    final at0 = tester.getRect(_box).top;
    expect(at0, lessThanOrEqualTo(editingTop + 1), reason: 'box does not follow keyboard down to 0');
  });

  testWidgets('首页: enter and exit start from stable positions (<1px change)', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages);
    addTearDown(tester.view.resetViewInsets);
    final rest = tester.getRect(_box).top;

    // Enter editing by tapping and simulating keyboard appearance.
    final fieldBefore = find.byType(TextField).evaluate().single;
    await tester.tap(_box);
    await tester.pump();
    final enter0 = tester.getRect(_box).top;
    expect((enter0 - rest).abs(), lessThan(1), reason: 'enter starts from rest, no jump');

    // Simulate keyboard appearing.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    final enter1 = tester.getRect(_box).top;
    expect(enter1, greaterThanOrEqualTo(enter0), reason: 'first frame after keyboard, continuous or down');

    await pumpFrames(tester, 4);
    final editing = tester.getRect(_box).top;
    expect(editing, greaterThan(enter1), reason: 'continued down to editing seat');
    final fieldDuring = find.byType(TextField).evaluate().single;
    expect(fieldDuring, same(fieldBefore), reason: 'TextField not rebuilt during animation');

    // Exit editing: hide keyboard and leave editing.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.binding.handlePopRoute();
    await tester.pump();
    final exit0 = tester.getRect(_box).top;
    expect((exit0 - editing).abs(), lessThan(1), reason: 'exit starts from editing seat, no jump');

    await pumpFrames(tester, 4);
    final back = tester.getRect(_box).top;
    expect((back - rest).abs(), lessThan(1), reason: 'returns to original rest position');

    final fieldAfter = find.byType(TextField).evaluate().single;
    expect(fieldAfter, same(fieldBefore), reason: 'same TextField instance throughout');
  });

  testWidgets('首页 editing shows recent history above the box; picking one opens it', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages);
    await c.read(browserLibraryProvider.notifier).recordVisit(Uri.parse('https://read.example.com/x'), '读过的页');
    await pumpFrames(tester, 2);
    expect(find.text('读过的页').hitTestable(), findsNothing, reason: 'history waits for the field');
    await tester.tap(_box);
    await pumpFrames(tester, 5);
    expect(find.text('读过的页'), findsOneWidget);
    expect(
      tester.getRect(find.text('读过的页')).bottom,
      lessThan(tester.getRect(_box).top),
      reason: 'above the box, out of the keyboard',
    );
    await tester.tap(find.text('读过的页'));
    await pumpFrames(tester, 3);
    expect(pages.last.url, Uri.parse('https://read.example.com/x'));
  });

  testWidgets('标签页: the page flies into its card, two across; a card grows back into its page', (tester) async {
    final pages = FakePages();
    final (c, a, b) = await _twoPages(tester, pages);
    b.preview = tinyPng;
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    // Decoding before the flight waits at most 300 ms (test images never
    // decode under fake time).
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    expect(b.captures, 1, reason: 'the open page is captured first');
    expect(_overview, findsOneWidget);
    expect(_liveView, findsNothing, reason: 'the live view is offstage, not transformed');
    expect(find.byKey(const ValueKey('browser-tab-preview')), findsWidgets, reason: 'its snapshot is what flies');

    // Check intermediate frames: the flying card is visible and moving.
    await tester.pump(const Duration(milliseconds: 100));
    expect(_overview, findsOneWidget, reason: 'still opening');
    final previewMid = find.byKey(const ValueKey('browser-tab-preview'));
    expect(previewMid, findsWidgets, reason: 'preview visible mid-flight');

    await pumpFrames(tester, 5);

    final aId = _tabs(c).firstWhere((t) => t.title == 'A 页').id;
    final bId = _tabs(c).firstWhere((t) => t.title == 'B 页').id;
    final aCard = tester.getRect(find.byKey(ValueKey('browser-tab-$aId')));
    final bCard = tester.getRect(find.byKey(ValueKey('browser-tab-$bId')));
    expect(aCard.top, bCard.top, reason: 'one row');
    expect(bCard.left, greaterThan(aCard.right));
    expect(aCard.width, lessThan(400 / 2));
    expect(
      find.descendant(
        of: find.byKey(ValueKey('browser-tab-$bId')),
        matching: find.byKey(const ValueKey('browser-tab-preview')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(ValueKey('browser-tab-$aId')),
        matching: find.byKey(const ValueKey('browser-tab-preview')),
      ),
      findsNothing,
      reason: 'no snapshot of A: its site, not a made-up page',
    );

    await tester.tap(find.byKey(ValueKey('browser-tab-$aId')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_overview, findsOneWidget, reason: 'still growing');
    await waitForOverviewExit(tester);
    expect(_overview, findsNothing);
    expect(_liveView, findsOneWidget);
    expect(c.read(browserWorkspaceProvider).selectedFor(_scope)!.id, aId);
    expect(a.disposed || b.disposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签页: mid-flight back reverses the animation from wherever it is', (tester) async {
    final pages = FakePages();
    final (c, _, b) = await _twoPages(tester, pages);
    b.preview = tinyPng;
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    await waitForOverview(tester); // Wait for overview to appear.
    await tester.pump(); // Establish ticker baseline.
    await tester.pump(const Duration(milliseconds: 100));
    expect(_overview, findsOneWidget, reason: 'mid-flight in');

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_overview, findsOneWidget, reason: 'reversing out');
    await waitForOverviewExit(tester);
    expect(_overview, findsNothing);
    expect(_liveView, findsOneWidget);
    expect(_tabs(c), hasLength(2), reason: 'tabs unchanged');
  });

  testWidgets('a snapshot that arrives after its page navigated is dropped; the overview still opens', (tester) async {
    final pages = FakePages();
    final (c, _, b) = await _twoPages(tester, pages);
    final pending = b.pendingPreview = Completer<Uint8List?>();
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    b.navigate(Uri.parse('https://b.example.com/next'));
    b.finish(title: 'B 下一页');
    pending.complete(tinyPng);
    await pumpFrames(tester, 6);
    expect(_overview, findsOneWidget);
    expect(find.byKey(const ValueKey('browser-tab-preview')), findsNothing);

    // Back leaves the overview for the open page.
    await tester.binding.handlePopRoute();
    await waitForOverviewExit(tester);
    expect(_overview, findsNothing);
    expect(find.byType(BrowserPage), findsOneWidget);
    expect(_tabs(c), hasLength(2));
  });

  testWidgets('标签页: rapid clicks (open, pick, pick again) do not crash', (tester) async {
    final pages = FakePages();
    final (c, a, b) = await _twoPages(tester, pages);
    a.preview = tinyPng;
    b.preview = tinyPng;

    // Open overview.
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    await waitForOverview(tester);
    await tester.pump(); // Ticker baseline.
    await pumpFrames(tester, 5);
    expect(_overview, findsOneWidget, reason: 'overview opened');

    // Pick A tab.
    final aId = _tabs(c).firstWhere((t) => t.title == 'A 页').id;
    await tester.tap(find.byKey(ValueKey('browser-tab-$aId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_liveView, findsOneWidget, reason: 'real page paints beneath the outgoing snapshot');

    // Quickly click the same A card again (may be obscured by IgnorePointer during animation).
    await tester.tap(find.byKey(ValueKey('browser-tab-$aId')), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await pumpFrames(tester, 8);
    expect(tester.takeException(), isNull, reason: 'no crash');
    expect(c.read(browserWorkspaceProvider).selectedFor(_scope)!.id, aId, reason: 'A is selected');
    expect(_tabs(c), hasLength(2));

    // Now open overview again to verify it still works.
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    await waitForOverview(tester);
    expect(_overview, findsOneWidget, reason: 'can reopen overview');
  });

  testWidgets('首页 and 标签页 at 360dp 1.3x scale: box/cards readable, no overflow', (tester) async {
    final pages = FakePages();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Test home layout first with narrow layout and text scaling.
    final c = await _pump(tester, pages, narrow: true, textScale: 1.3);
    expect(tester.getRect(_box).height, greaterThan(52.0), reason: 'box grew for large text');
    expect(tester.takeException(), isNull, reason: 'no overflow in home');

    // Now create pages and test overview.
    await searchFromHome(tester, 'a.example.com');
    pages.last
      ..preview = tinyPng
      ..finish(title: 'A 页');
    await pumpFrames(tester, 2);

    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    await waitForOverview(tester);
    await pumpFrames(tester, 5);
    expect(tester.takeException(), isNull, reason: 'no overflow in overview');
    final aId = _tabs(c).single.id;
    final card = tester.getRect(find.byKey(ValueKey('browser-tab-$aId')));
    expect(card.width, greaterThan(100), reason: 'card readable');
    expect(card.height, greaterThan(100), reason: 'card readable');
  });

  testWidgets('a snapshot never outlives its tab: closed, then undone, the card shows the site', (tester) async {
    final pages = FakePages();
    final (c, _, b) = await _twoPages(tester, pages);
    b.preview = tinyPng;
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await pumpFrames(tester, 6);
    final bId = _tabs(c).firstWhere((t) => t.title == 'B 页').id;
    await tester.tap(find.descendant(of: find.byKey(ValueKey('browser-tab-$bId')), matching: find.byTooltip('关闭标签页')));
    await pumpFrames(tester, 4);
    expect(_tabs(c), hasLength(1));
    await tester.tap(find.byKey(const ValueKey('browser-tab-undo')));
    await pumpFrames(tester, 4);
    expect(_tabs(c), hasLength(2));
    expect(find.byKey(const ValueKey('browser-tab-preview')), findsNothing);
  });

  testWidgets('reduced motion: the overview opens and closes without a flight', (tester) async {
    final pages = FakePages();
    await _twoPages(tester, pages, reduceMotion: true);
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    await tester.pump();
    expect(_overview, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('browser-tabs-done')));
    await tester.pump();
    await tester.pump();
    expect(_overview, findsNothing);
    expect(_liveView, findsOneWidget);

    // 首页's box jumps to the keyboard and back.
    await tester.tap(find.byKey(const ValueKey('browser-home-key')));
    await pumpFrames(tester, 2);
    final rest = tester.getRect(_box);
    await tester.tap(_box);
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(_box).top, greaterThan(rest.top + 100));
  });

  testWidgets('首页 → site → 首页 → site: every page left keeps a real snapshot in the overview', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://a.example.com/'));
    final a = pages.last
      ..preview = tinyPng
      ..finish(title: 'A 页');
    await pumpFrames(tester, 2);
    await tester.tap(find.byKey(const ValueKey('browser-home-key')));
    await pumpFrames(tester, 3);
    expect(a.captures, 1, reason: 'captured while still on screen, before 首页');
    expect(find.byKey(const ValueKey('browser-home')), findsOneWidget);

    await searchFromHome(tester, 'b.example.com');
    final b = pages.last
      ..preview = tinyPng
      ..finish(title: 'B 页');
    await pumpFrames(tester, 2);
    await tester.tap(find.byKey(const ValueKey('browser-home-key')));
    await pumpFrames(tester, 3);
    expect(b.captures, 1);
    await searchFromHome(tester, 'c.example.com');
    pages.last.finish(title: 'C 页');
    await pumpFrames(tester, 2);

    await openOverview(tester);
    final ids = {for (final t in _tabs(c)) t.title: t.id};
    expect(ids.keys, containsAll(['A 页', 'B 页', 'C 页']));
    expect(previewIn(ids['A 页']!), findsOneWidget);
    expect(previewIn(ids['B 页']!), findsOneWidget);
    expect(previewIn(ids['C 页']!), findsNothing, reason: 'C gave no snapshot: its site, not a guess');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a move waiting on its snapshot is dropped when the overview opens first', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://a.example.com/'));
    final a = pages.last..finish(title: 'A 页');
    await pumpFrames(tester, 2);
    final pending = a.pendingPreview = Completer<Uint8List?>();
    await tester.tap(find.byKey(const ValueKey('browser-home-key')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await tester.pump();
    pending.complete(tinyPng);
    await tester.pump(const Duration(milliseconds: 320));
    await pumpFrames(tester, 5);
    expect(_overview, findsOneWidget);
    expect(_tabs(c), hasLength(1), reason: 'the stale 首页 move never ran');
    expect(c.read(browserWorkspaceProvider).selectedFor(_scope)!.title, 'A 页');
  });

  testWidgets('a snapshot finishing after its page navigated is not kept, and the move still goes', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://a.example.com/'));
    final a = pages.last..finish(title: 'A 页');
    await pumpFrames(tester, 2);
    final pending = a.pendingPreview = Completer<Uint8List?>();
    await tester.tap(find.byKey(const ValueKey('browser-home-key')));
    await tester.pump();
    a.navigate(Uri.parse('https://a.example.com/next'));
    a.finish(title: 'A 下一页');
    pending.complete(tinyPng);
    await pumpFrames(tester, 3);
    expect(find.byKey(const ValueKey('browser-home')), findsOneWidget);
    a.pendingPreview = null;
    await openOverview(tester);
    final aId = _tabs(c).firstWhere((t) => t.url != null).id;
    expect(previewIn(aId), findsNothing);
  });

  testWidgets('a same-address reload or SPA change retires the snapshot of the old document', (tester) async {
    final pages = FakePages();
    final (c, _, b) = await _twoPages(tester, pages);
    b.preview = tinyPng;
    await openOverview(tester);
    final bId = _tabs(c).firstWhere((t) => t.title == 'B 页').id;
    expect(previewIn(bId), findsOneWidget);

    // Same address, new document (reload / pushState): revision only.
    b
      ..preview = null
      ..revision += 1
      ..ping();
    await pumpFrames(tester, 2);
    expect(previewIn(bId), findsNothing, reason: 'dropped while the overview shows it');
    await tester.tap(find.byKey(const ValueKey('browser-tabs-done')));
    await waitForOverviewExit(tester);
    await openOverview(tester);
    expect(previewIn(bId), findsNothing, reason: 'and not shown again');
  });

  testWidgets('a snapshot outlives its page leaving the pool, not a new page made for the tab', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://a.example.com/'));
    final ws = c.read(browserWorkspaceProvider.notifier);
    final a = pages.last
      ..preview = tinyPng
      ..finish(title: 'A 页');
    await pumpFrames(tester, 2);
    await openOverview(tester);
    await tester.tap(find.byKey(const ValueKey('browser-tabs-done')));
    await waitForOverviewExit(tester);
    for (final host in ['b', 'c', 'd']) {
      await ws.open(_scope, Uri.parse('https://$host.example.com/'));
      await pumpFrames(tester, 2);
      pages.last.finish(title: host);
    }
    expect(a.disposed, isTrue, reason: 'A gave its live page up');
    await openOverview(tester);
    final aId = _tabs(c).firstWhere((t) => t.title == 'A 页').id;
    expect(previewIn(aId), findsOneWidget, reason: 'the last picture stays on the card');

    await tester.tap(find.byKey(ValueKey('browser-tab-$aId')));
    await pumpFrames(tester, 5);
    expect(pages.last.url.host, 'a.example.com', reason: 'a new page for A');
    await openOverview(tester);
    expect(previewIn(aId), findsNothing, reason: 'the old picture is not the new page');
  });

  testWidgets('the fields have no theme fill: the home box and the glass capsule are their only surface', (
    tester,
  ) async {
    final pages = FakePages();
    await _pump(tester, pages);
    final home = tester.widget<TextField>(_field).decoration!;
    expect(home.filled, isFalse);
    expect(home.border, isA<OutlineInputBorder>().having((b) => b.borderSide, 'side', BorderSide.none));
    await searchFromHome(tester, 'example.com');
    pages.last.finish();
    await pumpFrames(tester, 2);
    await tester.tap(find.byKey(const ValueKey('browser-address')));
    await pumpFrames(tester, 2);
    expect(tester.widget<TextField>(_field).decoration!.filled, isFalse);
    expect(tester.widget<TextField>(_field).keyboardType, TextInputType.text);
  });

  testWidgets('标签页 ＋ pairs primary with onPrimary', (tester) async {
    final pages = FakePages();
    await _twoPages(tester, pages);
    await openOverview(tester);
    final scheme = Theme.of(tester.element(_overview)).colorScheme;
    final style = tester.widget<IconButton>(find.byKey(const ValueKey('browser-tabs-new'))).style!;
    expect(style.backgroundColor!.resolve({}), scheme.primary);
    expect(style.foregroundColor!.resolve({}), scheme.onPrimary);
  });

  Finder markImage(String tabId) => find.descendant(
    of: find.byKey(ValueKey('browser-tab-$tabId')),
    matching: find.byWidgetPredicate((w) => w is Image && w.key != const ValueKey('browser-tab-preview')),
  );

  testWidgets('a page\'s own favicon is kept once per document and shown for its site', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://a.example.com/x?q=1'));
    final a = pages.last..icon = tinyPng;
    a.finish(title: 'A 页');
    await pumpFrames(tester, 2);
    a.ping();
    a.ping();
    await pumpFrames(tester, 2);
    expect(a.iconRequests, 1, reason: 'not again for notifications of the same document');
    expect(pages.siteIcons.remembered, [Uri.parse('https://a.example.com/x?q=1')]);
    await openOverview(tester);
    final aId = _tabs(c).single.id;
    expect(markImage(aId), findsWidgets, reason: 'the site marks are the favicon, not a letter');

    await tester.tap(find.byKey(const ValueKey('browser-tabs-done')));
    await waitForOverviewExit(tester);
    a.navigate(Uri.parse('https://a.example.com/y'));
    a.finish(title: 'A2');
    await pumpFrames(tester, 2);
    expect(a.iconRequests, 2, reason: 'a new document asks again');
  });

  testWidgets('a favicon read that finishes after a navigation is never kept', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages, url: Uri.parse('https://a.example.com/'));
    final a = pages.last;
    final pending = a.pendingIcon = Completer<Uint8List?>();
    a.finish(title: 'A 页');
    await pumpFrames(tester, 2);
    a.navigate(Uri.parse('https://b.example.com/'));
    pending.complete(tinyPng);
    await pumpFrames(tester, 2);
    expect(pages.siteIcons.remembered, isEmpty);
    expect(pages.icons, isEmpty);
  });

  testWidgets('a favicon that arrives late is picked up when the page is captured', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages, url: Uri.parse('https://a.example.com/'));
    final a = pages.last..finish(title: 'A 页');
    await pumpFrames(tester, 2);
    expect(a.iconRequests, 1);
    expect(pages.siteIcons.remembered, isEmpty);
    a.icon = tinyPng;
    await openOverview(tester);
    expect(a.iconRequests, 2, reason: 'one more try before the snapshot');
    expect(pages.siteIcons.remembered, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('browser-tabs-done')));
    await waitForOverviewExit(tester);
    await openOverview(tester);
    expect(a.iconRequests, 2, reason: 'kept: no further reads');
  });

  testWidgets('the IME hiding itself on back (no pop reaches Flutter) ends 首页 editing and glides home', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages);
    addTearDown(tester.view.resetViewInsets);
    final rest = tester.getRect(_box);
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final field = tester.widget<TextField>(_field);

    await tester.tap(_box);
    await tester.pump();
    // Focused, the keyboard not up yet: a 0 inset is not "it went away".
    await pumpFrames(tester, 3);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(tester.getRect(_box).top, greaterThan(rest.top + 100), reason: 'still editing');

    // The keyboard slides up while composing (use 300dp = 600 physical).
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    for (final h in [300.0, 600.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: h);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pumpFrames(tester, 3);
    expect(field.focusNode!.hasFocus, isTrue, reason: 'composing through the keyboard rising');
    expect(field.controller!.value.composing, const TextRange(start: 0, end: 2));

    // ...then the IME hides itself; no handlePopRoute.
    for (final h in [400.0, 200.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: h);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pumpFrames(tester, 5);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.getRect(_box).top, moreOrLessEquals(rest.top, epsilon: 0.5), reason: 'back in the middle');
    expect(find.byKey(const ValueKey('browser-toolbar')), findsOneWidget);
    expect(identical(tester.state<EditableTextState>(find.byType(EditableText)), state), isTrue);
    expect(find.byType(BrowserPage), findsOneWidget, reason: 'the browser stays');

    // A new edit starts over with known keyboard 300dp: box uses that cached height.
    await tester.tap(_box);
    await tester.pump();
    await pumpFrames(tester, 3);
    expect(field.focusNode!.hasFocus, isTrue);
    final secondEditTop = tester.getRect(_box).top;
    // With known 300dp: editTop = 844 - 300 - 58 - 12 = 474.
    expect(secondEditTop, greaterThan(rest.top + 100), reason: 'uses known keyboard height');
    expect(secondEditTop, lessThan(rest.top + 300), reason: 'positioned for 300dp keyboard');
  });

  testWidgets('首页: predicted keyboard larger than real stabilizes to actual after 80ms', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages); // Default 390x844dp
    addTearDown(tester.view.resetViewInsets);

    final rest = tester.getRect(_box);

    // Tap to edit: snaps to predicted (no known keyboard).
    await tester.tap(_box);
    await tester.pump();
    final snap0 = tester.getRect(_box).top;
    expect((snap0 - rest.top).abs(), lessThan(1), reason: 'starts from rest, no jump');

    // Animate down to predicted seat over 420ms.
    await tester.pump(const Duration(milliseconds: 420));
    final predictedTop = tester.getRect(_box).top;
    // Predicted: 844 * 0.4 = 337.6dp → editTop ≈ 844 - 337.6 - 58 - 12 = 436.4.
    expect(predictedTop, greaterThan(rest.top + 100), reason: 'animated to predicted seat');

    // Real keyboard arrives at 280dp (560 physical / 2).
    tester.view.viewInsets = const FakeViewPadding(bottom: 560);
    await tester.pump();
    final before80 = tester.getRect(_box).top;
    expect((before80 - predictedTop).abs(), lessThan(1), reason: 'no immediate jump when keyboard arrives');

    // Wait 80ms for stable timer to fire.
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(); // Start animation.
    await tester.pump(const Duration(milliseconds: 16));
    final correcting = tester.getRect(_box).top;
    expect(correcting, greaterThan(before80 - 1), reason: 'started correcting downward to actual seat');

    // Let animation complete (220ms standard duration).
    await tester.pump(const Duration(milliseconds: 220));
    final stable = tester.getRect(_box);
    // Box bottom should be 12dp gap above keyboard (BrowserHome.keyboardGap).
    final size = MediaQuery.sizeOf(tester.element(_box));
    final actualKeyboard = 280.0;
    final expectedBottom = size.height - actualKeyboard - 12;
    expect(stable.bottom, moreOrLessEquals(expectedBottom, epsilon: 2.0), reason: 'corrected to actual keyboard');

    // Keyboard collapses: 280 → 240 → 100 → 0.
    tester.view.viewInsets = const FakeViewPadding(bottom: 480); // 240dp
    await tester.pump();
    final at240 = tester.getRect(_box).top;
    expect(at240, lessThanOrEqualTo(stable.top + 1), reason: 'frozen when keyboard drops to 240');

    tester.view.viewInsets = const FakeViewPadding(bottom: 200); // 100dp
    await tester.pump();
    final at100 = tester.getRect(_box).top;
    expect(at100, lessThanOrEqualTo(stable.top + 1), reason: 'still frozen at 100');

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    final at0 = tester.getRect(_box).top;
    expect(at0, lessThanOrEqualTo(stable.top + 1), reason: 'does not follow keyboard down to 0');
  });
}
