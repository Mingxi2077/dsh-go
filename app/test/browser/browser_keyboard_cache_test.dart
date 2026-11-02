import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/browser/browser_home.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

void main() {
  setUpAll(loadTestFonts);
  testWidgets('closing insets cannot poison the keyboard height for the next search', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const BrowserPage(host: HostRef.local), overrides: FakePages().overrides()));
    await pumpFrames(tester, 3);
    final box = find.byKey(const ValueKey('browser-home-search'));
    await tester.tap(box);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await pumpFrames(tester, 5);
    expect(tester.widget<BrowserHome>(find.byType(BrowserHome)).knownKeyboard, 300);
    for (final height in [480.0, 160.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: height);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await pumpFrames(tester, 5);
    expect(tester.widget<BrowserHome>(find.byType(BrowserHome)).editing, isFalse);
    await tester.tap(box);
    await tester.pump();
    final home = tester.widget<BrowserHome>(find.byType(BrowserHome));
    expect(home.editing, isTrue);
    expect(home.knownKeyboard, 300, reason: 'next entry uses the expanded height, not a closing frame');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
