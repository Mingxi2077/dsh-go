import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/browser/browser_site_icons.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

class _Socket implements Socket {
  bool destroyed = false;
  @override
  void destroy() => destroyed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  _Headers(this.location);
  final String? location;
  @override
  String? value(String name) => name == HttpHeaders.locationHeader ? location : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response({this.statusCode = 200, this.contentLength = -1, String? location, Stream<List<int>>? body})
    : headers = _Headers(location),
      body = body ?? Stream.value([1, 2, 3]);
  final Stream<List<int>> body;
  bool listened = false;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers;
  @override
  bool get isRedirect => [301, 302, 303, 307, 308].contains(statusCode);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listened = true;
    return body.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final Future<HttpClientResponse> Function() response;
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;
  @override
  Future<HttpClientResponse> close() {
    expectSync(followRedirects, isFalse);
    expectSync(persistentConnection, isFalse);
    return response();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  final urls = <Uri>[];
  bool closed = false;
  Future<HttpClientResponse> Function(Uri, int) respond = (_, _) async => _Response();
  Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? factory;
  String Function(Uri)? proxy;
  @override
  set connectionFactory(Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value) => factory = value;
  @override
  set findProxy(String Function(Uri)? value) => proxy = value;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  set userAgent(String? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (closed) throw const SocketException('closed');
    expectSync(proxy!(url), 'DIRECT');
    urls.add(url);
    final connection = await factory!(url, null, null);
    await connection.socket;
    if (closed) throw const SocketException('closed');
    return _Request(() => respond(url, urls.length));
  }

  @override
  void close({bool force = false}) {
    expectSync(force, isTrue);
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Network {
  final client = _Client();
  final lookups = <String>[];
  final connections = <({InternetAddress address, int port})>[];
  final tlsHosts = <String>[];
  final sockets = <_Socket>[];
  final publicIp = InternetAddress('8.8.8.8');
  BrowserIconLookup? lookup;
  BrowserIconConnect? connect;
  BrowserIconSecure? secure;

  Future<T> run<T>(Future<T> Function(BrowserIconNetwork) body) => HttpOverrides.runZoned(
    () => body(
      BrowserIconNetwork(
        lookup: (host) async {
          lookups.add(host);
          return lookup == null ? [publicIp] : await lookup!(host);
        },
        connect: (address, port) async {
          connections.add((address: address, port: port));
          if (connect != null) return connect!(address, port);
          final socket = _Socket();
          sockets.add(socket);
          return ConnectionTask.fromSocket(Future<Socket>.value(socket), socket.destroy);
        },
        secure: (socket, host) async {
          tlsHosts.add(host);
          return secure == null ? socket : await secure!(socket, host);
        },
      ),
    ),
    createHttpClient: (_) => client,
  );
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<({int width, int height, Uint8List rgba})> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    return (
      width: image.width,
      height: image.height,
      rgba: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

Uint8List _ico(List<({Uint8List bytes, int width, int height})> frames) {
  final result = Uint8List(6 + frames.length * 16 + frames.fold<int>(0, (n, f) => n + f.bytes.length));
  final data = ByteData.sublistView(result)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, frames.length, Endian.little);
  var offset = 6 + frames.length * 16;
  for (var i = 0; i < frames.length; i++) {
    final frame = frames[i];
    final entry = 6 + i * 16;
    result[entry] = frame.width == 256 ? 0 : frame.width;
    result[entry + 1] = frame.height == 256 ? 0 : frame.height;
    data.setUint32(entry + 8, frame.bytes.length, Endian.little);
    data.setUint32(entry + 12, offset, Endian.little);
    result.setAll(offset, frame.bytes);
    offset += frame.bytes.length;
  }
  return result;
}

// A 2x2 bottom-up DIB with a red left column, green right column and a
// transparent top-right pixel. Uses real palettes, DWORD strides and AND mask.
Uint8List _dib(int bits, {bool alpha = false, bool mask = true}) {
  final colors = bits <= 8 ? 1 << bits : 0;
  final stride = ((2 * bits + 31) ~/ 32) * 4;
  final pixels = 40 + colors * 4;
  final result = Uint8List(pixels + stride * 2 + (mask ? 8 : 0));
  final data = ByteData.sublistView(result)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, 2, Endian.little)
    ..setInt32(8, 4, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, bits, Endian.little);
  if (colors > 0) {
    result[42] = 255;
    result[45] = 255;
  }
  for (var row = 0; row < 2; row++) {
    final start = pixels + row * stride;
    if (bits <= 8) {
      if (bits == 8) {
        result[start + 1] = 1;
      } else {
        result[start] = bits == 1 ? 0x40 : 0x01;
      }
    } else {
      result[start + 2] = 255;
      result[start + bits ~/ 8 + 1] = 255;
      if (bits == 32 && alpha) {
        result[start + 3] = 128;
        result[start + 7] = 255;
      }
    }
  }
  if (mask) result[pixels + stride * 2 + 4] = 0x40;
  // Keep the header writes live so fixture changes are checked by the analyzer.
  expect(data.getUint16(14, Endian.little), bits);
  return result;
}

void main() {
  final page = Uri.parse('https://example.com/private?q=secret#fragment');
  final icon = Uri.parse('https://example.com/favicon.ico');

  group('favicon network', () {
    test('real TLS preserves hostname verification and caps decompressed gzip bytes', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final context = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(_testCertificate))
          ..usePrivateKeyBytes(utf8.encode(_testPrivateKey));
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(_testCertificate));
        final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
        final requests = <HttpRequest>[];
        var oversized = false;
        server.listen(
          (request) {
            requests.add(request);
            final body = gzip.encode(oversized ? Uint8List(BrowserIconNetwork.maxBytes + 1) : [1, 2, 3]);
            request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
            request.response.contentLength = body.length;
            request.response.add(body);
            unawaited(request.response.close().then<void>((_) {}, onError: (Object _) {}));
          },
          onError: (Object error) {
            // Rejected client handshakes never become HTTP requests.
            expectSync(error, isA<HandshakeException>());
          },
        );
        final checked = InternetAddress('8.8.8.8');
        BrowserIconNetwork network({bool trusted = true}) => BrowserIconNetwork(
          lookup: (_) async => [checked],
          connect: (address, port) {
            expectSync(address, same(checked));
            expectSync(port, server.port);
            return Socket.startConnect(InternetAddress.loopbackIPv4, port);
          },
          secure: trusted ? (socket, host) => SecureSocket.secure(socket, host: host, context: trust) : null,
        );
        final target = icon.replace(port: server.port);
        try {
          expect(await network().fetch(target), [1, 2, 3]);
          expect(requests.single.uri.path, '/favicon.ico');
          expect(requests.single.headers.value(HttpHeaders.hostHeader), 'example.com:${server.port}');
          expect(requests.single.headers.value(HttpHeaders.cookieHeader), isNull);
          expect(requests.single.headers.value(HttpHeaders.refererHeader), isNull);
          expect(await network().fetch(target.replace(host: 'wrong.example.com')), isNull);
          expect(await network(trusted: false).fetch(target), isNull);
          expect(requests, hasLength(1));
          oversized = true;
          expect(await network().fetch(target), isNull);
          expect(requests, hasLength(2));
        } finally {
          await server.close(force: true);
        }
      }, _RealHttp());
    });

    test('only the origin favicon is requested; credentials and local URLs are rejected', () {
      expect(BrowserIconNetwork.iconUrl(page), icon);
      expect(
        BrowserIconNetwork.iconUrl(Uri.parse('https://example.com:8443/a?secret')),
        Uri.parse('https://example.com:8443/favicon.ico'),
      );
      for (final raw in [
        'file:///key',
        'https://user:password@example.com',
        'http://127.0.0.1',
        'http://office.local',
      ]) {
        expect(BrowserIconNetwork.iconUrl(Uri.parse(raw)), isNull);
      }
    });

    test('pins TCP to a vetted address and retains the origin host for TLS and HTTP', () async {
      final net = _Network();
      net.lookup = (_) async => [InternetAddress('2606:4700:4700::1111'), net.publicIp];
      await net.run((network) async => expect(await network.fetch(icon), [1, 2, 3]));
      expect(net.lookups, ['example.com']);
      expect(net.connections.single.address, same(net.publicIp));
      expect(net.connections.single.port, 443);
      expect(net.tlsHosts, ['example.com']);
      expect(net.client.urls, [icon]);
      expect(net.client.closed, isTrue);
      expect(net.sockets.every((s) => s.destroyed), isTrue);
    });

    test('rejects empty, mixed-private, mapped, reserved and transition DNS answers before connecting', () async {
      for (final ip in [
        '0.0.0.0',
        '10.0.0.1',
        '127.0.0.1',
        '169.254.169.254',
        '172.16.0.1',
        '192.168.0.1',
        '100.64.0.1',
        '198.18.0.1',
        '224.0.0.1',
        '240.0.0.1',
        '192.0.0.1',
        '192.0.2.1',
        '192.88.99.1',
        '198.51.100.1',
        '203.0.113.1',
        '::1',
        'fc00::1',
        'fe80::1',
        '::ffff:127.0.0.1',
        '::ffff:8.8.8.8',
        '64:ff9b::a00:1',
        '2001::1',
        '2001:db8::1',
        '2002:a00:1::1',
        '3fff::1',
      ]) {
        final net = _Network()..lookup = (_) async => [InternetAddress('8.8.8.8'), InternetAddress(ip)];
        await net.run((network) async => expect(await network.fetch(icon), isNull, reason: ip));
        expect(net.connections, isEmpty, reason: ip);
      }
      final empty = _Network()..lookup = (_) async => [];
      await empty.run((network) async => expect(await network.fetch(icon), isNull));
      expect(empty.connections, isEmpty);
    });

    test('allows public IPv6-only DNS', () async {
      final net = _Network()..lookup = (_) async => [InternetAddress('2606:4700:4700::1111')];
      await net.run((network) async => expect(await network.fetch(icon), isNotNull));
      expect(net.connections.single.address.type, InternetAddressType.IPv6);
    });

    test('every redirect uses a new vetted connection; relative locations resolve correctly', () async {
      final net = _Network();
      net.client.respond = (_, hop) async => switch (hop) {
        1 => _Response(statusCode: 302, location: '/images/icon'),
        2 => _Response(statusCode: 307, location: 'https://cdn.example.org/icon.png'),
        _ => _Response(),
      };
      await net.run((network) async => expect(await network.fetch(icon), [1, 2, 3]));
      expect(net.lookups, ['example.com', 'example.com', 'cdn.example.org']);
      expect(net.tlsHosts, net.lookups);
      expect(net.client.urls[1].path, '/images/icon');
    });

    test('redirect DNS rebinding cannot reach a private address', () async {
      final net = _Network();
      net.lookup = (_) async => [InternetAddress(net.lookups.length == 1 ? '8.8.8.8' : '127.0.0.1')];
      net.client.respond = (_, _) async => _Response(statusCode: 302, location: '/again');
      await net.run((network) async => expect(await network.fetch(icon), isNull));
      expect(net.lookups, hasLength(2));
      expect(net.connections, hasLength(1));
    });

    test('rejects unsafe, missing and malformed redirect locations', () async {
      for (final target in [
        null,
        'http://example.com/icon',
        'https://127.0.0.1/icon',
        'https://user:secret@example.com/icon',
        'file:///secret',
        'https://[broken',
      ]) {
        final net = _Network();
        net.client.respond = (_, _) async => _Response(statusCode: 302, location: target);
        await net.run((network) async => expect(await network.fetch(icon), isNull, reason: '$target'));
        expect(net.connections, hasLength(1));
      }
    });

    test('redirect loops stop after three requests', () async {
      final net = _Network();
      net.client.respond = (_, _) async => _Response(statusCode: 302, location: icon.toString());
      await net.run((network) async => expect(await network.fetch(icon), isNull));
      expect(net.client.urls, hasLength(3));
    });

    test('content-length limit rejects before consuming the response body', () async {
      final net = _Network();
      final response = _Response(contentLength: BrowserIconNetwork.maxBytes + 1);
      net.client.respond = (_, _) async => response;
      await net.run((network) async => expect(await network.fetch(icon), isNull));
      expect(response.listened, isFalse);
    });

    test('streamed/decompressed byte limit cancels the body even with a misleading content-length', () async {
      for (final length in [-1, 1]) {
        var cancelled = false;
        var reachedTail = false;
        Stream<List<int>> chunks() async* {
          try {
            yield Uint8List(BrowserIconNetwork.maxBytes);
            yield [1];
            reachedTail = true;
            yield [2];
          } finally {
            cancelled = true;
          }
        }

        final net = _Network();
        net.client.respond = (_, _) async => _Response(contentLength: length, body: chunks());
        await net.run((network) async => expect(await network.fetch(icon), isNull));
        expect(cancelled, isTrue);
        expect(reachedTail, isFalse);
      }
    });

    test('exact byte limit is accepted; empty, non-200, transport and TLS failures return null', () async {
      final net = _Network();
      net.client.respond = (_, _) async => _Response(body: Stream.value(Uint8List(BrowserIconNetwork.maxBytes)));
      await net.run((network) async => expect((await network.fetch(icon))!.length, BrowserIconNetwork.maxBytes));
      for (final response in [_Response(body: const Stream.empty()), _Response(statusCode: 404)]) {
        final failed = _Network();
        failed.client.respond = (_, _) async => response;
        await failed.run((network) async => expect(await network.fetch(icon), isNull));
      }
      final tls = _Network()..secure = (_, _) async => throw const HandshakeException('certificate rejected');
      await tls.run((network) async => expect(await network.fetch(icon), isNull));
      expect(tls.sockets.single.destroyed, isTrue);
      final dns = _Network()..lookup = (_) async => throw const SocketException('dns failed');
      await dns.run((network) async => expect(await network.fetch(icon), isNull));
    });

    testWidgets('overall timeout cancels a late TCP connection before TLS can start', (tester) async {
      final net = _Network();
      final connection = Completer<ConnectionTask<Socket>>();
      net.connect = (_, _) => connection.future;
      await net.run((network) async {
        final result = network.fetch(icon);
        await tester.pump();
        await tester.pump(const Duration(seconds: 9));
        expect(await result, isNull);
        final socket = _Socket();
        var cancelled = false;
        connection.complete(ConnectionTask.fromSocket(Future<Socket>.value(socket), () => cancelled = true));
        await tester.pump();
        expect(cancelled, isTrue);
        expect(socket.destroyed, isTrue);
        expect(net.tlsHosts, isEmpty);
      });
    });

    testWidgets('DNS timeout cannot create a late connection', (tester) async {
      final answer = Completer<List<InternetAddress>>();
      final net = _Network()..lookup = (_) => answer.future;
      await net.run((network) async {
        final result = network.fetch(icon);
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));
        expect(await result, isNull);
        answer.complete([net.publicIp]);
        await tester.pump();
        expect(net.connections, isEmpty);
      });
    });
  });

  group('favicon decoding', () {
    test('bounds dimensions and keeps PNG aspect ratio without enlarging small images', () async {
      final small = await _decode((await BrowserSiteIcons.normalize(await _png(2, 1)))!);
      expect((small.width, small.height), (2, 1));
      final large = await _decode((await BrowserSiteIcons.normalize(await _png(256, 128)))!);
      expect((large.width, large.height), (96, 48));
      expect(await BrowserSiteIcons.normalize(await _png(2049, 1)), isNull);
      expect(await BrowserSiteIcons.normalize(Uint8List(BrowserIconNetwork.maxBytes + 1)), isNull);
      expect(await BrowserSiteIcons.normalize(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('ICO supports embedded PNG and skips invalid larger entries', () async {
      final bytes = _ico([
        (bytes: Uint8List.fromList([1, 2]), width: 256, height: 256),
        (bytes: await _png(16, 16), width: 16, height: 16),
      ]);
      final decoded = await _decode((await BrowserSiteIcons.normalize(bytes))!);
      expect((decoded.width, decoded.height), (16, 16));
      expect(decoded.rgba.take(4), [255, 0, 0, 255]);
    });

    for (final bits in [1, 4, 8, 24, 32]) {
      test('ICO $bits-bit DIB decodes palette/BGR pixels, bottom-up rows and AND transparency', () async {
        final result = await BrowserSiteIcons.normalize(_ico([(bytes: _dib(bits), width: 2, height: 2)]));
        expect(result, isNotNull);
        final decoded = await _decode(result!);
        expect((decoded.width, decoded.height), (2, 2));
        expect(decoded.rgba.sublist(0, 4), [255, 0, 0, 255]);
        expect(decoded.rgba[7], 0);
        expect(decoded.rgba.sublist(12, 16), [0, 255, 0, 255]);
      });
    }

    test('ICO 32-bit alpha is retained, with or without an AND mask', () async {
      for (final mask in [true, false]) {
        final png = await BrowserSiteIcons.normalize(
          _ico([(bytes: _dib(32, alpha: true, mask: mask), width: 2, height: 2)]),
        );
        final decoded = await _decode(png!);
        expect(decoded.rgba[3], 128);
        expect(decoded.rgba[7], mask ? 0 : 255);
      }
    });

    test('malformed ICO offsets, dimensions, palettes and truncated masks fail safely', () async {
      final valid = _ico([(bytes: _dib(4), width: 2, height: 2)]);
      for (final offset in [8, 18]) {
        final broken = Uint8List.fromList(valid);
        ByteData.sublistView(broken).setUint32(offset, 0xffffffff, Endian.little);
        expect(await BrowserSiteIcons.normalize(broken), isNull);
      }
      final mismatch = _ico([(bytes: await _png(1, 1), width: 2, height: 2)]);
      expect(await BrowserSiteIcons.normalize(mismatch), isNull);
      for (final bytes in [
        _dib(24, mask: false),
        _dib(32, mask: false),
        Uint8List.fromList([0, 0, 1, 0]),
      ]) {
        expect(await BrowserSiteIcons.normalize(_ico([(bytes: bytes, width: 2, height: 2)])), isNull);
      }
      final palette = _dib(4);
      ByteData.sublistView(palette).setUint32(32, 17, Endian.little);
      expect(await BrowserSiteIcons.normalize(_ico([(bytes: palette, width: 2, height: 2)])), isNull);
    });
  });

  group('favicon cache lifetime', () {
    test('native favicon replaces a cached network failure without another request', () async {
      var calls = 0;
      final store = BrowserSiteIcons(
        fetch: (_) async {
          calls++;
          return null;
        },
      );
      addTearDown(store.dispose);
      expect(await store.load(page), isNull);
      expect(await store.remember(page, await _png(128, 64)), isTrue);
      final result = await store.load(page.replace(path: '/other', query: 'private=ignored'));
      final decoded = await _decode(result!);
      expect((decoded.width, decoded.height), (96, 48));
      expect(calls, 1);
    });

    test('a late network failure cannot replace the native favicon', () async {
      final pending = Completer<Uint8List?>();
      final store = BrowserSiteIcons(fetch: (_) => pending.future);
      addTearDown(store.dispose);
      final loading = store.load(page);
      expect(await store.remember(page, await _png(16, 16)), isTrue);
      pending.complete(null);
      expect(await loading, isNull);
      expect(await store.load(page), isNotNull);
    });

    test('navigation and disposal during native decoding do not retain an icon', () async {
      final bytes = await _png(16, 16);
      final store = BrowserSiteIcons(fetch: (_) async => null);
      var current = true;
      final saving = store.remember(page, bytes, isCurrent: () => current);
      current = false;
      expect(await saving, isFalse);
      expect(await store.load(page), isNull);
      final disposing = store.remember(page, bytes);
      store.dispose();
      expect(await disposing, isFalse);
      expect(await store.load(page), isNull);
    });

    test('invalid native images or local origins never replace a usable icon', () async {
      final bytes = await _png(16, 16);
      final store = BrowserSiteIcons(fetch: (_) async => null);
      addTearDown(store.dispose);
      expect(await store.remember(page, bytes), isTrue);
      expect(await store.remember(page, Uint8List.fromList([1, 2, 3])), isFalse);
      expect(await store.remember(Uri.parse('https://127.0.0.1/'), bytes), isFalse);
      expect(await store.remember(page, Uint8List(BrowserIconNetwork.maxBytes + 1)), isFalse);
      expect(await store.load(page), isNotNull);
    });

    test('same-origin requests share work and cache only normalized images', () async {
      final bytes = await _png(16, 16);
      var calls = 0;
      final store = BrowserSiteIcons(
        fetch: (url) async {
          calls++;
          expect(url, icon);
          return bytes;
        },
      );
      addTearDown(store.dispose);
      final first = store.load(page);
      final second = store.load(page.replace(path: '/another', query: 'different'));
      expect(second, same(first));
      expect(await first, isNotNull);
      expect(await store.load(page), isNotNull);
      expect(calls, 1);
    });

    test('limits active work to four and releases queued callers immediately on disposal', () async {
      final pending = <Completer<Uint8List?>>[];
      final store = BrowserSiteIcons(
        fetch: (_) {
          final result = Completer<Uint8List?>();
          pending.add(result);
          return result.future;
        },
      );
      final work = List.generate(12, (i) => store.load(Uri.parse('https://site$i.example.com/')));
      expect(pending, hasLength(4));
      store.dispose();
      expect(await Future.wait(work.skip(4)), everyElement(isNull));
      expect(pending, hasLength(4));
      for (final item in pending) {
        item.complete(null);
      }
      expect(await Future.wait(work.take(4)), everyElement(isNull));
      expect(await store.load(page), isNull);
    });

    test('queue overflow is bounded and late fetch results are discarded on disposal', () async {
      final pending = Completer<Uint8List?>();
      final store = BrowserSiteIcons(fetch: (_) => pending.future);
      final work = List.generate(104, (i) => store.load(Uri.parse('https://site$i.example.com/')));
      expect(await store.load(Uri.parse('https://overflow.example.com/')), isNull);
      store.dispose();
      pending.complete(await _png(1, 1));
      expect(await Future.wait(work), everyElement(isNull));
    });

    test('evicts least-recently-used origins and caches failures', () async {
      final counts = <String, int>{};
      final store = BrowserSiteIcons(
        fetch: (uri) async {
          counts.update(uri.host, (v) => v + 1, ifAbsent: () => 1);
          return null;
        },
      );
      addTearDown(store.dispose);
      for (var i = 0; i < 100; i++) {
        await store.load(Uri.parse('https://site$i.example.com/'));
      }
      await store.load(Uri.parse('https://site0.example.com/'));
      await store.load(Uri.parse('https://site100.example.com/'));
      await store.load(Uri.parse('https://site1.example.com/'));
      expect(counts['site0.example.com'], 1);
      expect(counts['site1.example.com'], 2);
    });
  });
}

// Public test-only self-signed certificate/key for the loopback TLS server.
const _testCertificate = '''
-----BEGIN CERTIFICATE-----
MIIC2TCCAcGgAwIBAgIIKN5Rv8ZNtxUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UE
AxMLZXhhbXBsZS5jb20wHhcNMjAwMTAxMDAwMDAwWhcNNDUwMTAxMDAwMDAwWjAW
MRQwEgYDVQQDEwtleGFtcGxlLmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
AQoCggEBAJGYHF7+05y5rlUFzT/D9Y67HP6Sh0vRpADi44WeaAjtA+BEg5sL9u4h
smlHf5dQN4MCTKW3mv/VAPWqc/gelEfECGp9tHiLs86rbcv7rgoE0stzXTemDXKC
xs3g/e3bFgM2TWR88LX5s576tHYYAKmfSzvvNC9wnqA+mnH3HwnSF2UAHUuT4ieM
z3cJ018qrn2EivtS7o5iZ6JRHU3x3nNis1f6ElRYUyV8LqM1CXNztJFN5+jog0np
hjOAnCrZWLQqoNDnEzF43uruq/OgRpXyJdEbcFHd92NAzWz9gLR/jsNCDpsamEqT
AnXvX2rxBBH9s/cZaBQWkKKjkygfet0CAwEAAaMrMCkwFgYDVR0RBA8wDYILZXhh
bXBsZS5jb20wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAU3JW
HAsIBiesTcCD7ldBIRExZuB4glNOPG18mAvt7OqxzTCiYy0+CyY4Pz10tV/AuYwM
yoraix77amu3US8brDyjrFN/NU+MQkQUFpXzo7ZuncVT3ik7cquJdePYfnazZNGJ
b7GhK8L5w3Vbde0vQs/hi9pNLogZ4C4Imr5fJ/tORsZ1GXk3hpK0KwDh85MP4Fti
XxivfbjR0TVtDBsa1jyXZMz33hlwVfBUrMB9PXUJlpNKz5Bt7Zg7ntwrrNkSGsZ9
ar/ABiDZl30gddZ+pQo16mBzH+3ydU+X2V0yynWoevlbbxv3mZmc00EelVhNkH8c
q9plZf3spAfWnv5zaQ==
-----END CERTIFICATE-----
''';
const _testPrivateKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCRmBxe/tOcua5V
Bc0/w/WOuxz+kodL0aQA4uOFnmgI7QPgRIObC/buIbJpR3+XUDeDAkylt5r/1QD1
qnP4HpRHxAhqfbR4i7POq23L+64KBNLLc103pg1ygsbN4P3t2xYDNk1kfPC1+bOe
+rR2GACpn0s77zQvcJ6gPppx9x8J0hdlAB1Lk+InjM93CdNfKq59hIr7Uu6OYmei
UR1N8d5zYrNX+hJUWFMlfC6jNQlzc7SRTefo6INJ6YYzgJwq2Vi0KqDQ5xMxeN7q
7qvzoEaV8iXRG3BR3fdjQM1s/YC0f47DQg6bGphKkwJ1719q8QQR/bP3GWgUFpCi
o5MoH3rdAgMBAAECggEAYm43CBY51GRIMx0IBUsjMYrY8Fb5901VFnBOJ+DPLvGm
RDGt093D5HyNlNWMsiy+Suj8DrFRrhJAYtYJLz7lOpuSoQQ5RaIVPuzw/w45PHbE
WF23MM8nmjpF05x/sBYFDMjii8RYLH8Ta7DM3mYd1I9oGq3+VvBJncaVPeU3a7hD
o1bhkKs2Ap+ygdLFuMce/wNFqMJA/FvrwNfv6KqLTFwGv7kRxvLPBXgjeZVoDG6y
Zmq6douA7xxTNO0bZOaLtzgbdQ5Oj9fYRi8YBXMJxBMCyR6Z2scY2UrCSi4sLzLM
wS5cD+Vz7bcaLFHsasvW1gyJ6dvmjhEgXgnlAW6MlQKBgQDBMnxY/LWDilff8xxH
gMxwmmrAq4n83U0mpVBNIqYEYMQqc2maZviwHDuKX8YrOLKfW/ytEI7e/dMsUXO3
bbAH2mPMUcBerfJ2BM14F2LW+6M55cl4t92gFY6jPTrAnTv0G9gQRjwWc6aHhUZe
XdIYLz9zMf6u6NVSb9jdTqmClwKBgQDA7DB00CBpl85gsHBiDooEJG9xe4eZD7yR
l0YnoA8BXN/jOD2PFzI5FfUFb+xghvLNZ/KxbbJaNzLl0NScBMRQrEVuSQaGTTAH
qzdn3ppQXfFB4a+tt8B5gZhUHe11T8KaF/db8ucGV6kGNpDn+J0YSJNwcNpDVdbu
9y4YXyzAqwKBgFVcFQzMOvavfTv5khkVkz59O4V9RS5wKNJWYDB0ip2Mk5+d9p69
uEs3bicpQcl+94zpe66LjlSAGXmPU21MDWaq20U/KZurh2EVpiLVUlpiPDAskuO/
eTBt1ePR/c90qTSlyMUIAyx4VK+z9u9izJza41HmWPy26unNeSfuxX5pAoGBAJBT
4ohxb94vQKkbNmhVYjFpJKpsdOwwVq1A064vUyp81c4CNCOJgfwtDgpMSjWIn7rF
ik3suCI/62b8zSIPeuKzjpnMLgJpWoZSM/gUE7QOI8Ba2/gFYQxFxLUhUpWR3w8y
4M48MVOQXxYT2mKAnt4c5ZiYBOGdJVfPOf/nq+5TAoGAWpGBxi2CaPstSmIy+Gxz
3n6yvEcYklRxFjXAWnDF/N9DSUIK2RQ0SqcoEfK8ZH1YqFkbXFeC44P7GRmJ9vjW
/Z2pMOtH6eezBVguJ/wFDouClER1Fl0e1Yf/ZcpNWSJAX72fNTGnr7qzDfKA7wM1
+2nwFS8i88ZlCYJ+6SfI2D0=
-----END PRIVATE KEY-----
''';
