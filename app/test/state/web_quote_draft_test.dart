import 'dart:convert';

import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/web_quote.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DraftWebQuote reference([String text = 'A useful passage']) => DraftWebQuote.fromContent(
  BrowserPageContent(
    url: Uri.parse('https://example.com/article?token=private#fragment'),
    title: 'Page title',
    text: text,
    selection: true,
    truncated: false,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reference-only draft survives restart; editing text preserves references; clear removes both', () async {
    var c = ProviderContainer();
    var store = c.read(draftStoreProvider.notifier);
    final quote = reference();
    store.save('one', '', [], webQuotes: [quote]);
    store.save('two', 'prompt', [], webQuotes: [reference('second')]);
    store.save('two', 'edited', []);
    await store.flush();
    final raw = (await SharedPreferences.getInstance()).getString(DraftStore.preferenceKey)!;
    expect(raw, isNot(contains('token=private')));
    c.dispose();
    c = ProviderContainer();
    store = c.read(draftStoreProvider.notifier);
    await store.flush();
    expect(c.read(draftStoreProvider).drafts['one']!.text, isEmpty);
    expect(c.read(draftStoreProvider).drafts['one']!.webQuotes.single.toJson(), quote.toJson());
    expect(c.read(draftStoreProvider).drafts['two']!.text, 'edited');
    expect(c.read(draftStoreProvider).drafts['two']!.webQuotes.single.text, 'second');
    store.clear('one');
    await store.flush();
    expect(jsonDecode((await SharedPreferences.getInstance()).getString(DraftStore.preferenceKey)!)['one'], isNull);
    c.dispose();
  });

  test('restored references reject invalid addresses, de-duplicate IDs and bound content/count', () {
    final json = reference().toJson();
    expect(DraftWebQuote.fromJson({...json, 'url': 'file:///secret'}), isNull);
    expect(DraftWebQuote.fromJson({...json, 'url': 'http://127.0.0.1/'}), isNull);
    expect(DraftWebQuote.fromJson({...json, 'text': 42}), isNull);
    final clipped = DraftWebQuote.fromJson({...json, 'text': '${'x' * 20000}\u202e'})!;
    expect(clipped.text.length, BrowserPageContent.maxChars);
    expect(clipped.truncated, isTrue);
    expect(DraftWebQuote.readList([json, json]), hasLength(1));
    expect(
      DraftWebQuote.readList([
        for (var i = 0; i < 40; i++) {...json, 'id': 'id-$i'},
      ]),
      hasLength(DraftWebQuote.limit),
    );
  });

  test('forget prevents a late load or late quote recovery resurrecting a deleted conversation', () async {
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        'gone': {
          't': '',
          'at': 1,
          'webQuotes': [reference().toJson()],
        },
      }),
    });
    final c = ProviderContainer();
    final store = c.read(draftStoreProvider.notifier);
    store.forget('gone');
    store.save('gone', '', [], webQuotes: [reference()]);
    await store.flush();
    expect(c.read(draftStoreProvider).drafts['gone'], isNull);
    c.dispose();
  });

  test('reference capacity includes cards already claimed by the composer', () async {
    final c = ProviderContainer();
    final store = c.read(draftStoreProvider.notifier);
    await store.flush();
    const scope = BrowserScope(hostKey: 'local:local', sessionId: 's1');
    store.save(
      draftStorageKey(hostKey: scope.hostKey, sessionId: scope.sessionId),
      '',
      [],
      webQuotes: [for (var i = 0; i < DraftWebQuote.limit; i++) reference()],
    );
    expect(
      () => c
          .read(browserReferenceInboxProvider.notifier)
          .add(BrowserReference(scope: scope, content: reference().content)),
      throwsStateError,
    );
    c.dispose();
  });

  test('local queued composition survives queue placement and mode changes', () {
    final composition = WebQuoteComposition(text: 'prompt', quotes: [reference()], replyQuote: 'reply');
    final p = PendingPrompt(requestId: 'r', text: 'transport text', time: DateTime(2026), webComposition: composition);
    expect(p.withMode(SendMode.queue).placed('inbox', InboxSlot.nextTurn).webComposition, same(composition));
  });
}
