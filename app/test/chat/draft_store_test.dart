import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/browser/browser_models.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/web_quote.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/composer_fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only text survives a provider scope restart; empty slots are deleted', () async {
    var container = ProviderContainer();
    var store = container.read(draftStoreProvider.notifier);
    final image = DraftAttachment.sniff('图片.png', tinyPng);
    final a = draftStorageKey(hostKey: 'local:local', sessionId: 'a');
    final b = draftStorageKey(hostKey: 'local:local', sessionId: 'b');
    store.save(a, 'A 草稿', [image]);
    store.save(b, 'B 草稿', const []);
    store.clear(b);
    await store.flush();
    container.dispose();
    container = ProviderContainer();
    store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts[a]!.text, 'A 草稿');
    expect(drafts[a]!.attachments, isEmpty);
    expect(drafts.containsKey(b), isFalse);
    container.dispose();
  });

  test('unscoped v2 drafts remain recoverable beside host-scoped drafts', () async {
    final scopedKey = draftStorageKey(hostKey: 'local:local', sessionId: 'scoped-chat');
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        'new': {'t': '旧版新对话草稿', 'at': 30},
        'old-chat': {'t': '旧版会话草稿', 'at': 20},
        scopedKey: {'t': '新版本会话草稿', 'at': 40},
      }),
      DraftStore.legacyPreferenceKey: jsonEncode({
        'older-chat': {'t': '更早版本的草稿', 'at': 10},
      }),
    });

    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final state = container.read(draftStoreProvider);
    expect(state.drafts.keys, [scopedKey]);
    expect(state.legacyDrafts.keys, containsAll(['new', 'old-chat', 'older-chat']));
    expect(state.legacyDrafts['new']!.text, '旧版新对话草稿');
    expect(state.legacyDrafts['old-chat']!.text, '旧版会话草稿');
    expect(state.drafts[scopedKey]!.text, '新版本会话草稿');

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString(DraftStore.preferenceKey)!) as Map;
    final legacy = jsonDecode(prefs.getString(DraftStore.legacyPreferenceKey)!) as Map;
    expect(saved.keys, [scopedKey]);
    expect(legacy['new']['t'], '旧版新对话草稿');
    expect(legacy['old-chat']['t'], '旧版会话草稿');
    expect(legacy['older-chat']['t'], '更早版本的草稿');
    container.dispose();
  });

  test('unscoped v2 web references remain recoverable and can be appended', () async {
    final previousQuote = DraftWebQuote.fromContent(
      BrowserPageContent(
        url: Uri.https('example.com', '/older-article'),
        title: 'Older article',
        text: 'Passage from the old browser',
        selection: true,
        truncated: false,
      ),
    );
    final currentQuote = DraftWebQuote.fromContent(
      BrowserPageContent(
        url: Uri.https('example.org', '/current-article'),
        title: 'Current article',
        text: 'Passage already in the composer',
        selection: false,
        truncated: false,
      ),
    );
    final target = draftStorageKey(hostKey: 'local:local', sessionId: 'current-chat');
    final image = DraftAttachment.sniff('current.png', tinyPng);
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        'new': {
          't': '旧版网页草稿',
          'at': 30,
          'webQuotes': [previousQuote.toJson()],
        },
      }),
    });

    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final legacyQuote = container.read(draftStoreProvider).legacyDrafts['new']!.webQuotes.single;
    expect(legacyQuote.id, previousQuote.id);
    expect(legacyQuote.text, previousQuote.text);
    store.save(target, '当前草稿', [image], webQuotes: [currentQuote]);
    expect(
      store.importLegacy(legacyKey: 'new', expectedText: '旧版网页草稿', expectedWebQuotes: [legacyQuote], targetKey: target),
      isTrue,
    );

    final recovered = container.read(draftStoreProvider).drafts[target]!;
    expect(recovered.text, '当前草稿\n\n旧版网页草稿');
    expect(recovered.attachments.single, same(image));
    expect(recovered.webQuotes.map((quote) => quote.id), [currentQuote.id, legacyQuote.id]);
    await store.flush();
    final preferences = await SharedPreferences.getInstance();
    final migratedLegacy = jsonDecode(preferences.getString(DraftStore.legacyPreferenceKey)!) as Map;
    expect(migratedLegacy['new']['webQuotes'].single['text'], 'Passage from the old browser');
    container.dispose();
  });

  test('a picture pasted as its bytes is not put back, what was typed before it is (#1684)', () async {
    // As Android reads them: what UTF-8 cannot decode is U+FFFD.
    final jpeg = '\ufffd\ufffd\ufffd\ufffd\u0000\u0010JFIF\u0000MM\u0000*' * 1000;
    final png = '\ufffdPNG\r\n\u001a\n\u0000\u0000\u0000\rIHDR' * 1000;
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        draftStorageKey(hostKey: 'local:local', sessionId: 'pasted'): {'t': jpeg, 'at': 5},
        draftStorageKey(hostKey: 'local:local', sessionId: 'png'): {'t': png, 'at': 4},
        draftStorageKey(hostKey: 'local:local', sessionId: 'both'): {'t': '看看这张图 $jpeg', 'at': 3},
        draftStorageKey(hostKey: 'local:local', sessionId: 'cafe'): {'t': 'café$png', 'at': 2},
        draftStorageKey(hostKey: 'local:local', sessionId: 'typed'): {'t': '明天再问', 'at': 1},
      }),
    });
    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts.keys, [
      draftStorageKey(hostKey: 'local:local', sessionId: 'both'),
      draftStorageKey(hostKey: 'local:local', sessionId: 'cafe'),
      draftStorageKey(hostKey: 'local:local', sessionId: 'typed'),
    ]);
    expect(drafts[draftStorageKey(hostKey: 'local:local', sessionId: 'both')]!.text, '看看这张图');
    expect(drafts[draftStorageKey(hostKey: 'local:local', sessionId: 'cafe')]!.text, 'café');
    expect(drafts[draftStorageKey(hostKey: 'local:local', sessionId: 'typed')]!.text, '明天再问');
    container.dispose();
  });

  test('what was typed before the saved drafts load wins', () async {
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        draftStorageKey(hostKey: 'local:local', sessionId: 'a'): {'t': '旧文', 'at': 1},
        draftStorageKey(hostKey: 'local:local', sessionId: 'b'): {'t': 'B 的旧文', 'at': 2},
      }),
    });
    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    store.save(draftStorageKey(hostKey: 'local:local', sessionId: 'a'), '刚输入的', const []);
    await store.flush();
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts[draftStorageKey(hostKey: 'local:local', sessionId: 'a')]!.text, '刚输入的');
    expect(drafts[draftStorageKey(hostKey: 'local:local', sessionId: 'b')]!.text, 'B 的旧文');
    container.dispose();
  });

  test('keeps at most 30 drafts', () async {
    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    for (var i = 0; i < 35; i++) {
      store.save(draftStorageKey(hostKey: 'local:local', sessionId: '$i'), '草稿 $i', const []);
    }
    await store.flush();
    expect(container.read(draftStoreProvider).drafts, hasLength(30));
    container.dispose();
  });

  testWidgets('switching conversations restores their own text and attachments', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(session: 'a');
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final image = DraftAttachment.sniff('图片.png', tinyPng);
    container.read(draftStoreProvider.notifier).save(draftStorageKey(hostKey: 'local:local', sessionId: 'b'), 'B 草稿', [
      image,
    ]);
    await tester.enterText(find.byType(TextField), 'A 草稿');
    container.read(currentSessionProvider.notifier).select('b');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'B 草稿');
    expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items, [image]);
    container.read(currentSessionProvider.notifier).select('a');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'A 草稿');
    expect(find.byType(ComposerTray), findsNothing);
    container.read(currentSessionProvider.notifier).select('c');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.byType(ComposerTray), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a delayed send failure restores only its own conversation', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(session: 'a');
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final result = Completer<bool>();
    harness.controllers['a']!.sendResult = result.future;
    await tester.enterText(find.byType(TextField), 'A 的消息');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    container.read(currentSessionProvider.notifier).select('b');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'B 的草稿');
    result.complete(false);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'B 的草稿');
    container.read(currentSessionProvider.notifier).select('a');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'A 的消息');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('switching conversations cancels active dictation', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final bridge = FakeVoiceBridge();
    final harness = ChatHarness(session: 'a');
    await tester.pumpWidget(
      testApp(const ChatScreen(), overrides: [...harness.overrides, voiceBridgeProvider.overrideWithValue(bridge)]),
    );
    await pumpFrames(tester);
    final voice = tester.widget<Composer>(find.byType(Composer)).voice!;
    await voice.start();
    bridge.emit(const VoicePartial('听写内容'));
    await tester.pump();
    expect(voice.active, isTrue);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    container.read(currentSessionProvider.notifier).select('b');
    await tester.pump();
    expect(bridge.calls, contains('cancel'));
    expect(voice.active, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('sending a new conversation leaves the next new draft empty', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(created: 'fresh');
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    container.read(currentSessionProvider.notifier).select(null);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
