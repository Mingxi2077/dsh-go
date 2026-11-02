import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/ui/browser/browser_quote_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final changed in [false, true]) {
    testWidgets('selection preview ${changed ? 'rejects a same-path URL change' : 'requires explicit confirmation'}', (
      tester,
    ) async {
      usePhoneView(tester);
      final page = FakeBrowserPage(
        initialUrl: Uri.parse('https://example.com/docs?article=one'),
        onPageChanged: (_, _) {},
      )..finish();
      addTearDown(page.dispose);
      const scope = BrowserScope(hostKey: 'local:local', sessionId: 'quote-test');
      final sheet = BrowserQuoteSheet(
        page: page,
        scope: scope,
        target: (chat: 'Test', host: 'Local'),
        initialContent: BrowserPageContent(
          url: Uri.parse('https://example.com/docs'),
          title: 'Example',
          text: 'Selected words',
          selection: true,
          truncated: false,
        ),
      );
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: sheet))),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await pumpFrames(tester, 2);
      final container = ProviderScope.containerOf(tester.element(find.byType(BrowserQuoteSheet)));
      expect(container.read(browserReferenceInboxProvider), isEmpty);
      expect(find.text('Selected words'), findsOneWidget);
      if (changed) {
        // Same saved source and revision, but a different full URL (e.g. an
        // in-document address update). It must invalidate the preview.
        page.finish(at: Uri.parse('https://example.com/docs?article=two'));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('browser-quote-confirm')));
      await pumpFrames(tester, 2);
      final inbox = container.read(browserReferenceInboxProvider);
      expect(inbox, changed ? isEmpty : hasLength(1));
      if (!changed) {
        expect(inbox.single.scope, scope);
        expect(inbox.single.content.text, 'Selected words');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
