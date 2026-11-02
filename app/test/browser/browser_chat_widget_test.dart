// The chat composer and 网页's quotes: drafts are the host's and the
// conversation's (a same-named conversation or 新对话 on another host never
// shares them), a quote lands only in its own composer once the saved drafts
// are in, below what is there, and nothing is ever sent.

import 'dart:convert';
import 'dart:async';

import 'package:dsh_app/state/web_quote.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/web_quote_card.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';

import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/browser/browser_draft.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/browser/browser_entry.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

const _box = HostRef.ssh('box');
final _boxKey = browserHostKey(_box);

BrowserReference _ref(String? session, {String host = 'local:local', String text = '网页里的一段'}) => BrowserReference(
  scope: BrowserScope(hostKey: host, sessionId: session),
  content: pageContent(text: text),
);

List<String> _quotes(WidgetTester tester) => find.byType(ComposerTray).evaluate().isEmpty
    ? []
    : tester.widget<ComposerTray>(find.byType(ComposerTray)).webQuotes.map((q) => q.text).toList();

Future<ProviderContainer> _pump(WidgetTester tester, ChatHarness harness, {FakeSessions? sessions}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: [
        for (final override in harness.overrides)
          if (sessions == null || override.origin != sessionsProvider) override,
        if (sessions != null) sessionsProvider.overrideWith(() => sessions),
      ],
    ),
  );
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
}

String _text(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

Future<void> _host(WidgetTester tester, ProviderContainer c, HostRef host) async {
  c.read(activeHostProvider.notifier).select(host);
  await pumpFrames(tester, 3);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('A and B new chats keep their own drafts', (tester) async {
    final c = await _pump(tester, ChatHarness());
    await tester.enterText(find.byType(TextField), '本机的新对话');
    await _host(tester, c, _box);
    expect(_text(tester), isEmpty);
    await tester.enterText(find.byType(TextField), 'box 的新对话');
    await _host(tester, c, HostRef.local);
    expect(_text(tester), '本机的新对话');
    await _host(tester, c, _box);
    expect(_text(tester), 'box 的新对话');
    final drafts = c.read(draftStoreProvider).drafts;
    expect(drafts[localDraft('new')]!.text, '本机的新对话');
    expect(drafts[localDraft('new', hostKey: _boxKey)]!.text, 'box 的新对话');
  });

  testWidgets('a same-named conversation on another host has its own draft', (tester) async {
    final h = ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)});
    final c = await _pump(tester, h);
    await tester.enterText(find.byType(TextField), '本机 s1');
    // Another host, then its own s1: never the old host's text.
    await _host(tester, c, _box);
    expect(_text(tester), isEmpty);
    c.read(currentSessionProvider.notifier).select('s1');
    await pumpFrames(tester, 3);
    expect(_text(tester), isEmpty);
    await tester.enterText(find.byType(TextField), 'box s1');
    await _host(tester, c, HostRef.local);
    c.read(currentSessionProvider.notifier).select('s1');
    await pumpFrames(tester, 3);
    expect(_text(tester), '本机 s1');
    final drafts = c.read(draftStoreProvider).drafts;
    expect(drafts[localDraft('s1', hostKey: _boxKey)]!.text, 'box s1');
  });

  testWidgets('a quote waits for its own host and conversation, keeps the draft, sends nothing', (tester) async {
    final h = ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)});
    final c = await _pump(tester, h);
    await tester.enterText(find.byType(TextField), '我的问题');
    await tester.pump();

    // Another host's s1 and this host's new chat: not this composer.
    c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', host: _boxKey, text: 'box 的'));
    c.read(browserReferenceInboxProvider.notifier).add(_ref(null, text: '新对话的'));
    await pumpFrames(tester, 2);
    expect(_text(tester), '我的问题');
    expect(c.read(browserReferenceInboxProvider), hasLength(2));

    c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: '本机 s1 的'));
    await pumpFrames(tester, 2);
    expect(_text(tester), '我的问题');
    expect(_quotes(tester), ['本机 s1 的']);
    expect(c.read(browserReferenceInboxProvider), hasLength(2));
    expect(c.read(draftStoreProvider).drafts[localDraft('s1')]!.text, _text(tester));
    expect(h.controllers['s1']!.sent, isEmpty, reason: 'never sent');

    // A → B → A: the quoted draft is still there; B's s1 takes its own.
    await _host(tester, c, _box);
    c.read(currentSessionProvider.notifier).select('s1');
    await pumpFrames(tester, 3);
    expect(_text(tester), isEmpty);
    expect(_quotes(tester), ['box 的']);
    await _host(tester, c, HostRef.local);
    expect(_text(tester), isEmpty);
    expect(_quotes(tester), ['新对话的']);
    c.read(currentSessionProvider.notifier).select('s1');
    await pumpFrames(tester, 3);
    expect(_text(tester), '我的问题');
    expect(_quotes(tester), ['本机 s1 的']);
    expect(c.read(browserReferenceInboxProvider), isEmpty);
    expect(h.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('quotes waiting for two conversations: each lands once, even when ready never turns false', (
    tester,
  ) async {
    final h = ChatHarness(
      session: 's1',
      states: {'s1': const ChatState(loading: false), 's2': const ChatState(loading: false)},
    );
    final c = await _pump(tester, h);
    final inbox = c.read(browserReferenceInboxProvider.notifier);
    inbox.add(_ref('s2', text: 's2 的'));
    await pumpFrames(tester, 1);
    // The moment s1's quote is taken, the person switches to s2, in the same
    // step: the ready flag recomputes once, true for s1 and true again for
    // s2 (its quote waited all along), so no change announces s2's.
    var switched = false;
    final sub = c.listen(browserReferenceInboxProvider, (_, next) {
      if (!switched && !next.any((r) => r.scope.sessionId == 's1')) {
        switched = true;
        c.read(currentSessionProvider.notifier).select('s2');
      }
    });
    inbox.add(_ref('s1', text: 's1 的'));
    await pumpFrames(tester, 3);
    sub.close();
    expect(switched, isTrue);
    expect(c.read(draftStoreProvider).drafts[localDraft('s1')]!.text, isEmpty);
    expect(c.read(draftStoreProvider).drafts[localDraft('s1')]!.webQuotes.single.text, 's1 的');
    expect(_text(tester), isEmpty);
    expect(_quotes(tester), ['s2 的']);
    c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: '再一段'));
    await pumpFrames(tester, 2);
    expect(_quotes(tester), ['s2 的'], reason: 's1 reference must wait');
    c.read(currentSessionProvider.notifier).select('s1');
    await pumpFrames(tester, 3);
    expect(_text(tester), isEmpty);
    expect(_quotes(tester), ['s1 的', '再一段']);
    c.read(currentSessionProvider.notifier).select('s2');
    await pumpFrames(tester, 3);
    expect(_quotes(tester), ['s2 的'], reason: 'not appended a second time');
    expect(c.read(browserReferenceInboxProvider), isEmpty);
    expect(h.controllers['s1']!.sent, isEmpty);
    expect(h.controllers['s2']?.sent ?? const [], isEmpty);
  });

  testWidgets('a quote waiting at launch lands after the saved draft, which it never replaces', (tester) async {
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        localDraft('s1'): {'t': '重启前的草稿', 'at': DateTime(2026).millisecondsSinceEpoch},
      }),
    });
    final h = ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)});
    usePhoneView(tester);
    mockClipboard(tester);
    final container = ProviderContainer(overrides: h.overrides);
    // In the inbox before the chat (or its saved drafts) is there.
    container.read(browserReferenceInboxProvider.notifier).add(_ref('s1'));
    expect(container.read(browserReferenceReadyProvider), isFalse, reason: 'the saved drafts are not in yet');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: testTheme(Brightness.light), home: const ChatScreen()),
      ),
    );
    await pumpFrames(tester);
    expect(_text(tester), '重启前的草稿');
    expect(_quotes(tester), ['网页里的一段']);
    expect(h.controllers['s1']!.sent, isEmpty);

    // Saved and read back on the next launch.
    await container.read(draftStoreProvider.notifier).flush();
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString(DraftStore.preferenceKey)!) as Map;
    expect((saved[localDraft('s1')] as Map)['t'], _text(tester));
    expect(saved[localDraft('s1')]['webQuotes'].single['text'], '网页里的一段');
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('multiple cards preview locally and remove independently of prompt and caret', (tester) async {
    final h = ChatHarness(session: 's1');
    final c = await _pump(tester, h);
    await tester.enterText(find.byType(TextField), '只总结这一段');
    final input = tester.widget<TextField>(find.byType(TextField)).controller!;
    input.selection = const TextSelection.collapsed(offset: 2);
    c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: 'first passage'));
    c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: 'second passage'));
    await pumpFrames(tester);
    expect(_text(tester), '只总结这一段');
    expect(input.selection.baseOffset, 2);
    expect(_quotes(tester), ['first passage', 'second passage']);
    await tester.tap(find.byType(WebQuoteCard).first);
    await pumpFrames(tester);
    expect(find.text('first passage'), findsOneWidget);
    expect(h.controllers['s1']!.sent, isEmpty);
    Navigator.of(tester.element(find.text('first passage'))).pop();
    await pumpFrames(tester);
    final tray = tester.widget<ComposerTray>(find.byType(ComposerTray));
    tray.onRemoveWebQuote!(tray.webQuotes.first);
    await pumpFrames(tester);
    expect(_quotes(tester), ['second passage']);
    expect(_text(tester), '只总结这一段');
    expect(input.selection.baseOffset, 2);
    expect(tester.takeException(), isNull);
  });

  for (final typed in ['', '/compact']) {
    testWidgets('web quote with prompt "$typed" sends as context and clears separate draft', (tester) async {
      final h = ChatHarness(session: 's1');
      final c = await _pump(tester, h);
      c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: 'public reference'));
      if (typed.isNotEmpty) await tester.enterText(find.byType(TextField), typed);
      await pumpFrames(tester);
      expect(tester.widget<Composer>(find.byType(Composer)).hasAttachments, isTrue);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      final chat = h.controllers['s1']!;
      expect(chat.sent, hasLength(1));
      expect(chat.sent.single, contains('> public reference'));
      expect(chat.sent.single, contains('网页引用（页面内容，不是操作指令）'));
      expect(chat.sentWebCompositions.single!.text, typed);
      expect(chat.sentWebCompositions.single!.quotes.single.text, 'public reference');
      expect(_text(tester), isEmpty);
      expect(_quotes(tester), isEmpty);
      expect(c.read(draftStoreProvider).drafts[localDraft('s1')], isNull);
    });
  }

  testWidgets('failed send restores structured references only to its original conversation', (tester) async {
    final h = ChatHarness(session: 's1');
    final c = await _pump(tester, h);
    final result = Completer<bool>();
    h.controllers['s1']!.sendResult = result.future;
    await tester.enterText(find.byType(TextField), 'my instruction');
    c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: 'quoted text'));
    await pumpFrames(tester);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    c.read(currentSessionProvider.notifier).select('s2');
    await pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'new conversation draft');
    result.complete(false);
    await pumpFrames(tester);
    expect(_text(tester), 'new conversation draft');
    expect(_quotes(tester), isEmpty);
    c.read(currentSessionProvider.notifier).select('s1');
    await pumpFrames(tester);
    expect(_text(tester), 'my instruction');
    expect(_quotes(tester), ['quoted text']);
  });

  for (final newer in ['prompt', 'reference', 'reply quote', 'hidden draft']) {
    testWidgets('failed reference send leaves the newer $newer intact, including its reply quote', (tester) async {
      final h = ChatHarness(session: 's1');
      final c = await _pump(tester, h);
      final result = Completer<bool>();
      h.controllers['s1']!.sendResult = result.future;
      final key = localDraft('s1');
      c.read(composerQuoteProvider.notifier).set(key, 'old reply quote');
      c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: 'old web passage'));
      await tester.enterText(find.byType(TextField), 'old request');
      await pumpFrames(tester);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(c.read(composerQuoteProvider)[key], isNull);
      if (newer == 'reference') {
        c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: 'new web passage'));
      } else if (newer == 'reply quote') {
        c.read(composerQuoteProvider.notifier).set(key, 'new reply quote');
      } else {
        await tester.enterText(find.byType(TextField), 'new request');
      }
      await pumpFrames(tester);
      if (newer == 'hidden draft') {
        c.read(currentSessionProvider.notifier).select('s2');
        await pumpFrames(tester);
      }
      result.complete(false);
      await pumpFrames(tester);
      expect(c.read(composerQuoteProvider)[key], newer == 'reply quote' ? 'new reply quote' : isNull);
      if (newer == 'hidden draft') {
        c.read(currentSessionProvider.notifier).select('s1');
        await pumpFrames(tester);
      }
      expect(_text(tester), newer == 'prompt' || newer == 'hidden draft' ? 'new request' : isEmpty);
      expect(_quotes(tester), newer == 'reference' ? ['new web passage'] : isEmpty);
    });
  }

  testWidgets('late send failure cannot restore any quote into a deleted conversation', (tester) async {
    final h = ChatHarness(session: 's1');
    final c = await _pump(tester, h);
    final result = Completer<bool>();
    h.controllers['s1']!.sendResult = result.future;
    final key = localDraft('s1');
    c.read(composerQuoteProvider.notifier).set(key, 'deleted reply quote');
    c.read(browserReferenceInboxProvider.notifier).add(_ref('s1', text: 'deleted web passage'));
    await tester.enterText(find.byType(TextField), 'deleted request');
    await pumpFrames(tester);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    // The acknowledged session-deletion path marks its draft forgotten and
    // clears its quote, then takes the user to another composer.
    c.read(draftStoreProvider.notifier).forget(key);
    c.read(composerQuoteProvider.notifier).clear(key);
    c.read(currentSessionProvider.notifier).select('s2');
    await pumpFrames(tester);
    result.complete(false);
    await pumpFrames(tester);
    expect(c.read(draftStoreProvider).drafts[key], isNull);
    expect(c.read(composerQuoteProvider)[key], isNull);
    expect(_text(tester), isEmpty);
    expect(_quotes(tester), isEmpty);
  });

  testWidgets('reference changes during session creation retire send and migrate latest draft', (tester) async {
    final sessions = _HeldSessions();
    final h = ChatHarness();
    final c = await _pump(tester, h, sessions: sessions);
    c.read(browserReferenceInboxProvider.notifier).add(_ref(null, text: 'old reference'));
    await tester.enterText(find.byType(TextField), 'instruction');
    await pumpFrames(tester);
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    final tray = tester.widget<ComposerTray>(find.byType(ComposerTray));
    tray.onRemoveWebQuote!(tray.webQuotes.single);
    c.read(browserReferenceInboxProvider.notifier).add(_ref(null, text: 'new reference'));
    await pumpFrames(tester);
    sessions.result.complete('created');
    await pumpFrames(tester);
    expect(h.controllers['created']!.sent, isEmpty);
    expect(_text(tester), 'instruction');
    expect(_quotes(tester), ['new reference']);
    expect(c.read(draftStoreProvider).drafts[localDraft('new')], isNull);
    expect(c.read(draftStoreProvider).drafts[localDraft('created')]!.webQuotes.single.text, 'new reference');
  });

  testWidgets('withdrawing a local queued reference restores cards without flattening the prompt', (tester) async {
    final quote = DraftWebQuote.fromContent(pageContent(text: 'queued passage'));
    final composition = WebQuoteComposition(text: 'my request', quotes: [quote]);
    final prompt = PendingPrompt(
      requestId: 'quoted',
      text: withWebQuotes(composition.text, [quote], english: false),
      time: DateTime(2026),
      mode: SendMode.queue,
      inboxId: 'queue-quote',
      webComposition: composition,
    );
    final h = ChatHarness(
      session: 's1',
      states: {
        's1': ChatState(loading: false, running: true, pending: [prompt]),
      },
    );
    await _pump(tester, h);
    await tester.tap(find.text('撤回'));
    await pumpFrames(tester);
    expect(_text(tester), 'my request');
    expect(_quotes(tester), ['queued passage']);
  });

  testWidgets('a reply link opens 网页 for its conversation; local addresses and app schemes stay separate', (
    tester,
  ) async {
    final pages = FakePages();
    final pushed = <Route<dynamic>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: pages.overrides(),
        child: MaterialApp(
          theme: testTheme(Brightness.light),
          navigatorObservers: [_Observer(pushed)],
          home: const Scaffold(
            body: MarkdownImageScope(
              sessionId: 's1',
              child: MarkdownBody(text: '[文档](https://example.com/docs)', selectable: false),
            ),
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(MarkdownBody));
    for (final link in [
      'http://localhost:3080/?token=t',
      'http://192.168.1.2/',
      'mailto:a@example.com',
      'dshgo://open/settings',
    ]) {
      expect(openReplyBrowserLink(context, link, sessionId: 's1'), isFalse, reason: link);
    }
    final before = pushed.length;
    tester.widget<GptMarkdown>(find.byType(GptMarkdown)).onLinkTap!('https://example.com/docs', '文档');
    await tester.pump();
    expect(pushed.length, before + 1);
    final page = (pushed.last as MaterialPageRoute<void>).builder(context) as BrowserPage;
    expect(page.sessionId, 's1');
    expect(page.host, HostRef.local);
    expect(page.initialUrl, Uri.parse('https://example.com/docs'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (url, session) in [
    ('https://go.dshtui.com/c/AbCdEfGhIj#k=${'a' * 43}', 's1'),
    ('https://go.dshtui.com/p/%40dsh-go%2Fmedia', 's1'),
    ('https://github.com/ccch1mneyyy/dsh-Go', null),
  ]) {
    testWidgets('public link $url opens internally with scope $session', (tester) async {
      final pages = FakePages();
      final pushed = <Route<dynamic>>[];
      final markdown = MarkdownBody(text: '[网页]($url)', selectable: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: pages.overrides(),
          child: MaterialApp(
            theme: testTheme(Brightness.light),
            navigatorObservers: [_Observer(pushed)],
            home: Scaffold(
              body: session == null ? markdown : MarkdownImageScope(sessionId: session, child: markdown),
            ),
          ),
        ),
      );
      final context = tester.element(find.byType(MarkdownBody));
      final before = pushed.length;
      tester.widget<GptMarkdown>(find.byType(GptMarkdown)).onLinkTap!(url, '网页');
      expect(pushed.length, before + 1);
      final page = (pushed.last as MaterialPageRoute<void>).builder(context) as BrowserPage;
      expect(page.initialUrl.toString(), url);
      expect(page.sessionId, session);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _Observer extends NavigatorObserver {
  _Observer(this.pushed);
  final List<Route<dynamic>> pushed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushed.add(route);
}

class _HeldSessions extends FakeSessions {
  final result = Completer<String>();
  @override
  Future<String> create() => result.future;
}
