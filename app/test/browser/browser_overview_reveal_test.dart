import 'dart:async';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:dsh_app/ui/browser/browser_tabs_overview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final reduced in [false, true]) {
    testWidgets('overview reveals the live page before dismissal, reduced=$reduced', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final pages = FakePages(finishDuringInitialization: true);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: BrowserPage(host: HostRef.local, initialUrl: Uri.parse('https://example.com/')),
            ),
          ),
          overrides: pages.overrides(),
        ),
      );
      await pumpFrames(tester, 5);
      await tester.tap(find.byKey(const ValueKey('browser-tabs')));
      await pumpFrames(tester, 8);
      final overview = find.byType(BrowserTabsOverview);
      expect(overview, findsOneWidget);
      final live = find.byKey(const ValueKey('fake-browser-view'));
      expect(live, findsNothing, reason: 'web content stays offstage while choosing a tab');
      final state = tester.state<BrowserTabsOverviewState>(overview);
      var done = false;
      unawaited(state.leave().then((_) => done = true));
      await tester.pump();
      expect(live, findsOneWidget, reason: 'real page paints before the snapshot is removed');
      expect(overview, findsOneWidget);
      if (!reduced) {
        var sawFade = false;
        for (var frame = 0; frame < 40 && !done; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (overview.evaluate().isNotEmpty) {
            final opacity = find.descendant(of: overview, matching: find.byType(Opacity));
            sawFade |= tester.widgetList<Opacity>(opacity).any((w) => w.opacity > 0 && w.opacity < 1);
          }
        }
        expect(sawFade, isTrue, reason: 'snapshot must visibly fade while real content already paints');
      }
      await pumpFrames(tester, 5);
      expect(done, isTrue);
      expect(overview, findsNothing);
      expect(live, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
