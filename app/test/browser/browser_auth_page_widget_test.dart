// 登录页 (BrowserAuthPage): the real host only (never the authorize query,
// code or state), loading and finishing states, close pops, 在系统浏览器中打开
// hands over only when the system browser really opened, a lost renderer
// hides the view and reopening makes a fresh controller, and controllers are
// destroyed only after their view left the tree. The controller is a fake.

import 'dart:async';

import 'package:dsh_app/browser/browser_auth_controller.dart';
import 'package:dsh_app/browser/browser_links.dart';
import 'package:dsh_app/ui/browser/browser_auth_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

class _FakeAuth extends ChangeNotifier implements BrowserAuthController {
  _FakeAuth(this.request);

  @override
  final BrowserAuthorization request;
  @override
  bool loading = true;
  @override
  int progress = 0;
  @override
  String? error;
  @override
  bool finishing = false;
  @override
  Uri currentUrl = Uri.parse('https://chat.deepseek.com/sign_in?code=SECRET&state=STATE');

  bool initialized = false;
  bool disposed = false;
  bool viewMountedAtDispose = false;
  int reloads = 0;
  bool externalResult = false;
  int externals = 0;

  @override
  Future<void> initialize({required bool dark}) async => initialized = true;
  @override
  Future<void> reload() async => reloads++;
  @override
  Future<bool> openExternal() async {
    externals++;
    if (!externalResult) {
      error = 'external_open_failed';
      notifyListeners();
    }
    return externalResult;
  }

  void set({bool? loading, String? error, bool? finishing}) {
    if (loading != null) this.loading = loading;
    this.error = error;
    if (finishing != null) this.finishing = finishing;
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    viewMountedAtDispose = _mounted.contains(this);
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _mounted = <_FakeAuth>{};

class _View extends StatefulWidget {
  const _View(this.controller);
  final _FakeAuth controller;
  @override
  State<_View> createState() => _ViewState();
}

class _ViewState extends State<_View> {
  @override
  void initState() {
    super.initState();
    _mounted.add(widget.controller);
  }

  @override
  void dispose() {
    _mounted.remove(widget.controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: ValueKey('fake-auth-view'));
}

void main() {
  setUpAll(loadTestFonts);

  late List<_FakeAuth> made;
  late int handedOver;
  late int requestNotified;
  late BrowserAuthorization request;

  setUp(() {
    made = [];
    handedOver = 0;
    requestNotified = 0;
    request = BrowserAuthorization(
      id: 1,
      url: Uri.parse('https://chat.deepseek.com/authorize?client_id=x&state=STATE'),
      completed: Completer<void>().future,
      isCurrent: () => true,
      cancel: () async {},
      // The root router's handoff notifies this; the page never does itself.
      onSystemBrowserOpened: () => requestNotified++,
    );
    BrowserAuthPage.debugController = (request) {
      final c = _FakeAuth(request);
      made.add(c);
      return c;
    };
    BrowserAuthPage.debugView = (c) => _View(c as _FakeAuth);
  });

  Future<void> pump(WidgetTester tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BrowserAuthPage(request: request, onSystemBrowserOpened: () => handedOver++),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // Not settled: the loading line is indeterminate.
    await pumpFrames(tester, 5);
  }

  testWidgets('shows only the real host while loading; close pops and destroys after the view left', (tester) async {
    await pump(tester);
    final c = made.single;
    expect(c.initialized, isTrue);
    expect(find.text('chat.deepseek.com'), findsOneWidget);
    expect(find.textContaining('SECRET'), findsNothing);
    expect(find.textContaining('STATE'), findsNothing);
    expect(find.byKey(const ValueKey('browser-auth-progress')), findsOneWidget);
    c.set(loading: false);
    await tester.pump();
    expect(find.byKey(const ValueKey('browser-auth-progress')), findsNothing);

    c.set(finishing: true);
    await tester.pump();
    expect(find.text('正在完成登录…'), findsOneWidget);
    c.set(finishing: false);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('browser-auth-close')));
    await tester.pumpAndSettle();
    expect(find.byType(BrowserAuthPage), findsNothing);
    expect(c.disposed, isTrue);
    expect(c.viewMountedAtDispose, isFalse);
  });

  testWidgets('系统浏览器: handed over only when it opened; a failure stays and says so', (tester) async {
    await pump(tester);
    final c = made.single..set(loading: false);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('browser-auth-system')));
    await tester.pump();
    expect(c.externals, 1);
    expect(handedOver, 0);
    expect(find.text('没能打开系统浏览器'), findsOneWidget);
    expect(find.byType(BrowserAuthPage), findsOneWidget);

    c
      ..externalResult = true
      ..set(error: null);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('browser-auth-system')));
    await tester.pump();
    expect(handedOver, 1);
    expect(requestNotified, 0, reason: 'only the router notifies the request, once');
    expect(find.byType(BrowserAuthPage), findsOneWidget, reason: 'the router decides what closes');
  });

  testWidgets('load failure retries the same controller; a lost renderer hides the view and reopens fresh', (
    tester,
  ) async {
    await pump(tester);
    final first = made.single..set(loading: false, error: 'load_failed');
    await tester.pump();
    expect(find.text('检查网络后再试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(first.reloads, 1);

    first.set(error: 'renderer_gone');
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-auth-view')), findsNothing);
    expect(find.text('网页已关闭'), findsOneWidget);
    await tester.tap(find.text('重新打开'));
    await tester.pump();
    await tester.pump();
    expect(made, hasLength(2));
    expect(made.last.initialized, isTrue);
    expect(first.disposed, isTrue);
    expect(first.viewMountedAtDispose, isFalse);
    expect(find.byKey(const ValueKey('fake-auth-view')), findsOneWidget);
  });
}
