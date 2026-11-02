import 'package:dsh_app/browser/browser_downloads.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/browser/browser_downloads_page.dart';
import 'package:dsh_app/ui/common/empty_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

class _Downloads extends BrowserDownloadPlatform {
  Object snapshot = {'firstDownload': false, 'folderId': '', 'folderLabel': 'Download/DSH-Go/Browser', 'items': []};
  @override
  Stream<Object?> get changes => const Stream.empty();
  @override
  Future<T?> callNative<T>(String method, [Map<String, Object?>? args]) async {
    return (method == 'snapshot' ? snapshot : null) as T?;
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('empty state: folder panel full width, empty view centred vertically and horizontally', (tester) async {
    // Real device from screenshot: 1316x2832, 3.5 density = 376x809 dp
    tester.view.physicalSize = const Size(1316, 2832);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final platform = _Downloads();
    await tester.pumpWidget(
      testApp(
        BrowserDownloadsPage(host: HostRef.local),
        overrides: [browserDownloadPlatformProvider.overrideWithValue(platform)],
      ),
    );
    await pumpFrames(tester, 5);

    // Folder panel fills the screen width.
    final folderContainer = find.ancestor(of: find.text('下载文件夹'), matching: find.byType(Container)).first;
    expect(folderContainer, findsOneWidget);
    final containerBox = tester.renderObject<RenderBox>(folderContainer);
    final screenWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(containerBox.size.width, screenWidth, reason: 'Folder panel must fill screen width');

    // EmptyView is centred both horizontally and vertically in the remaining viewport.
    final emptyView = find.byType(EmptyView);
    expect(emptyView, findsOneWidget);
    final emptyBox = tester.renderObject<RenderBox>(emptyView);
    final emptyGlobal = emptyBox.localToGlobal(Offset.zero);

    // Horizontal centre
    final emptyHCentre = emptyGlobal.dx + emptyBox.size.width / 2;
    expect(emptyHCentre, closeTo(screenWidth / 2, 2.0), reason: 'Empty state must be horizontally centred');

    // Vertical centre: the sliver fills the remaining height, EmptyView centres in it.
    final scaffold = tester.renderObject<RenderBox>(find.byType(Scaffold));
    final appBar = tester.renderObject<RenderBox>(find.byType(AppBar));
    final remainingHeight = scaffold.size.height - appBar.size.height - containerBox.size.height;
    final emptyVCentre = emptyGlobal.dy - appBar.size.height - containerBox.size.height + emptyBox.size.height / 2;
    expect(
      emptyVCentre,
      closeTo(remainingHeight / 2, 2.0),
      reason: 'Empty state must be vertically centred in the remaining area',
    );
  });

  testWidgets('narrow viewport with large text and long path: panel scrolls, no overflow', (tester) async {
    // 360x320 dp, 1.3x text scale, long path + the reset button visible.
    tester.view.physicalSize = const Size(1080, 960);
    tester.view.devicePixelRatio = 3.0;
    tester.view.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.platformDispatcher.clearTextScaleFactorTestValue);

    final platform = _Downloads();
    platform.snapshot = {
      'firstDownload': false,
      'folderId': 'custom',
      'folderLabel': 'Download/Documents/Projects/DSH-Go/Browser/Attachments/2026/January',
      'items': [],
    };
    await tester.pumpWidget(
      testApp(
        BrowserDownloadsPage(host: HostRef.local),
        overrides: [browserDownloadPlatformProvider.overrideWithValue(platform)],
      ),
    );
    await pumpFrames(tester, 5);

    // The page builds without overflow.
    expect(tester.takeException(), isNull);

    // Both folder actions exist and the panel wraps them.
    expect(find.text('选择文件夹'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);

    // EmptyView is still present.
    expect(find.byType(EmptyView), findsOneWidget);

    // The page is scrollable (CustomScrollView), so a tall panel can never
    // push the empty state out of reach. Lock onto the CustomScrollView's own
    // Scrollable: SelectableText wraps its content in an inner scrollable and
    // a bare find.byType(Scrollable) would be ambiguous.
    final scrollable = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    expect(scrollable, findsOneWidget);
    expect(tester.widget<Scrollable>(scrollable).physics, isA<AlwaysScrollableScrollPhysics>());

    // The panel really scrolls: the offset moves and the content follows.
    final scrollState = tester.state<ScrollableState>(scrollable);
    final before = scrollState.position.pixels;
    await tester.drag(scrollable, const Offset(0, -100));
    await tester.pump();
    expect(scrollState.position.pixels, greaterThan(before), reason: 'The page must scroll when the panel is tall');

    // After scrolling, the empty state is still reachable and on screen.
    expect(find.byType(EmptyView), findsOneWidget);
    final emptyRect = tester.getRect(find.byType(EmptyView));
    final viewportRect = tester.getRect(find.byType(CustomScrollView));
    expect(emptyRect.overlaps(viewportRect), isTrue, reason: 'Empty state must stay visible after scrolling');
  });

  testWidgets('completed download shows the real file size on the status line', (tester) async {
    tester.view.physicalSize = const Size(1316, 2832);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final platform = _Downloads();
    platform.snapshot = {
      'firstDownload': false,
      'folderId': '',
      'folderLabel': 'Download/DSH-Go/Browser',
      'items': [
        {
          'id': 'test',
          'filename': 'go-download-check.json',
          'sourceHost': 'httpbingo.org',
          'mime': 'application/json',
          'location': 'Download/DSH-Go/Browser/go-download-check.json',
          'status': 'completed',
          'received': 1024,
          'total': 1024,
        },
      ],
    };

    await tester.pumpWidget(
      testApp(
        BrowserDownloadsPage(host: HostRef.local),
        overrides: [browserDownloadPlatformProvider.overrideWithValue(platform)],
      ),
    );
    await pumpFrames(tester, 5);

    // The completed item shows "下载完成 · 1.0 KB" instead of just "下载完成".
    expect(find.textContaining('下载完成'), findsOneWidget);
    expect(find.textContaining('1.0 KB'), findsOneWidget);
  });

  testWidgets('download list fills width and scrolls to the last item', (tester) async {
    tester.view.physicalSize = const Size(1316, 2832);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final platform = _Downloads();
    platform.snapshot = {
      'firstDownload': false,
      'folderId': '',
      'folderLabel': 'Download/DSH-Go/Browser',
      'items': [
        for (var i = 0; i < 10; i++)
          {
            'id': 'item$i',
            'filename': 'file-$i.pdf',
            'sourceHost': 'example.com',
            'mime': 'application/pdf',
            'location': 'Download/DSH-Go/Browser/file-$i.pdf',
            'status': 'completed',
            'received': 2048000 + i * 1000,
            'total': 2048000 + i * 1000,
          },
      ],
    };

    await tester.pumpWidget(
      testApp(
        BrowserDownloadsPage(host: HostRef.local),
        overrides: [browserDownloadPlatformProvider.overrideWithValue(platform)],
      ),
    );
    await pumpFrames(tester, 5);

    // All items build without overflow.
    expect(tester.takeException(), isNull);

    // Cards fill the available width: screen width - 32dp (16dp padding each side).
    final card = find.byType(Card).first;
    final cardBox = tester.renderObject<RenderBox>(card);
    final screenWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(cardBox.size.width, closeTo(screenWidth - 32, 1.0), reason: 'Cards must fill available width');

    // The list is scrollable: the first item is visible, the last is off-screen.
    expect(find.text('file-9.pdf').hitTestable(), findsOneWidget);
    expect(find.text('file-0.pdf'), findsNothing);

    // Scroll to the bottom to reveal the last item.
    final scrollable = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    await tester.dragUntilVisible(find.text('file-0.pdf'), scrollable, const Offset(0, -180));
    expect(find.text('file-0.pdf').hitTestable(), findsOneWidget);
  });
}
