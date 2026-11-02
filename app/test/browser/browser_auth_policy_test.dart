import 'dart:async';

import 'package:dsh_app/browser/browser_auth_controller.dart';
import 'package:dsh_app/browser/browser_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final completed = Completer<void>();
  BrowserAuthorization request({
    String? authorize,
    String? origin = 'http://127.0.0.1:3080',
    bool current = true,
    bool forum = false,
  }) => BrowserAuthorization(
    id: Object(),
    url: Uri.parse(authorize ?? 'https://platform.deepseek.com/authorize?authorize_id=engine-owned'),
    callbackOrigin: origin == null ? null : Uri.parse(origin),
    completed: completed.future,
    isCurrent: () => current,
    cancel: () async {},
    onForumRedirect: forum ? (_) async => true : null,
  );
  const callback = 'http://127.0.0.1:3080/oauth/callback';

  test('public HTTPS documents are permitted across identity provider hosts', () {
    for (final url in [
      'https://platform.deepseek.com/authorize',
      'https://accounts.google.com/login',
      'https://8.8.8.8/',
    ]) {
      expect(BrowserAuthPolicy.publicUrl(url), Uri.parse(url));
    }
  });

  for (final raw in [
    'http://example.com/',
    'file:///sdcard/token',
    'content://private/token',
    'javascript:alert(1)',
    'data:text/html,test',
    'intent://example.com/',
    'dshgo://open',
    'mailto:user@example.com',
    'https://user:password@example.com/',
    'https://@example.com/',
    'https://127.0.0.1/',
    'https://10.0.0.1/',
    'https://172.16.0.1/',
    'https://192.168.1.1/',
    'https://169.254.169.254/',
    'https://100.64.0.1/',
    'https://localhost/',
    'https://host.localhost./',
    'https://host.local/',
    'https://host.internal/',
    'https://host.lan/',
    'https://[::1]/',
    'https://[fc00::1]/',
    'https://[::ffff:127.0.0.1]/',
    'https://2130706433/',
    'https://127.1/',
    'https://0x7f000001/',
    'https://0177.0.0.1/',
    'https://example.com:65536/',
    'https://example.com\\@127.0.0.1/',
    'https://example.com/\n',
  ]) {
    test('blocks unsafe public navigation: $raw', () => expect(BrowserAuthPolicy.publicUrl(raw), isNull));
  }

  test('authorize_id does not require client-known state or code', () {
    for (final suffix in ['', '?code=secret', '?code=secret&state=engine-only', '?error=access_denied']) {
      final raw = '$callback$suffix';
      expect(BrowserAuthPolicy.callback(request(), raw, isMainFrame: true), Uri.parse(raw));
    }
  });

  test('an exposed state must match exactly once, after query decoding', () {
    final auth = request(authorize: 'https://example.com/authorize?state=a%2Bb%20c');
    expect(BrowserAuthPolicy.callback(auth, '$callback?state=a%2Bb+c', isMainFrame: true), isNotNull);
    for (final suffix in ['', '?state=other', '?state=', '?state=a%2Bb+c&state=a%2Bb+c', '?state=%FF']) {
      expect(BrowserAuthPolicy.callback(auth, '$callback$suffix', isMainFrame: true), isNull);
    }
    expect(
      BrowserAuthPolicy.callback(
        request(authorize: 'https://example.com/authorize?state=a&state=a'),
        '$callback?state=a',
        isMainFrame: true,
      ),
      isNull,
    );
  });

  test('callback requires the current request and main frame', () {
    expect(BrowserAuthPolicy.callback(request(current: false), callback, isMainFrame: true), isNull);
    expect(BrowserAuthPolicy.callback(request(), callback, isMainFrame: false), isNull);
    expect(BrowserAuthPolicy.publicUrl(callback), isNull);
  });

  for (final raw in [
    'https://127.0.0.1:3080/oauth/callback',
    'http://127.0.0.1:3081/oauth/callback',
    'http://127.0.0.1/oauth/callback',
    'http://localhost:3080/oauth/callback',
    'http://127.0.0.2:3080/oauth/callback',
    'http://[::1]:3080/oauth/callback',
    'http://127.1:3080/oauth/callback',
    'http://2130706433:3080/oauth/callback',
    'http://127.0.0.1.:3080/oauth/callback',
    'http://127.0.0.1:03080/oauth/callback',
    'http://127.0.0.1:0/oauth/callback',
    'http://127.0.0.1:65536/oauth/callback',
    'http://user@127.0.0.1:3080/oauth/callback',
    'http://@127.0.0.1:3080/oauth/callback',
    '$callback#',
    '$callback#fragment',
    '$callback/extra',
    '$callback/',
    'http://127.0.0.1:3080/OAuth/callback',
    'http://127.0.0.1:3080/oauth/%63allback',
    'http://127.0.0.1:3080/other/../oauth/callback',
    '$callback?code=x\n',
    '$callback?code=x\\y',
  ]) {
    test('rejects non-exact callback: $raw', () {
      expect(BrowserAuthPolicy.callback(request(), raw, isMainFrame: true), isNull);
    });
  }

  test('callback origin must itself be a loopback HTTP origin', () {
    for (final origin in [
      null,
      'https://127.0.0.1:3080',
      'http://localhost:3080',
      'http://user@127.0.0.1:3080',
      'http://127.0.0.1:3080/other',
      'http://127.0.0.1:3080?token=private',
      'http://127.0.0.1:3080#',
    ]) {
      expect(BrowserAuthPolicy.callback(request(origin: origin), callback, isMainFrame: true), isNull);
    }
    expect(
      BrowserAuthPolicy.callback(request(origin: 'http://127.0.0.1:3080/'), callback, isMainFrame: true),
      isNotNull,
    );
  });

  test('URL limit is inclusive at 8192 characters for callbacks and documents', () {
    final raw = '$callback?code='.padRight(BrowserAuthPolicy.maxUrlChars, 'a');
    expect(BrowserAuthPolicy.callback(request(), raw, isMainFrame: true), isNotNull);
    expect(BrowserAuthPolicy.callback(request(), '${raw}a', isMainFrame: true), isNull);
    final public = 'https://example.com/?x='.padRight(BrowserAuthPolicy.maxUrlChars, 'a');
    expect(BrowserAuthPolicy.publicUrl(public), isNotNull);
    expect(BrowserAuthPolicy.publicUrl('${public}a'), isNull);
  });

  test('forum callback requires explicit capability, current authorization and main frame', () {
    const raw = 'dshgo://forum/auth?payload=a%2Bb%2F%3D%0A';
    expect(BrowserAuthPolicy.forumCallback(request(forum: true), raw, isMainFrame: true), Uri.parse(raw));
    expect(BrowserAuthPolicy.forumCallback(request(), raw, isMainFrame: true), isNull);
    expect(BrowserAuthPolicy.forumCallback(request(forum: true, current: false), raw, isMainFrame: true), isNull);
    expect(BrowserAuthPolicy.forumCallback(request(forum: true), raw, isMainFrame: false), isNull);
    expect(BrowserAuthPolicy.publicUrl(raw), isNull);
    final limit = 'dshgo://forum/auth?payload='.padRight(8192, 'a');
    expect(BrowserAuthPolicy.forumCallback(request(forum: true), limit, isMainFrame: true), isNotNull);
    expect(BrowserAuthPolicy.forumCallback(request(forum: true), '${limit}a', isMainFrame: true), isNull);
  });

  for (final raw in [
    'DSHGO://forum/auth?payload=a',
    'dshgo://FORUM/auth?payload=a',
    'dshgo://forum/Auth?payload=a',
    'dshgo://forum./auth?payload=a',
    'dshgo://user@forum/auth?payload=a',
    'dshgo://@forum/auth?payload=a',
    'dshgo://forum:0/auth?payload=a',
    'dshgo://forum:80/auth?payload=a',
    'dshgo://forum:/auth?payload=a',
    'dshgo://forum/auth?payload=a#',
    'dshgo://forum/auth?payload=a#fragment',
    'dshgo://forum/auth/?payload=a',
    'dshgo://forum/other/../auth?payload=a',
    'dshgo://forum/%61uth?payload=a',
    'dshgo://%66orum/auth?payload=a',
    'dshgo:///forum/auth?payload=a',
    'dshgo://forum/auth',
    'dshgo://forum/auth?payload=',
    'dshgo://forum/auth?payload=%20%0A',
    'dshgo://forum/auth?payload=a&payload=b',
    'dshgo://forum/auth?payload=a&%70ayload=b',
    'dshgo://forum/auth?%70ayload=a',
    'dshgo://forum/auth?payload=a&other=b',
    'dshgo://forum/auth?payload=%FF',
    'dshgo://forum/auth?payload=%',
    'dshgo://forum/auth?payload=a\n',
    'dshgo://forum/auth?payload=a\\b',
    'https://forum/auth?payload=a',
    'dshgo://open/auth?payload=a',
  ]) {
    test('forum callback rejects non-exact spelling: $raw', () {
      expect(BrowserAuthPolicy.forumCallback(request(forum: true), raw, isMainFrame: true), isNull);
    });
  }
}
