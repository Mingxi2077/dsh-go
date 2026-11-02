import 'package:dsh_app/browser/browser_return.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final exit in [true, false]) {
    testWidgets('${exit ? 'close' : 'return to chat'} preserves earlier side tags, loading tab counts', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final pages = FakePages();
      late BuildContext origin;
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) {
              origin = context;
              return const Scaffold(body: Text('chat'));
            },
          ),
          overrides: pages.overrides(),
        ),
      );
      final container = ProviderScope.containerOf(origin);
      container.read(currentSessionProvider.notifier).select('chat');
      final workspace = container.read(browserWorkspaceProvider.notifier);
      const scope = BrowserScope(hostKey: 'local:local', sessionId: 'chat');
      final url = Uri.parse('https://example.com/earlier');
      final opening = workspace.open(scope, url);
      await tester.pump();
      final earlier = await opening;
      container
          .read(browserReturnProvider.notifier)
          .remember(host: HostRef.local, sessionId: 'chat', tabId: earlier.id, url: url, title: 'Earlier');
      Navigator.of(
        origin,
      ).push(BrowserPage.route(host: HostRef.local, sessionId: 'chat', url: Uri.parse('https://example.org/loading')));
      await pumpFrames(tester, 5);
      final loading = container.read(browserWorkspaceProvider).selectedFor(scope)!;
      expect(loading.id, isNot(earlier.id));
      expect(pages.last.ready, isFalse);
      await tester.tap(find.byKey(ValueKey(exit ? 'browser-close' : 'browser-return-to-chat')));
      await pumpFrames(tester, 5);
      expect(find.byType(BrowserPage), findsNothing);
      final tags = container.read(browserReturnProvider).itemsFor(scope);
      expect(tags.any((item) => item.tabId == earlier.id), isTrue);
      expect(tags.any((item) => item.tabId == loading.id), !exit);
      expect(tags.length, exit ? 1 : 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
