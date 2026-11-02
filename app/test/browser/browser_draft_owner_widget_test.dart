// Composer actions that outlive a switch: a reply's 「引用」 from a selection
// sheet opened before it, and 恢复旧草稿 confirmed after it. Both belong to the
// composer that was on screen when they started (host, conversation, draft
// generation); A → B and A → B → A land nothing. A confirmed old draft goes
// after the current text, keeps the attachments, sends nothing and stays in v1.

import 'dart:convert';
import 'dart:ui' show SemanticsAction;

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

const _box = HostRef.ssh('box');

Future<ProviderContainer> _pump(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
}

String _text(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

ValueChanged<String> _onQuote(WidgetTester tester) => tester.widget<ChatList>(find.byType(ChatList)).onQuote!;

ChatHarness _two() =>
    ChatHarness(session: 'A', states: {'A': const ChatState(loading: false), 'B': const ChatState(loading: false)});

const _old = '旧版留下的一整段\n第二行';

void _legacy() => SharedPreferences.setMockInitialValues({
  DraftStore.legacyPreferenceKey: jsonEncode({
    'A': {'t': _old, 'at': DateTime(2025).millisecondsSinceEpoch},
  }),
});

Future<void> _openLegacy(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppIcons.add));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('plus-legacy-drafts')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('legacy-draft-A')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a quote from a sheet opened before A → B → A lands nowhere', (tester) async {
    final c = await _pump(tester, _two());
    final early = _onQuote(tester);
    c.read(currentSessionProvider.notifier).select('B');
    await pumpFrames(tester, 2);
    early('A 里选的');
    expect(c.read(composerQuoteProvider), isEmpty, reason: 'not into B');
    c.read(currentSessionProvider.notifier).select('A');
    await pumpFrames(tester, 2);
    early('A 里选的');
    expect(c.read(composerQuoteProvider), isEmpty, reason: 'A again is a new composer');
    _onQuote(tester)('现在选的');
    expect(c.read(composerQuoteProvider), {localDraft('A'): '现在选的'});
  });

  testWidgets('a quote from a sheet opened before a host switch lands nowhere', (tester) async {
    final c = await _pump(tester, _two());
    final early = _onQuote(tester);
    c.read(activeHostProvider.notifier).select(_box);
    c.read(currentSessionProvider.notifier).select('A');
    await pumpFrames(tester, 3);
    early('本机 A 里选的');
    expect(c.read(composerQuoteProvider), isEmpty, reason: "not into box's same-named A");
    c.read(activeHostProvider.notifier).select(HostRef.local);
    c.read(currentSessionProvider.notifier).select('A');
    await pumpFrames(tester, 3);
    early('本机 A 里选的');
    expect(c.read(composerQuoteProvider), isEmpty);
  });

  testWidgets('恢复旧草稿: previewed in full, then after the latest text, attachments kept, nothing sent', (tester) async {
    _legacy();
    final h = _two();
    final c = await _pump(tester, h);
    final image = DraftAttachment.sniff('图.png', tinyPng);
    // Written while B is on screen, so A's composer shows it when it returns.
    c.read(currentSessionProvider.notifier).select('B');
    await pumpFrames(tester, 2);
    c.read(draftStoreProvider.notifier).save(localDraft('A'), '已有的', [image]);
    c.read(currentSessionProvider.notifier).select('A');
    await pumpFrames(tester, 2);
    // Typed and not saved yet by the time the sheet opens.
    await tester.enterText(find.byType(TextField), '已有的，刚改');

    await _openLegacy(tester);
    expect(find.byKey(const ValueKey('legacy-draft-text')), findsOneWidget);
    expect(find.text(_old), findsOneWidget, reason: 'the whole text');
    expect(find.text('旧版保存的草稿，不属于任何主机'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('legacy-draft-append')));
    await tester.pumpAndSettle();

    expect(_text(tester), '已有的，刚改\n\n$_old');
    final draft = c.read(draftStoreProvider).drafts[localDraft('A')]!;
    expect(draft.text, _text(tester));
    expect(draft.attachments, [image]);
    expect(c.read(draftStoreProvider).legacyDrafts['A']!.text, _old, reason: 'v1 stays');
    expect(h.controllers['A']!.sent, isEmpty);
    await c.read(draftStoreProvider.notifier).flush();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DraftStore.legacyPreferenceKey), contains('旧版留下的一整段'));
  });

  for (final hop in ['A → B → A', 'host switch']) {
    testWidgets('恢复旧草稿 confirmed after $hop restores nothing', (tester) async {
      _legacy();
      final c = await _pump(tester, _two());
      await tester.enterText(find.byType(TextField), 'A 的字');
      await _openLegacy(tester);
      if (hop == 'host switch') {
        c.read(activeHostProvider.notifier).select(_box);
        c.read(currentSessionProvider.notifier).select('A');
      } else {
        c.read(currentSessionProvider.notifier).select('B');
        await tester.pump();
        c.read(currentSessionProvider.notifier).select('A');
      }
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('legacy-draft-append')));
      await tester.pumpAndSettle();
      expect(find.text('对话已经切换，没有恢复'), findsOneWidget);
      final drafts = c.read(draftStoreProvider).drafts;
      expect(drafts.values.map((d) => d.text), isNot(contains(contains(_old))));
      expect(_text(tester), isNot(contains(_old)));
    });
  }

  testWidgets('offline: 恢复旧草稿 stays reachable in ＋\'s seat; attachments stay off', (tester) async {
    _legacy();
    final h = ChatHarness(session: 'A', connected: false, states: {'A': const ChatState(loading: false)});
    final c = await _pump(tester, h);
    final entry = find.byKey(const ValueKey('composer-legacy-drafts'));
    expect(entry, findsOneWidget);
    expect(find.byIcon(AppIcons.add), findsNothing, reason: 'no attachment key offline');
    expect(find.byTooltip('恢复旧草稿'), findsOneWidget);
    final node = tester.getSemantics(entry).getSemanticsData();
    expect(node.label, '恢复旧草稿');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.hasAction(SemanticsAction.tap), isTrue, reason: 'enabled');

    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsNothing, reason: 'not the attachment panel');
    await tester.tap(find.byKey(const ValueKey('legacy-draft-A')));
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('legacy-draft-target'));
    expect(
      find.descendant(of: target, matching: find.text('未命名对话')),
      findsOneWidget,
      reason: 'the conversation',
    );
    expect(
      find.descendant(of: target, matching: find.text('本机')),
      findsOneWidget,
      reason: 'and its host',
    );
    await tester.tap(find.byKey(const ValueKey('legacy-draft-append')));
    await tester.pumpAndSettle();
    expect(_text(tester), _old);
    expect(c.read(draftStoreProvider).drafts[localDraft('A')]!.text, _old);
    expect(h.controllers['A']?.sent ?? const [], isEmpty);
  });

  testWidgets('offline without old drafts: the ＋ key, disabled as before', (tester) async {
    final h = ChatHarness(session: 'A', connected: false, states: {'A': const ChatState(loading: false)});
    await _pump(tester, h);
    expect(find.byKey(const ValueKey('composer-legacy-drafts')), findsNothing);
    final plus = find.ancestor(of: find.byIcon(AppIcons.add), matching: find.byType(InkResponse));
    expect(tester.widget<InkResponse>(plus.first).onTap, isNull);
  });

  testWidgets('online with old drafts: ＋ still opens attachments; the old drafts are inside', (tester) async {
    _legacy();
    await _pump(tester, _two());
    expect(find.byKey(const ValueKey('composer-legacy-drafts')), findsNothing);
    await tester.tap(find.byIcon(AppIcons.add));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsOneWidget);
    expect(find.byKey(const ValueKey('plus-legacy-drafts')), findsOneWidget);
  });

  testWidgets('no old drafts: no entry', (tester) async {
    await _pump(tester, _two());
    await tester.tap(find.byIcon(AppIcons.add));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plus-legacy-drafts')), findsNothing);
  });
}
