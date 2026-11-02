import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/browser/browser_downloads.dart';
import 'package:dsh_app/browser/browser_return.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:dsh_app/ui/browser/browser_downloads_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'browser_widget_fakes.dart';

class _Downloads extends BrowserDownloadPlatform {
  final calls = <({String method, Map<String, Object?>? args})>[];
  Object snapshot = {'firstDownload': true, 'folderId': '', 'folderLabel': 'Download/DSH-Go/Browser', 'items': []};
  @override
  Stream<Object?> get changes => const Stream.empty();
  @override
  Future<T?> callNative<T>(String method, [Map<String, Object?>? args]) async {
    calls.add((method: method, args: args));
    return (method == 'snapshot'
            ? snapshot
            : method == 'chooseFolder'
            ? false
            : method == 'readAttachment'
            ? Uint8List.fromList([65, 66, 67])
            : null)
        as T?;
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final leaveDownloads in [false, true]) {
    testWidgets('download attaches once; go to chat respects route lifetime ($leaveDownloads)', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final pages = FakePages(finishDuringInitialization: true);
      final platform = _Downloads()
        ..snapshot = {
          'items': [
            {'id': 'file', 'filename': 'notes.txt', 'status': 'completed', 'received': 3},
          ],
        };
      late BuildContext origin;
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) {
              origin = context;
              return const Scaffold(body: Text('owning conversation'));
            },
          ),
          overrides: [...pages.overrides(), browserDownloadPlatformProvider.overrideWithValue(platform)],
        ),
      );
      final container = ProviderScope.containerOf(origin);
      container.read(currentSessionProvider.notifier).select('chat');
      container.read(draftStoreProvider);
      await pumpFrames(tester, 3);
      final key = draftStorageKey(hostKey: 'local:local', sessionId: 'chat');
      container.read(draftStoreProvider.notifier).save(key, 'keep my prompt', []);
      unawaited(
        Navigator.of(origin).push(
          BrowserPage.route(host: HostRef.local, sessionId: 'chat', url: Uri.parse('https://example.com/article')),
        ),
      );
      await pumpFrames(tester, 5);
      await tester.tap(find.byKey(const ValueKey('browser-more')));
      await pumpFrames(tester, 3);
      await tester.tap(find.text('下载管理'));
      await pumpFrames(tester, 5);
      await tester.tap(find.text('加入当前会话'));
      await pumpFrames(tester, 3);
      await tester.tap(find.text('取消'));
      await pumpFrames(tester, 3);
      expect(platform.calls.where((c) => c.method == 'readAttachment'), isEmpty);
      await tester.tap(find.text('加入当前会话'));
      await pumpFrames(tester, 3);
      await tester.tap(find.text('加入草稿'));
      await pumpFrames(tester, 3);
      final draft = container.read(draftStoreProvider).drafts[key]!;
      expect(draft.text, 'keep my prompt');
      expect(draft.attachments.single.name, 'notes.txt');
      expect(draft.attachments.single.bytes, [65, 66, 67]);
      expect(platform.calls.where((c) => c.method == 'readAttachment'), hasLength(1));
      if (leaveDownloads) {
        final action = tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed;
        Navigator.of(tester.element(find.byType(BrowserDownloadsPage))).pop();
        await pumpFrames(tester, 5);
        action();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(find.byType(BrowserDownloadsPage), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        return;
      }
      await tester.tap(find.text('去对话'));
      await pumpFrames(tester, 5);
      expect(find.byType(BrowserDownloadsPage), findsNothing);
      expect(find.byType(BrowserPage), findsNothing);
      expect(find.text('owning conversation'), findsOneWidget);
      expect(container.read(currentSessionProvider), 'chat');
      const scope = BrowserScope(hostKey: 'local:local', sessionId: 'chat');
      expect(
        container.read(browserReturnProvider).itemsFor(scope).single.url.toString(),
        'https://example.com/article',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
  for (final action in ['confirm', 'cancel', 'navigate', 'host']) {
    testWidgets('download offer needs explicit consent and refuses stale $action', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final pages = FakePages(finishDuringInitialization: true);
      final platform = _Downloads();
      await tester.pumpWidget(
        testApp(
          BrowserPage(host: HostRef.local, initialUrl: Uri.parse('https://example.com/article')),
          overrides: [...pages.overrides(), browserDownloadPlatformProvider.overrideWithValue(platform)],
        ),
      );
      await pumpFrames(tester, 5);
      final page = pages.last;
      final container = ProviderScope.containerOf(tester.element(find.byType(BrowserPage)));
      // A public CDN is a legitimate download target, independent of page origin.
      page.onDownloadRequested!(
        BrowserDownloadRequest(id: 'offer', url: Uri.parse('https://cdn.example.org/report.pdf'), filename: '报告.pdf'),
      );
      await pumpFrames(tester, 5);
      expect(find.byKey(const ValueKey('download-start')), findsOneWidget);
      expect(platform.calls.where((c) => c.method == 'confirm'), isEmpty);
      if (action == 'navigate') page.navigate(Uri.parse('https://example.com/another'));
      if (action == 'host') container.read(activeHostProvider.notifier).select(const HostRef.ssh('elsewhere'));
      if (action == 'cancel') {
        await tester.tap(find.text('取消').last);
      } else {
        await tester.tap(find.byKey(const ValueKey('download-start')));
      }
      await pumpFrames(tester, 5);
      final starts = platform.calls.where((c) => c.method == 'confirm').toList();
      if (action == 'confirm') {
        expect(starts, hasLength(1));
        expect(starts.single.args, {'id': 'offer', 'folderId': ''});
      } else {
        expect(starts, isEmpty);
      }
      expect(platform.calls.where((c) => c.method == 'reject'), isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('downloads at 360dp and larger text show folder and actual transfer states without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2100);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _Downloads();
    platform.snapshot = {
      'firstDownload': false,
      'folderId': '',
      'folderLabel': 'Download/DSH-Go/Browser',
      'items': [
        for (final status in ['completed', 'failed', 'downloading'])
          {
            'id': status,
            'filename': '一份有着很长文件名的报告与说明文件.pdf',
            'sourceHost': 'example.com',
            'mime': 'application/pdf',
            'location': 'Download/DSH-Go/Browser/一份有着很长文件名的报告与说明文件.pdf',
            'status': status,
            'received': 24576,
            'total': 49152,
            if (status == 'failed') 'error': 'network',
          },
      ],
    };
    final boundary = GlobalKey();
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: RepaintBoundary(
              key: boundary,
              child: const BrowserDownloadsPage(host: HostRef.local),
            ),
          ),
        ),
        overrides: [browserDownloadPlatformProvider.overrideWithValue(platform)],
      ),
    );
    await pumpFrames(tester, 5);
    expect(find.text('Download/DSH-Go/Browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Optional visual inspection artifact, never a committed golden baseline.
    final output = Platform.environment['DSH_BROWSER_SCREENSHOT_DIR'];
    if (output != null) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(
          pixelRatio: 2,
        );
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File('$output/downloads-360.png').writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
