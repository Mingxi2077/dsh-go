import 'package:dsh_app/browser/browser_omnibox.dart';
import 'package:dsh_app/browser/browser_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('malformed UTF-8 search parameters fall back to the public path without breaking persistence', () {
    for (final query in ['q=%FF', 'q=valid&tracking=%C0', '%FF=bad&q=valid']) {
      final url = Uri.parse('https://www.google.com/search?$query#private');
      expect(BrowserPolicy.allows(url), isTrue);
      expect(BrowserOmnibox.restorableUrl(url), Uri.parse('https://www.google.com/search'));
    }
  });

  test('addresses, pasted paths and natural-language queries have distinct destinations', () {
    final address = BrowserOmnibox.resolve(' github.com/ccch1mneyyy/dsh-Go ');
    expect(address!.url, Uri.parse('https://github.com/ccch1mneyyy/dsh-Go'));
    expect(address.isSearch, isFalse);
    expect(
      BrowserOmnibox.resolve('https://example.com/a b?q=hello world')!.url,
      Uri.parse('https://example.com/a%20b?q=hello%20world'),
    );
    expect(BrowserOmnibox.resolve('example.com:8443/docs')!.url, Uri.parse('https://example.com:8443/docs'));
    for (final text in ['怎么安装 Go 插件', 'C++ & Flutter?', 'site:github.com dsh go', '2026', 'flutter']) {
      final result = BrowserOmnibox.resolve(text)!;
      expect(result.isSearch, isTrue, reason: text);
      expect(result.url.host, 'www.bing.com');
      expect(result.url.queryParameters['q'], text);
    }
  });

  test('forbidden or malformed URLs are never sent as search queries', () {
    for (final text in [
      '',
      '   ',
      'javascript:alert(1)',
      'data:text/html,secret',
      'file:///sdcard/private',
      'intent://payload',
      'dshgo://open/settings',
      'custom:secret',
      'ftp://example.com',
      'http://localhost:3080/?token=SECRET',
      'localhost',
      'localhost:3080',
      '127.0.0.1:3080/?token=SECRET',
      '192.168.1.1',
      '[::1]',
      'http://2130706433',
      '0x7f000001',
      '2130706433/private',
      'https://user:secret@example.com',
      'https://example.com:99999999999',
      'https://example.com\\@localhost',
      'https://',
      'https://exa mple.com/',
      'one\ntwo',
      '/sdcard/file',
    ]) {
      expect(BrowserOmnibox.resolve(text), isNull, reason: text);
    }
  });

  test('each selectable engine receives the exact submitted Unicode search once', () {
    const input = '浏览器 C++ & a=b #引用';
    final hosts = {
      'bing': 'www.bing.com',
      'google': 'www.google.com',
      'baidu': 'www.baidu.com',
      'duckduckgo': 'duckduckgo.com',
    };
    for (final engine in BrowserSearchEngine.values) {
      final url = BrowserOmnibox.resolve(input, engine: engine)!.url;
      expect(url.host, hosts[engine.name]);
      expect(url.queryParameters.values.single, input);
      expect(url.hasFragment, isFalse);
      expect(BrowserPolicy.allows(url), isTrue);
    }
  });

  test('restored search pages keep only their search terms; references still remove every parameter', () {
    for (final engine in BrowserSearchEngine.values) {
      final url = engine.search('Go 浏览器');
      final withToken = url.replace(
        queryParameters: {...url.queryParameters, 'access_token': 'SECRET', 'code': 'OAUTH'},
        fragment: 'SECRET',
      );
      expect(BrowserOmnibox.restorableUrl(withToken), url);
      expect(BrowserPolicy.savedUrl(withToken).hasQuery, isFalse);
    }
    for (final text in [
      'https://example.com/search?q=secret&token=secret#secret',
      'https://www.bing.com/login?q=secret&token=secret',
      'https://www.bing.com.evil.com/search?q=secret',
      'http://www.google.com/search?q=secret',
      'https://www.google.com/search?q=one&q=two',
    ]) {
      expect(BrowserOmnibox.restorableUrl(Uri.parse(text)).hasQuery, isFalse, reason: text);
    }
  });
}
