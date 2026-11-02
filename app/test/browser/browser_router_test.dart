import 'dart:async';

import 'package:dsh_app/browser/browser_links.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/browser/browser_router.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'browser_widget_fakes.dart';

void main() {
  testWidgets('ordinary app links open in the root browser and notify on return', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final key = GlobalKey<NavigatorState>();
    final pages = FakePages();
    final router = AppBrowserRouter(navigatorKey: key, host: () => const HostRef.ssh('chosen'))..attach();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: pages.overrides(),
        child: MaterialApp(
          theme: buildLightTheme(),
          navigatorKey: key,
          home: const Scaffold(body: Text('settings')),
        ),
      ),
    );
    final returned = BrowserLinks.pageReturns.first;
    final url = Uri.parse('https://example.com/account?private=value#section');
    expect(await BrowserLinks.open(url), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final page = tester.widget<BrowserPage>(find.byType(BrowserPage));
    expect(page.host, const HostRef.ssh('chosen'));
    expect(page.sessionId, isNull);
    expect(page.initialUrl, url);
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(await returned, Uri.parse('https://example.com/account'));
    expect(find.text('settings'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one authorization per attempt; completion removes only its own route', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final router = AppBrowserRouter(
      navigatorKey: key,
      host: () => HostRef.local,
      authorizationBuilder: (_, _) => const Scaffold(body: Text('authorize')),
    )..attach();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const Scaffold(body: Text('account')),
      ),
    );
    final done = Completer<void>();
    var cancellations = 0;
    final request = BrowserAuthorization(
      id: Object(),
      url: Uri.parse('https://example.com/authorize'),
      completed: done.future,
      isCurrent: () => !done.isCompleted,
      cancel: () async {
        cancellations++;
      },
    );
    expect(await BrowserLinks.authorize(request), isTrue);
    expect(await BrowserLinks.authorize(request), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('authorize'), findsOneWidget);
    unawaited(key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('later')))));
    await tester.pumpAndSettle();
    done.complete();
    await tester.pumpAndSettle();
    expect(find.text('later'), findsOneWidget);
    expect(find.text('authorize', skipOffstage: false), findsNothing);
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('account'), findsOneWidget);
    expect(cancellations, 0);
  });

  testWidgets('back cancels; explicit system handoff keeps the same login active', (tester) async {
    final key = GlobalKey<NavigatorState>();
    late VoidCallback handoff;
    final router = AppBrowserRouter(
      navigatorKey: key,
      host: () => HostRef.local,
      authorizationBuilder: (_, action) {
        handoff = action;
        return const Scaffold(body: Text('authorize'));
      },
    )..attach();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const Scaffold(body: Text('account')),
      ),
    );
    var cancellations = 0;
    final ended = <Completer<void>>[];
    var handoffs = 0;
    BrowserAuthorization request() {
      final done = Completer<void>();
      ended.add(done);
      return BrowserAuthorization(
        id: Object(),
        url: Uri.parse('https://example.com/authorize'),
        completed: done.future,
        isCurrent: () => !done.isCompleted,
        cancel: () async {
          cancellations++;
          done.complete();
        },
        onSystemBrowserOpened: () => handoffs++,
      );
    }

    await BrowserLinks.authorize(request());
    await tester.pumpAndSettle();
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(cancellations, 1);
    final next = request();
    await BrowserLinks.authorize(next);
    await tester.pumpAndSettle();
    handoff();
    await tester.pumpAndSettle();
    expect(handoffs, 1);
    expect(cancellations, 1);
    expect(next.isCurrent(), isTrue);
    expect(find.text('account'), findsOneWidget);
    ended.last.complete();
    await tester.pump();
  });
}
