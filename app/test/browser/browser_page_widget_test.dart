// 网页 as a daily browser: home page → search, the engine, bookmarks and
// history, suggestions, three live pages kept across tab switches, the card
// overview of tabs (closing with 撤销, closing the last page, snapshots that
// belong to their page), the one home field that keeps its IME session, the
// menu, a 360-wide phone at text size 1.3, reduced motion, and quotes that
// still go to the page's own conversation. The page is a hand-driven fake
// (browser_widget_fakes.dart): no WebView.

import 'package:dsh_app/browser/browser_library.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

const _scope = BrowserScope(hostKey: 'local:local');
final _field = find.byKey(const ValueKey('browser-address-field'));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  FakePages pages, {
  Uri? url,
  bool narrow = false,
  bool reduceMotion = false,
  String? session,
}) async {
  if (narrow) {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(720, 1480);
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
  } else {
    usePhoneView(tester);
  }
  mockClipboard(tester);
  final page = BrowserPage(host: HostRef.local, sessionId: session, initialUrl: url);
  await tester.pumpWidget(
    testApp(
      narrow || reduceMotion
          ? Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: narrow ? const TextScaler.linear(1.3) : null, disableAnimations: reduceMotion),
                child: page,
              ),
            )
          : page,
      overrides: pages.overrides(),
    ),
  );
  await pumpFrames(tester, 3);
  return ProviderScope.containerOf(tester.element(find.byType(BrowserPage)));
}

bool _tapEnabled(WidgetTester tester, String tooltip) =>
    tester
        .widget<InkResponse>(find.descendant(of: find.byTooltip(tooltip), matching: find.byType(InkResponse)))
        .onTap !=
    null;

Future<void> _type(WidgetTester tester, String text, {bool submit = true}) async {
  await tester.enterText(_field, text);
  await pumpFrames(tester, 1);
  if (submit) {
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await pumpFrames(tester, 3);
  }
}

List<BrowserTab> _tabs(ProviderContainer c) => c.read(browserWorkspaceProvider).tabsFor(_scope);

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a new browser opens on its home page: search, shortcuts, menu and tabs reachable', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages);
    expect(find.byKey(const ValueKey('browser-home')), findsOneWidget);
    expect(_tabs(c).single.isHome, isTrue);
    expect(pages.made, isEmpty, reason: 'the home page has no WebView');
    expect(find.text('DSH Go'), findsOneWidget, reason: 'a few known sites before any bookmark');
    expect(find.text('必应'), findsOneWidget);
    expect(find.text('维基百科'), findsOneWidget);
    expect(_tapEnabled(tester, '更多'), isTrue);
    expect(_tapEnabled(tester, '引用到对话'), isFalse);
    expect(find.text('1'), findsOneWidget, reason: 'the tab count');
    expect(find.byType(TextField), findsOneWidget, reason: 'one search box, no second one in the bar');
    expect(find.byKey(const ValueKey('browser-address')), findsNothing);
    expect(find.byKey(const ValueKey('browser-home-search')), findsOneWidget);
    expect(find.bySemanticsLabel('Dsh-Go'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('browser-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-menu-share')), findsNothing, reason: 'no page to act on');
    expect(find.byKey(const ValueKey('browser-menu-library')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-menu-engine')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-menu-textSize')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home → words are searched; an address opens; a blocked protocol says so', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages);
    final home = _tabs(c).single.id;
    await tester.tap(find.byKey(const ValueKey('browser-home-search')));
    await pumpFrames(tester, 2);
    expect(_field, findsOneWidget);

    await _type(tester, 'javascript:alert(1)');
    expect(find.text('这个地址不能在这里打开'), findsOneWidget);
    await _type(tester, 'http://localhost:3080/?token=t');
    expect(find.text('这个地址不能在这里打开'), findsOneWidget);
    expect(pages.made, isEmpty, reason: 'neither is searched for');

    await _type(tester, '天气 怎么样');
    final tab = _tabs(c).single;
    expect(tab.id, home, reason: 'the home tab goes to the page');
    expect(pages.last.url, BrowserSearchEngine.bing.search('天气 怎么样'));
    expect(find.byKey(const ValueKey('browser-home')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('browser-address')));
    await pumpFrames(tester, 2);
    await _type(tester, 'example.com/docs');
    expect(pages.last.loads.last, Uri.parse('https://example.com/docs'), reason: 'same live page');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the chosen engine searches next time', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages);
    await tester.tap(find.byKey(const ValueKey('browser-more')));
    await tester.pumpAndSettle();
    expect(find.text('必应'), findsWidgets, reason: 'the current engine');
    await tester.tap(find.byKey(const ValueKey('browser-menu-engine')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-engine-baidu')));
    await tester.pumpAndSettle();
    expect(c.read(browserLibraryProvider).engine, BrowserSearchEngine.baidu);

    await tester.tap(find.byKey(const ValueKey('browser-home-search')));
    await pumpFrames(tester, 2);
    await _type(tester, 'flutter', submit: false);
    expect(find.text('用 百度 搜索'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await pumpFrames(tester, 3);
    expect(pages.last.url, BrowserSearchEngine.baidu.search('flutter'));
  });

  testWidgets('bookmarks and history: saved from the menu, suggested while typing, edited, removed, cleared', (
    tester,
  ) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://example.com/docs?a=1'));
    final page = pages.last..finish(title: 'Example Docs');
    await pumpFrames(tester, 2);
    // Recorded once for the page, not on every rebuild or notification.
    page.ping();
    await pumpFrames(tester, 2);
    expect(c.read(browserLibraryProvider).history, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('browser-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-menu-bookmark')));
    await tester.pumpAndSettle();
    expect(find.text('已加入书签'), findsOneWidget);
    expect(c.read(browserLibraryProvider).bookmarks.single.url, Uri.parse('https://example.com/docs?a=1'));

    // Suggestions are local: the bookmark comes first, marked as one.
    await tester.tap(find.byKey(const ValueKey('browser-address')));
    await pumpFrames(tester, 2);
    await _type(tester, 'exam', submit: false);
    expect(find.byKey(const ValueKey('browser-suggestion-go')), findsOneWidget);
    final suggestion = find.byKey(const ValueKey('browser-suggestion-https://example.com/docs?a=1'));
    expect(suggestion, findsOneWidget);
    await tester.tap(suggestion);
    await pumpFrames(tester, 3);
    expect(page.loads.last, Uri.parse('https://example.com/docs?a=1'));
    page.finish(title: 'Example Docs');
    await pumpFrames(tester, 2);
    expect(c.read(browserLibraryProvider).history, hasLength(1), reason: 'the same address, not a second entry');

    // 书签与历史: edit the name, then delete; remove and clear history.
    await tester.tap(find.byKey(const ValueKey('browser-more')));
    await pumpFrames(tester, 6);
    await tester.tap(find.byKey(const ValueKey('browser-menu-library')));
    await tester.pumpAndSettle();
    final mark = c.read(browserLibraryProvider).bookmarks.single;
    await tester.tap(
      find.descendant(of: find.byKey(ValueKey('browser-bookmark-${mark.id}')), matching: find.byTooltip('编辑书签')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('browser-bookmark-name')), '文档');
    await tester.tap(find.byKey(const ValueKey('browser-bookmark-save')));
    await tester.pumpAndSettle();
    expect(c.read(browserLibraryProvider).bookmarks.single.title, '文档');
    await tester.tap(find.byTooltip('编辑书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-bookmark-delete')));
    await tester.pumpAndSettle();
    expect(c.read(browserLibraryProvider).bookmarks, isEmpty);

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await c.read(browserLibraryProvider.notifier).recordVisit(Uri.parse('https://example.org/'), 'Org');
    await tester.pumpAndSettle();
    expect(c.read(browserLibraryProvider).history, hasLength(2));
    await tester.tap(find.byTooltip('删除记录').first);
    await tester.pumpAndSettle();
    expect(c.read(browserLibraryProvider).history, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('browser-history-clear')));
    await tester.pumpAndSettle();
    expect(find.text('书签和打开的标签页不受影响'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('browser-history-clear-confirm')));
    await tester.pumpAndSettle();
    expect(c.read(browserLibraryProvider).history, isEmpty);
    expect(find.text('还没有浏览记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('three live pages survive tab switches; a fourth gives the oldest up', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://a.example.com/'));
    final ws = c.read(browserWorkspaceProvider.notifier);
    final a = pages.last..finish(title: 'A');
    await ws.open(_scope, Uri.parse('https://b.example.com/'));
    await pumpFrames(tester, 2);
    final b = pages.last..finish(title: 'B');
    await ws.open(_scope, Uri.parse('https://c.example.com/'));
    await pumpFrames(tester, 2);
    final cc = pages.last..finish(title: 'C');
    expect(pages.made, hasLength(3));
    expect(a.disposed || b.disposed, isFalse, reason: 'kept in the pool');

    // Back to A: the same page, not loaded again.
    final aTab = _tabs(c).firstWhere((t) => t.url == Uri.parse('https://a.example.com/'));
    await ws.activate(aTab.id);
    await pumpFrames(tester, 2);
    expect(pages.made, hasLength(3));
    expect(a.loads, isEmpty);
    expect(find.text('a.example.com'), findsOneWidget);

    // A fourth live page: B (least recently used) gives its page up.
    await ws.open(_scope, Uri.parse('https://d.example.com/'));
    await pumpFrames(tester, 2);
    expect(pages.made, hasLength(4));
    expect(b.disposed, isTrue);
    expect(a.disposed || cc.disposed, isFalse);
    final bTab = _tabs(c).firstWhere((t) => t.url == Uri.parse('https://b.example.com/'));
    await ws.activate(bTab.id);
    await pumpFrames(tester, 2);
    expect(pages.made, hasLength(5), reason: 'B is made again from its saved address');
    expect(pages.made.where((p) => !p.disposed), hasLength(3));
  });

  testWidgets('home keeps the open page: back to it from 打开的网页 without loading it again', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://example.com/read'));
    final page = pages.last..finish(title: '正在读');
    await tester.tap(find.byKey(const ValueKey('browser-home-key')));
    await pumpFrames(tester, 3);
    expect(find.byKey(const ValueKey('browser-home')), findsOneWidget);
    expect(page.disposed, isFalse);
    final web = _tabs(c).firstWhere((t) => t.url != null);
    await tester.tap(find.byKey(ValueKey('browser-home-tab-${web.id}')));
    await pumpFrames(tester, 3);
    expect(find.text('example.com'), findsOneWidget);
    expect(pages.made, hasLength(1));
    expect(page.loads, isEmpty);
  });

  testWidgets('closing: 撤销 brings a tab back; the last one leaves a home page; 关闭全部 asks', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://example.com/a'));
    pages.last.finish(title: 'A 页');
    await c.read(browserWorkspaceProvider.notifier).open(_scope, Uri.parse('https://example.org/b'));
    await pumpFrames(tester, 2);
    pages.last.finish(title: 'B 页');
    await pumpFrames(tester, 2);

    final aTab = _tabs(c).firstWhere((t) => t.title == 'A 页');
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await pumpFrames(tester, 6);
    expect(find.text('2 个标签页'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byKey(ValueKey('browser-tab-${aTab.id}')), matching: find.byTooltip('关闭标签页')),
    );
    await pumpFrames(tester, 4);
    expect(_tabs(c), hasLength(1));
    expect(find.text('已关闭标签页 · A 页'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('browser-tab-undo')));
    await pumpFrames(tester, 4);
    expect(_tabs(c), hasLength(2));

    await tester.tap(find.byKey(const ValueKey('browser-close-all')));
    await pumpFrames(tester, 4);
    expect(find.text('关闭这个对话的 2 个标签页？'), findsOneWidget);
    expect(find.text('书签和历史会保留'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('browser-close-all-confirm')));
    await pumpFrames(tester, 9); // grow back, then the final snapshot fade
    expect(_tabs(c).single.isHome, isTrue, reason: 'never a blank browser');
    expect(find.byKey(const ValueKey('browser-home')), findsOneWidget);
    expect(pages.made.every((p) => p.disposed), isTrue);

    // Closing the last page from the overview also leaves a home page.
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await pumpFrames(tester, 6);
    await tester.tap(find.byTooltip('关闭标签页'));
    await pumpFrames(tester, 6);
    expect(_tabs(c).single.isHome, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the menu shares, copies and opens the page in the system browser', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages, url: Uri.parse('https://example.com/docs#part'));
    pages.last.finish();
    await pumpFrames(tester, 2);
    for (final (choice, list) in [('share', pages.shared), ('external', pages.external)]) {
      await tester.tap(find.byKey(const ValueKey('browser-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('browser-menu-$choice')));
      await tester.pumpAndSettle();
      expect(list.single, Uri.parse('https://example.com/docs#part'), reason: choice);
    }
    await tester.tap(find.byKey(const ValueKey('browser-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-menu-copy')));
    await tester.pumpAndSettle();
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('网页文字大小 goes to every live page with the app\'s text size', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://example.com/'));
    pages.last.finish();
    await pumpFrames(tester, 2);
    await tester.tap(find.byKey(const ValueKey('browser-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-menu-textSize')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-text-size')), findsOneWidget);
    await c.read(browserLibraryProvider.notifier).setTextZoom(150);
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsWidgets);
    expect(pages.last.zooms.last, 150);
  });

  testWidgets('quotes still go to the page\'s own conversation', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://example.com/docs'), session: 's1');
    final page = pages.last..results[false] = pageContent;
    page.finish();
    await pumpFrames(tester, 2);
    await tester.tap(find.byTooltip('引用到对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-quote-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-quote-confirm')));
    await tester.pumpAndSettle();
    expect(
      c.read(browserReferenceInboxProvider).single.scope,
      const BrowserScope(hostKey: 'local:local', sessionId: 's1'),
    );
  });

  testWidgets('quote: nothing selected says so and never reads the page instead', (tester) async {
    final pages = FakePages();
    await _pump(tester, pages, url: Uri.parse('https://example.com/docs'));
    final page = pages.last;
    expect(_tapEnabled(tester, '引用到对话'), isFalse, reason: 'still loading');
    page.finish();
    await pumpFrames(tester, 2);
    await tester.tap(find.byTooltip('引用到对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-quote-selection')));
    await tester.pumpAndSettle();
    expect(find.text('没有选中文字，先在网页里长按选中'), findsOneWidget);
    expect(page.extracts, [true]);
  });

  testWidgets('immediate ready is recorded once and clearing history survives title notifications and tab switches', (
    tester,
  ) async {
    final pages = FakePages(finishDuringInitialization: true);
    final c = await _pump(tester, pages, url: Uri.parse('https://example.com/first'));
    final first = pages.last;
    final firstTab = _tabs(c).single;
    expect(c.read(browserLibraryProvider).history.single.url.path, '/first');
    expect(firstTab.title, 'Example Domain');
    final workspace = c.read(browserWorkspaceProvider.notifier);
    await workspace.open(_scope, Uri.parse('https://example.com/second'));
    await pumpFrames(tester, 3);
    await c.read(browserLibraryProvider.notifier).clearHistory();
    first.finish(title: 'Changed title after history was cleared');
    pages.last.ping();
    await workspace.activate(firstTab.id);
    await pumpFrames(tester, 3);
    expect(c.read(browserLibraryProvider).history, isEmpty);
    expect(pages.made, hasLength(2));
    first.navigate(Uri.parse('https://example.com/third'));
    first.finish();
    await pumpFrames(tester, 3);
    expect(c.read(browserLibraryProvider).history.single.url.path, '/third');
  });

  testWidgets('renderer failure retires both foreground and background pages and each can reopen', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, url: Uri.parse('https://example.com/first'));
    final first = pages.last;
    final firstTab = _tabs(c).single;
    final workspace = c.read(browserWorkspaceProvider.notifier);
    await workspace.open(_scope, Uri.parse('https://example.com/second'));
    await pumpFrames(tester, 3);
    final second = pages.last;
    first.rendererGone = true;
    first.ping();
    second.rendererGone = true;
    second.ping();
    await pumpFrames(tester, 3);
    expect(first.disposed && second.disposed, isTrue);
    expect(find.text('网页已关闭'), findsOneWidget);
    await tester.tap(find.text('重新打开'));
    await pumpFrames(tester, 3);
    expect(pages.made, hasLength(3));
    await workspace.activate(firstTab.id);
    await pumpFrames(tester, 3);
    expect(find.text('网页已关闭'), findsOneWidget);
    await tester.tap(find.text('重新打开'));
    await pumpFrames(tester, 3);
    expect(pages.made, hasLength(4));
    expect(pages.last.url.path, '/first');
  });

  testWidgets('360 wide at text size 1.3: home, bars, suggestions, menu and tabs fit', (tester) async {
    final pages = FakePages();
    final c = await _pump(tester, pages, narrow: true);
    await c
        .read(browserLibraryProvider.notifier)
        .recordVisit(Uri.parse('https://a-very-long-subdomain.example.com/'), '一个非常非常长的网页标题，在窄屏上也只占一行');
    await pumpFrames(tester, 2);
    expect(tester.takeException(), isNull);
    final close = tester.getRect(find.byKey(const ValueKey('browser-close')));
    final tabs = tester.getRect(find.byKey(const ValueKey('browser-tabs')));
    final box = tester.getRect(find.byKey(const ValueKey('browser-home-search')));
    expect([close.height, tabs.height], [44, 44]);
    expect(box.center.dx, moreOrLessEquals(180, epsilon: 0.5));
    expect(box.height, greaterThanOrEqualTo(52));
    // Close button is in the bottom toolbar, positioned at the bottom right
    final viewHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final bottomInset = tester.view.padding.bottom / tester.view.devicePixelRatio;
    expect(close.bottom, greaterThan(viewHeight - 100)); // Near bottom
    expect(close.bottom, lessThanOrEqualTo(viewHeight - bottomInset)); // Above system inset
    expect(close.right, lessThan(360)); // Within screen width
    // Only one close button exists
    expect(find.byKey(const ValueKey('browser-close')), findsOneWidget);
    expect(360 - tabs.right, 12);
    expect(
      tester.getRect(find.byKey(const ValueKey('browser-toolbar'))).center.dx,
      moreOrLessEquals(180, epsilon: 0.5),
    );

    await tester.tap(find.byKey(const ValueKey('browser-home-search')));
    await pumpFrames(tester, 2);
    await _type(tester, 'a-very', submit: false);
    expect(find.byKey(const ValueKey('browser-suggestions')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _type(tester, 'a-very-long-subdomain.example.com');
    pages.last.finish(title: '一个非常非常长的网页标题，在窄屏上也只占一行');
    await pumpFrames(tester, 2);

    await tester.tap(find.byKey(const ValueKey('browser-more')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(180, 80));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-address')), findsOneWidget, reason: 'a web page has its address');
    await tester.tap(find.byKey(const ValueKey('browser-tabs')));
    await pumpFrames(tester, 6);
    expect(find.byKey(const ValueKey('browser-tabs-overview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp toolbar fits with reduced spacing', (tester) async {
    final pages = FakePages();
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, pages, narrow: true);
    await pumpFrames(tester, 1);
    final toolbar = tester.getRect(find.byKey(const ValueKey('browser-toolbar')));
    // Toolbar should fit within the 320dp width
    expect(toolbar.width, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });
}
