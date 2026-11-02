import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_policy.dart';

typedef BrowserIconLookup = Future<List<InternetAddress>> Function(String host);
typedef BrowserIconConnect = Future<ConnectionTask<Socket>> Function(InternetAddress address, int port);
typedef BrowserIconSecure = Future<Socket> Function(Socket socket, String host);

/// No page path, query, credentials or cookies go to an icon aggregator.
/// Each connection is pinned to a vetted DNS answer, including redirects.
class BrowserIconNetwork {
  BrowserIconNetwork({BrowserIconLookup? lookup, BrowserIconConnect? connect, BrowserIconSecure? secure})
    : _lookup = lookup ?? InternetAddress.lookup,
      _connect = connect ?? Socket.startConnect,
      _secure = secure ?? ((socket, host) => SecureSocket.secure(socket, host: host));
  final BrowserIconLookup _lookup;
  final BrowserIconConnect _connect;
  final BrowserIconSecure _secure;
  static const maxBytes = 256 * 1024;

  static Uri? iconUrl(Uri page) => BrowserPolicy.allows(page)
      ? Uri(scheme: 'https', host: page.host, port: page.hasPort ? page.port : null, path: '/favicon.ico')
      : null;

  Future<InternetAddress> checkedAddress(Uri url) async {
    if (url.scheme != 'https' || !BrowserPolicy.allows(url)) throw const FormatException('blocked_icon');
    final answers = await _lookup(url.host).timeout(const Duration(seconds: 3));
    if (answers.isEmpty || answers.any((a) => !_publicAddress(a))) {
      throw const FormatException('blocked_icon_address');
    }
    return answers.where((a) => a.type == InternetAddressType.IPv4).firstOrNull ?? answers.first;
  }

  static bool _publicAddress(InternetAddress address) {
    if (!BrowserPolicy.allows(Uri(scheme: 'https', host: address.address))) return false;
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      // Special-purpose/documentation/relay ranges are not public icon servers.
      return !(b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) &&
          !(b[0] == 192 && b[1] == 88 && b[2] == 99) &&
          !(b[0] == 198 && b[1] == 51 && b[2] == 100) &&
          !(b[0] == 203 && b[1] == 0 && b[2] == 113);
    }
    // Only global unicast, excluding IETF assignments, documentation and
    // transition mechanisms whose embedded IPv4 address could be private.
    return (b[0] & 0xe0) == 0x20 &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] < 2) &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
        !(b[0] == 0x20 && b[1] == 0x02) &&
        !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
  }

  Future<Uint8List?> fetch(Uri icon) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'DSH-Go Browser Icons';
    var closed = false;
    final cancellations = <void Function()>[];
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      if (proxyHost != null || proxyPort != null) throw const FormatException('unexpected_icon_proxy');
      final address = await checkedAddress(url);
      if (closed) throw const SocketException('icon_request_closed');
      final tcp = await _connect(address, url.port);
      Socket? connected;
      var cancelled = false;
      void cancel() {
        if (cancelled) return;
        cancelled = true;
        tcp.cancel();
        connected?.destroy();
      }

      cancellations.add(cancel);
      final secure = tcp.socket.then((socket) async {
        connected = socket;
        try {
          if (closed || cancelled) throw const SocketException('icon_request_closed');
          // A custom HttpClient connectionFactory must perform TLS itself.
          // Keep the original hostname for SNI and certificate verification;
          // only the TCP connection uses the vetted IP, with no second lookup.
          final tls = connected = await _secure(socket, url.host);
          if (closed || cancelled) throw const SocketException('icon_request_closed');
          return tls;
        } on Object {
          connected?.destroy();
          rethrow;
        }
      });
      if (closed) cancel();
      return ConnectionTask.fromSocket(secure, cancel);
    };
    try {
      return await _fetch(client, icon).timeout(const Duration(seconds: 8));
    } on Object {
      return null;
    } finally {
      closed = true;
      client.close(force: true);
      for (final cancel in cancellations) {
        cancel();
      }
    }
  }

  Future<Uint8List?> _fetch(HttpClient client, Uri url) async {
    for (var hop = 0; hop < 3; hop++) {
      if (url.scheme != 'https' || !BrowserPolicy.allows(url)) return null;
      final request = await client.getUrl(url);
      request.followRedirects = false;
      request.persistentConnection = false;
      final response = await request.close();
      if (response.isRedirect) {
        final next = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (next == null) return null;
        url = url.resolve(next);
        continue;
      }
      if (response.statusCode != HttpStatus.ok || response.contentLength > maxBytes) return null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) return null;
        bytes.add(chunk);
      }
      return bytes.length == 0 ? null : bytes.takeBytes();
    }
    return null;
  }
}

typedef BrowserIconFetch = Future<Uint8List?> Function(Uri icon);

/// Bounded, process-local cache. Failed icons fall back to the site's initials.
class BrowserSiteIcons {
  BrowserSiteIcons({BrowserIconFetch? fetch}) : _fetch = fetch ?? BrowserIconNetwork().fetch;
  final BrowserIconFetch _fetch;
  final _cache = <Uri, Future<Uint8List?>>{};
  final _nativeRequests = <Uri, Object>{};
  final _waiting = Queue<Completer<void>>();
  int _active = 0;
  bool _disposed = false;
  static const maxCached = 100;

  /// Reuse the favicon of a document already loaded by the native WebView.
  /// No extra request or cookie transfer. The caller owns document identity;
  /// recheck it after decoding so navigation cannot seed another page's icon.
  Future<bool> remember(Uri page, Uint8List bytes, {bool Function()? isCurrent}) async {
    final icon = BrowserIconNetwork.iconUrl(page);
    if (_disposed || icon == null || bytes.isEmpty || bytes.length > BrowserIconNetwork.maxBytes) return false;
    if (!(isCurrent?.call() ?? true)) return false;
    if (!_nativeRequests.containsKey(icon) && _nativeRequests.length >= maxCached) return false;
    final operation = Object();
    _nativeRequests[icon] = operation;
    try {
      final png = await normalize(bytes);
      if (_disposed || png == null || !identical(_nativeRequests[icon], operation) || !(isCurrent?.call() ?? true)) {
        return false;
      }
      _cache.remove(icon);
      while (_cache.length >= maxCached) {
        _cache.remove(_cache.keys.first);
      }
      _cache[icon] = Future.value(png);
      return true;
    } finally {
      if (identical(_nativeRequests[icon], operation)) _nativeRequests.remove(icon);
    }
  }

  Future<Uint8List?> load(Uri page) {
    final icon = BrowserIconNetwork.iconUrl(page);
    if (_disposed || icon == null) return Future.value(null);
    final existing = _cache.remove(icon);
    if (existing != null) {
      _cache[icon] = existing;
      return existing;
    }
    // Bound pending work as well as completed images.
    if (_waiting.length >= maxCached) return Future.value(null);
    while (_cache.length >= maxCached) {
      _cache.remove(_cache.keys.first);
    }
    return _cache[icon] = _load(icon);
  }

  Future<Uint8List?> _load(Uri icon) async {
    if (_active >= 4) {
      final wait = Completer<void>();
      _waiting.add(wait);
      await wait.future;
    } else {
      _active++;
    }
    try {
      if (_disposed) return null;
      final bytes = await _fetch(icon);
      if (_disposed || bytes == null || bytes.length > BrowserIconNetwork.maxBytes) return null;
      final png = await normalize(bytes);
      return _disposed ? null : png;
    } on Object {
      return null;
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  /// Inspect dimensions before decoding; retain a tiny, standard PNG only.
  static Future<Uint8List?> normalize(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > BrowserIconNetwork.maxBytes) return null;
    try {
      if (bytes.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1 && bytes[3] == 0) {
        for (final frame in _icoFrames(bytes)) {
          try {
            final png = await _normalizeFrame(frame.bytes, width: frame.width, height: frame.height);
            if (png != null) return png;
          } on Object {
            // A corrupt/unsupported entry must not hide another usable frame.
          }
        }
        return null;
      }
      return await _normalizeFrame(bytes);
    } on Object {
      return null;
    }
  }

  static Future<Uint8List?> _normalizeFrame(Uint8List bytes, {int? width, int? height}) async {
    final dib = width != null && !_isPng(bytes);
    if (dib) bytes = _icoDib(bytes, width, height!);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = dib
          ? ui.ImageDescriptor.raw(buffer, width: width, height: height!, pixelFormat: ui.PixelFormat.rgba8888)
          : await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0 || descriptor.width > 2048 || descriptor.height > 2048) {
        return null;
      }
      if (width != null && (descriptor.width != width || descriptor.height != height)) return null;
      final longest = descriptor.width > descriptor.height ? descriptor.width : descriptor.height;
      final scale = longest > 96 ? 96 / longest : 1.0;
      codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round().clamp(1, 96),
        targetHeight: (descriptor.height * scale).round().clamp(1, 96),
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    _nativeRequests.clear();
    // Release queued callers even when an in-flight fetch has not completed.
    // Each released waiter owns one slot until its finally block runs.
    while (_waiting.isNotEmpty) {
      _active++;
      _waiting.removeFirst().complete();
    }
  }
}

bool _isPng(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 137 &&
    bytes[1] == 80 &&
    bytes[2] == 78 &&
    bytes[3] == 71 &&
    bytes[4] == 13 &&
    bytes[5] == 10 &&
    bytes[6] == 26 &&
    bytes[7] == 10;

List<({Uint8List bytes, int width, int height})> _icoFrames(Uint8List bytes) {
  if (bytes.length < 6) return [];
  final data = ByteData.sublistView(bytes);
  final count = data.getUint16(4, Endian.little);
  if (count == 0 || count > 64 || 6 + count * 16 > bytes.length) return [];
  final frames = <({Uint8List bytes, int width, int height})>[];
  for (var i = 0; i < count; i++) {
    final entry = 6 + i * 16;
    final size = data.getUint32(entry + 8, Endian.little);
    final offset = data.getUint32(entry + 12, Endian.little);
    if (size == 0 || offset < 6 + count * 16 || offset + size > bytes.length || bytes[entry + 3] != 0) continue;
    frames.add((
      bytes: Uint8List.sublistView(bytes, offset, offset + size),
      width: bytes[entry] == 0 ? 256 : bytes[entry],
      height: bytes[entry + 1] == 0 ? 256 : bytes[entry + 1],
    ));
  }
  frames.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
  return frames;
}

/// ICO's uncompressed Windows DIB: indexed 1/4/8-bit, BGR24 or BGRA32,
/// followed by a DWORD-aligned 1-bit transparency mask. Never decode the
/// doubled DIB height as real pixels or allocate from unchecked header sizes.
Uint8List _icoDib(Uint8List bytes, int width, int height) {
  Never invalid() => throw const FormatException('unsupported_icon_dib');
  if (bytes.length < 40) invalid();
  final data = ByteData.sublistView(bytes);
  final header = data.getUint32(0, Endian.little);
  final bits = data.getUint16(14, Endian.little);
  if (![40, 108, 124].contains(header) ||
      header > bytes.length ||
      data.getInt32(4, Endian.little) != width ||
      data.getInt32(8, Endian.little) != height * 2 ||
      data.getUint16(12, Endian.little) != 1 ||
      data.getUint32(16, Endian.little) != 0 ||
      ![1, 4, 8, 24, 32].contains(bits)) {
    invalid();
  }
  final used = data.getUint32(32, Endian.little);
  final colors = bits <= 8 ? (used == 0 ? 1 << bits : used) : 0;
  if ((bits <= 8 && colors > 1 << bits) || (bits > 8 && used != 0)) invalid();
  final pixels = header + colors * 4;
  final stride = ((width * bits + 31) ~/ 32) * 4;
  final mask = pixels + stride * height;
  final maskStride = ((width + 31) ~/ 32) * 4;
  if (mask > bytes.length) invalid();
  final hasMask = mask + maskStride * height <= bytes.length;
  var hasAlpha = false;
  if (bits == 32) {
    for (var y = 0; y < height && !hasAlpha; y++) {
      for (var x = 0; x < width; x++) {
        if (bytes[pixels + y * stride + x * 4 + 3] != 0) {
          hasAlpha = true;
          break;
        }
      }
    }
  }
  if (!hasMask && !hasAlpha) invalid();
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final row = height - y - 1;
    for (var x = 0; x < width; x++) {
      final output = (y * width + x) * 4;
      int color;
      if (bits <= 8) {
        final packed = bytes[pixels + row * stride + (x * bits ~/ 8)];
        final index = (packed >> (8 - bits - (x * bits % 8))) & ((1 << bits) - 1);
        if (index >= colors) invalid();
        color = header + index * 4;
      } else {
        color = pixels + row * stride + x * (bits ~/ 8);
      }
      final transparent = hasMask && (bytes[mask + row * maskStride + x ~/ 8] & (0x80 >> (x % 8))) != 0;
      rgba[output] = bytes[color + 2];
      rgba[output + 1] = bytes[color + 1];
      rgba[output + 2] = bytes[color];
      rgba[output + 3] = transparent ? 0 : (hasAlpha ? bytes[color + 3] : 255);
    }
  }
  return rgba;
}

final browserSiteIconsProvider = Provider<BrowserSiteIcons>((ref) {
  final store = BrowserSiteIcons();
  ref.onDispose(store.dispose);
  return store;
});

final browserSiteIconProvider = FutureProvider.autoDispose.family<Uint8List?, Uri>(
  (ref, url) => ref.watch(browserSiteIconsProvider).load(url),
);
