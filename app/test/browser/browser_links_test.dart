import 'dart:async';

import 'package:dsh_app/browser/browser_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    BrowserLinks.openPage = null;
    BrowserLinks.openAuthorization = null;
  });

  test('public pages use the internal handler; private and executable links never reach it', () async {
    final opened = <Uri>[];
    BrowserLinks.openPage = (url) async {
      opened.add(url);
      return true;
    };
    for (final raw in ['https://github.com/ccch1mneyyy/dsh-Go', 'https://go.dshtui.com/p/example']) {
      expect(await BrowserLinks.open(Uri.parse(raw)), isTrue);
    }
    for (final raw in [
      'http://127.0.0.1:3080/',
      'http://192.168.1.1/',
      'javascript:alert(1)',
      'file:///secret',
      'intent://open',
    ]) {
      expect(await BrowserLinks.open(Uri.parse(raw)), isFalse);
    }
    expect(opened, hasLength(2));
  });

  test('authorization is separate, immediate, and unavailable after the attempt expires', () async {
    final ended = Completer<void>();
    var current = true;
    var authCalls = 0;
    BrowserLinks.openPage = (_) async => throw StateError('must not save an authorization as an ordinary page');
    BrowserLinks.openAuthorization = (request) async {
      authCalls++;
      expect(request.completed, same(ended.future));
      return true;
    };
    final request = BrowserAuthorization(
      id: Object(),
      url: Uri.parse('https://platform.deepseek.com/dsh/authorize?authorize_id=example'),
      completed: ended.future,
      isCurrent: () => current,
      cancel: () async {},
    );
    expect(await BrowserLinks.authorize(request), isTrue);
    expect(ended.isCompleted, isFalse);
    current = false;
    expect(await BrowserLinks.authorize(request), isFalse);
    expect(authCalls, 1);
    ended.complete();
  });

  test('return notifications omit query and fragment', () async {
    final next = BrowserLinks.pageReturns.first;
    BrowserLinks.didReturn(Uri.parse('https://platform.deepseek.com/top_up?private=value#private'));
    expect(await next, Uri.parse('https://platform.deepseek.com/top_up'));
  });

  test('provider-required system browser reports handoff without cancelling the attempt', () async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final urls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      urls.add((call.arguments as Map)['url'] as String);
      return true;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    BrowserLinks.openAuthorization = (_) async => fail('provider requires a system browser');
    final done = Completer<void>();
    var handoffs = 0;
    var cancellations = 0;
    final request = BrowserAuthorization(
      id: Object(),
      url: Uri.parse('https://example.com/authorize?state=example'),
      completed: done.future,
      isCurrent: () => true,
      preferSystem: true,
      cancel: () async {
        cancellations++;
      },
      onSystemBrowserOpened: () => handoffs++,
    );
    expect(await BrowserLinks.authorize(request), isTrue);
    expect(urls, [request.url.toString()]);
    expect(handoffs, 1);
    expect(cancellations, 0);
    expect(done.isCompleted, isFalse);
    done.complete();
  });
}
