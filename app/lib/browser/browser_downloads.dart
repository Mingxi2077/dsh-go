import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/attachments.dart';
import 'browser_policy.dart';

class BrowserDownloadRequest {
  const BrowserDownloadRequest({
    required this.id,
    required this.url,
    required this.filename,
    this.mime = 'application/octet-stream',
    this.bytes = -1,
    this.supported = true,
  });
  final String id, filename, mime;
  final Uri url;
  final int bytes;
  final bool supported;
  static BrowserDownloadRequest? parse(Object? value) {
    if (value is! Map || value['id'] is! String || value['filename'] is! String) return null;
    final url = Uri.tryParse(value['url'] is String ? value['url'] as String : '');
    if (url == null) return null;
    return BrowserDownloadRequest(
      id: value['id'],
      url: url,
      filename: value['filename'],
      mime: value['mime'] is String ? value['mime'] : 'application/octet-stream',
      // Android WebView also reports zero when the response length is unknown.
      // Only the transfer can establish an empty file; don't promise "0 B" here.
      bytes: value['bytes'] is int && value['bytes'] > 0 ? value['bytes'] : -1,
      supported: value['supported'] == true && BrowserPolicy.allows(url),
    );
  }
}

class BrowserDownloadFolder {
  const BrowserDownloadFolder({this.id = '', this.label = 'Download/DSH-Go/Browser'});
  final String id, label;
  bool get isDefault => id.isEmpty;
}

enum BrowserDownloadStatus { queued, downloading, completed, failed, cancelled }

class BrowserDownloadItem {
  const BrowserDownloadItem({
    required this.id,
    required this.filename,
    required this.mime,
    required this.sourceHost,
    required this.location,
    required this.status,
    this.received = 0,
    this.total = -1,
    this.error,
  });
  final String id, filename, mime, sourceHost, location;
  final int received, total;
  final BrowserDownloadStatus status;
  final String? error;
  bool get active => status == BrowserDownloadStatus.queued || status == BrowserDownloadStatus.downloading;
  static BrowserDownloadItem? parse(Object? value) {
    if (value is! Map || value['id'] is! String || value['filename'] is! String) return null;
    return BrowserDownloadItem(
      id: value['id'],
      filename: value['filename'],
      mime: value['mime'] as String? ?? '',
      sourceHost: value['sourceHost'] as String? ?? '',
      location: value['location'] as String? ?? '',
      status:
          BrowserDownloadStatus.values.where((v) => v.name == value['status']).firstOrNull ??
          BrowserDownloadStatus.failed,
      received: value['received'] as int? ?? 0,
      total: value['total'] as int? ?? -1,
      error: value['error'] as String?,
    );
  }
}

class BrowserDownloadsState {
  const BrowserDownloadsState({
    this.loaded = false,
    this.firstDownload = true,
    this.folder = const BrowserDownloadFolder(),
    this.items = const [],
    this.error,
  });
  final bool loaded, firstDownload;
  final BrowserDownloadFolder folder;
  final List<BrowserDownloadItem> items;
  final String? error;
  static BrowserDownloadsState parse(Object? value) {
    if (value is! Map) throw PlatformException(code: 'unsupported');
    return BrowserDownloadsState(
      loaded: true,
      firstDownload: value['firstDownload'] != false,
      folder: BrowserDownloadFolder(
        id: value['folderId'] as String? ?? '',
        label: value['folderLabel'] as String? ?? 'Download/DSH-Go/Browser',
      ),
      items: List.unmodifiable([
        for (final v in (value['items'] as List? ?? const []).reversed) ?BrowserDownloadItem.parse(v),
      ]),
    );
  }
}

/// One native channel. Download offers carry no Cookie/header/authorization data.
class BrowserDownloadPlatform {
  BrowserDownloadPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/browser-downloads');
  static BrowserDownloadPlatform instance = BrowserDownloadPlatform();
  final MethodChannel _channel;
  final _offers = <int, void Function(BrowserDownloadRequest)>{};
  final _changes = StreamController<Object?>.broadcast();
  bool _listening = false;
  Stream<Object?> get changes {
    _listen();
    return _changes.stream;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') _changes.add(call.arguments);
      if (call.method == 'offer' && call.arguments is Map) {
        final args = call.arguments as Map;
        final request = BrowserDownloadRequest.parse(args);
        if (request != null) {
          final listener = _offers[args['viewId']];
          if (listener != null) {
            listener(request);
          } else {
            unawaited(callNative<void>('reject', {'id': request.id}).catchError((Object _) {}));
          }
        }
      }
    });
  }

  Future<T?> callNative<T>(String method, [Map<String, Object?>? args]) async {
    _listen();
    return _channel.invokeMethod<T>(method, args);
  }

  Future<void> attach(int id, void Function(BrowserDownloadRequest) listener) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _offers[id] = listener;
    try {
      await callNative<void>('attach', {'viewId': id});
    } on Object {
      _offers.remove(id);
    }
  }

  Future<void> detach(int id) async {
    if (_offers.remove(id) == null) return;
    try {
      await callNative<void>('detach', {'viewId': id});
    } on Object {
      /* renderer may be gone */
    }
  }
}

final browserDownloadPlatformProvider = Provider<BrowserDownloadPlatform>((ref) => BrowserDownloadPlatform.instance);
final browserDownloadsProvider = NotifierProvider<BrowserDownloadsController, BrowserDownloadsState>(
  BrowserDownloadsController.new,
);

class BrowserDownloadsController extends Notifier<BrowserDownloadsState> {
  late Future<void> ready;
  bool _alive = true;
  int _generation = 0;
  BrowserDownloadPlatform get _platform => ref.read(browserDownloadPlatformProvider);
  @override
  BrowserDownloadsState build() {
    _alive = true;
    final subscription = _platform.changes.listen((snapshot) {
      _generation++;
      if (_alive) state = BrowserDownloadsState.parse(snapshot);
    });
    ref.onDispose(() {
      _alive = false;
      unawaited(subscription.cancel());
    });
    ready = Future.microtask(refresh);
    return const BrowserDownloadsState();
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    try {
      final value = await _platform.callNative<Object>('snapshot');
      if (_alive && generation == _generation) state = BrowserDownloadsState.parse(value);
    } on Object {
      if (_alive && generation == _generation) {
        state = BrowserDownloadsState(
          loaded: true,
          firstDownload: state.firstDownload,
          folder: state.folder,
          items: state.items,
          error: 'unsupported',
        );
      }
    }
  }

  Future<bool> chooseFolder() async {
    final changed = await _platform.callNative<bool>('chooseFolder') ?? false;
    await refresh();
    return changed;
  }

  Future<void> resetFolder() async {
    await _platform.callNative<void>('resetFolder');
    await refresh();
  }

  Future<void> confirm(BrowserDownloadRequest request, {required String folderId}) async {
    if (!request.supported || !BrowserPolicy.allows(request.url)) throw PlatformException(code: 'unsupported');
    await _platform.callNative<void>('confirm', {'id': request.id, 'folderId': folderId});
    await refresh();
  }

  Future<void> reject(BrowserDownloadRequest request) async {
    try {
      await _platform.callNative<void>('reject', {'id': request.id});
    } on Object {
      /* offer expires */
    }
  }

  Future<void> cancel(String id) async {
    await _platform.callNative<void>('cancel', {'id': id});
    await refresh();
  }

  Future<void> open(String id) async {
    await _platform.callNative<void>('open', {'id': id});
  }

  Future<DraftAttachment> readAttachment(String id) async {
    final record = state.items.where((item) => item.id == id).firstOrNull;
    if (record == null || record.status != BrowserDownloadStatus.completed) {
      throw PlatformException(code: 'missing');
    }
    if (record.received > maxFileBytes) throw PlatformException(code: 'too_large');
    final bytes = await _platform.callNative<Uint8List>('readAttachment', {'id': id, 'maxBytes': maxFileBytes});
    if (bytes == null || bytes.isEmpty) throw PlatformException(code: 'missing');
    final result = DraftAttachment.sniff(record.filename, bytes);
    if (attachmentProblem(result) != null) throw PlatformException(code: 'too_large');
    return result;
  }
}
