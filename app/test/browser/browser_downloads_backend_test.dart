import 'dart:async';

import 'package:dsh_app/browser/browser_downloads.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Downloads extends BrowserDownloadPlatform {
  final events = StreamController<Object?>.broadcast();
  final calls = <String>[];
  final arguments = <Map<String, Object?>?>[];
  Object snapshot = {'folderId': '', 'folderLabel': 'Download/DSH-Go/Browser', 'items': []};
  Completer<Object?>? gate;
  Uint8List bytes = Uint8List.fromList([1, 2, 3]);
  bool pickResult = false;
  @override
  Stream<Object?> get changes => events.stream;
  @override
  Future<T?> callNative<T>(String method, [Map<String, Object?>? args]) async {
    calls.add(method);
    arguments.add(args);
    final Object? value = switch (method) {
      'snapshot' => await (gate?.future ?? Future.value(snapshot)),
      'readAttachment' => bytes,
      'chooseFolder' => pickResult,
      _ => null,
    };
    return value as T?;
  }
}

Map<String, Object?> _completed({int bytes = 3}) => {
  'items': [
    {
      'id': 'file',
      'filename': 'report.pdf',
      'mime': 'application/pdf',
      'sourceHost': 'example.com',
      'location': 'Download/DSH-Go/Browser/report.pdf',
      'status': 'completed',
      'received': bytes,
      'total': bytes,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Downloads platform;
  late ProviderContainer container;
  late BrowserDownloadsController controller;
  setUp(() {
    platform = _Downloads();
    container = ProviderContainer(overrides: [browserDownloadPlatformProvider.overrideWithValue(platform)]);
    controller = container.read(browserDownloadsProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await platform.events.close();
  });
  test('WebView zero-length offers are unknown until actual transfer completes', () {
    for (final size in [0, -1, 224]) {
      final offer = BrowserDownloadRequest.parse({
        'id': 'offer',
        'url': 'https://example.com/file.json',
        'filename': 'file.json',
        'bytes': size,
        'supported': true,
      });
      expect(offer!.bytes, size > 0 ? size : -1);
    }
  });
  test('loading the list, changing directory, and rejecting never start a transfer', () async {
    await controller.ready;
    expect(await controller.chooseFolder(), isFalse);
    await controller.resetFolder();
    await controller.reject(
      BrowserDownloadRequest(id: 'offer', url: Uri.parse('https://example.com/report'), filename: 'a'),
    );
    expect(platform.calls, isNot(contains('confirm')));
    expect(container.read(browserDownloadsProvider).folder.isDefault, isTrue);
  });
  test('explicit confirmation carries the displayed directory, unsupported targets never reach native start', () async {
    await controller.ready;
    final request = BrowserDownloadRequest(id: 'offer', url: Uri.parse('https://example.com/report'), filename: 'a');
    await controller.confirm(request, folderId: 'content://chosen/tree/one');
    expect(platform.arguments[platform.calls.indexOf('confirm')], {
      'id': 'offer',
      'folderId': 'content://chosen/tree/one',
    });
    final before = platform.calls.length;
    await expectLater(
      controller.confirm(
        BrowserDownloadRequest(id: 'private', url: Uri.parse('http://127.0.0.1/x'), filename: 'a'),
        folderId: '',
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(platform.calls.length, before);
  });
  test('a late list read cannot roll back newer native progress', () async {
    await controller.ready;
    platform.gate = Completer<Object?>();
    final refresh = controller.refresh();
    platform.events.add(_completed());
    await Future<void>.delayed(Duration.zero);
    platform.gate!.complete({'items': []});
    await refresh;
    expect(container.read(browserDownloadsProvider).items.single.status, BrowserDownloadStatus.completed);
  });
  test('attachments are only read from completed items and obey pre-read budget', () async {
    platform.snapshot = _completed();
    await controller.ready;
    await controller.refresh();
    final attachment = await controller.readAttachment('file');
    expect(attachment.name, 'report.pdf');
    expect(attachment.bytes, platform.bytes);
    expect(platform.arguments[platform.calls.indexOf('readAttachment')]!['maxBytes'], maxFileBytes);
    await expectLater(controller.readAttachment('absent'), throwsA(isA<PlatformException>()));
    platform.snapshot = _completed(bytes: maxFileBytes + 1);
    await controller.refresh();
    final before = platform.calls.length;
    await expectLater(controller.readAttachment('file'), throwsA(isA<PlatformException>()));
    expect(platform.calls.length, before);
  });
  test('post-read image size is checked by content rather than extension', () async {
    platform.snapshot = _completed();
    await controller.ready;
    await controller.refresh();
    platform.bytes = Uint8List(maxImageBytes + 1)..setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
    await expectLater(
      controller.readAttachment('file'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'too_large')),
    );
  });
}
