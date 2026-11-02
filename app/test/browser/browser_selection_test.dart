import 'dart:async';

import 'package:dsh_app/browser/browser_page_controller.dart';
import 'package:dsh_app/browser/browser_selection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Page implements BrowserPageController {
  @override
  Uri url = Uri.parse('https://example.com/article');
  @override
  int revision = 1;
  @override
  bool ready = true;
  Completer<BrowserPageContent>? pending;
  int reads = 0;
  @override
  Future<BrowserPageContent> extract({bool selection = false}) async {
    expect(selection, isTrue);
    reads++;
    return pending?.future ??
        BrowserPageContent(url: url, title: 'Article', text: 'Selected words', selection: true, truncated: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/browser-selection');
  const codec = StandardMethodCodec();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late BrowserSelectionBinding binding;
  late _Page page;
  late List<BrowserPageContent> quoted;
  Future<Object?> quote({String? token, String? url}) async {
    final show = calls.lastWhere((c) => c.method == 'show');
    final result = Completer<Object?>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall('quote', {'token': token ?? (show.arguments as Map)['token'], 'url': url ?? page.url.toString()}),
      ),
      (data) => result.complete(data == null ? null : codec.decodeEnvelope(data)),
    );
    return result.future;
  }

  void show() => binding.show(
    page: page,
    label: '引用',
    onQuote: (content) async {
      quoted.add(content);
    },
  );
  setUp(() {
    calls.clear();
    quoted = [];
    page = _Page();
    binding = BrowserSelectionBinding(channel: channel, identifier: (_) => 7);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() {
    binding.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('selection is read before native finish and handed to preview only once', () async {
    show();
    await Future<void>.delayed(Duration.zero);
    expect(await quote(), isTrue);
    expect(page.reads, 1);
    expect(quoted.single.text, 'Selected words');
    expect(calls.map((c) => c.method), ['show', 'finish']);
    show();
    expect(calls.where((c) => c.method == 'show'), hasLength(1));
  });

  test('foreign token or another document cannot extract anything', () async {
    show();
    await Future<void>.delayed(Duration.zero);
    expect(await quote(token: 'old'), isFalse);
    expect(await quote(url: 'https://example.com/other'), isFalse);
    expect(page.reads, 0);
  });

  test('unavailable native controller leaves selection actions unregistered', () {
    binding.dispose();
    binding = BrowserSelectionBinding(channel: channel, identifier: (_) => throw UnsupportedError('no_native_view'));
    expect(show, returnsNormally);
    expect(calls.where((call) => call.method == 'show'), isEmpty);
  });

  test('navigation during extraction discards selection; never falls back to full page', () async {
    show();
    await Future<void>.delayed(Duration.zero);
    page.pending = Completer();
    final result = quote();
    await Future<void>.delayed(Duration.zero);
    page.revision++;
    page.pending!.complete(
      BrowserPageContent(url: page.url, title: '', text: 'old', selection: true, truncated: false),
    );
    expect(await result, isFalse);
    expect(quoted, isEmpty);
    expect(page.reads, 1);
  });

  test('hidden or replaced binding cannot show a late quote', () async {
    show();
    await Future<void>.delayed(Duration.zero);
    page.pending = Completer();
    final result = quote();
    await Future<void>.delayed(Duration.zero);
    binding.hide();
    page.pending!.complete(
      BrowserPageContent(url: page.url, title: '', text: 'old', selection: true, truncated: false),
    );
    expect(await result, isFalse);
    expect(quoted, isEmpty);
  });
}
