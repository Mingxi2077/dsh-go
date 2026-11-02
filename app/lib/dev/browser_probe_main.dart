// Device-only backend probe. Build with tooling/build-apk.sh -t this file and
// dshBrowserTestBuild=true in the task's isolated Gradle user properties.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../browser/browser_page_controller.dart';
import '../browser/browser_policy.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Probe()));
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  late final BrowserPageController page;
  String status = 'Running browser backend probe';
  final passed = <String>[];

  @override
  void initState() {
    super.initState();
    page = BrowserPageController(initialUrl: Uri.parse('https://example.com/'), onPageChanged: (_, _) {});
    page.addListener(
      () => debugPrint(
        'BROWSER_PROBE STATE url=${page.url} ready=${page.ready} back=${page.canGoBack} error=${page.error}',
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(run()));
  }

  Future<void> until(bool Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (!predicate()) {
      if (!mounted || DateTime.now().isAfter(deadline)) {
        throw StateError('timeout: url=${page.url}, ready=${page.ready}, back=${page.canGoBack}, error=${page.error}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void check(bool value, String name) {
    if (!value) throw StateError(name);
    passed.add(name);
    debugPrint('BROWSER_PROBE PASS $name');
  }

  Future<void> run() async {
    try {
      await page.initialize(dark: false);
      await until(() => page.ready);
      final initial = await page.extract();
      check(
        initial.text.length > 30 && initial.url == Uri.parse('https://example.com/'),
        'real HTTPS document extraction',
      );
      const fixture =
          '<h1>Fixture</h1><p id="article">Alpha Omega</p><input value="SECRET">'
          '<textarea>SECRET</textarea><div contenteditable>SECRET</div><div hidden>SECRET</div>';
      await page.webView.runJavaScript('document.body.innerHTML = ${jsonEncode(fixture)}');
      final content = await page.extract();
      check(content.text.contains('Alpha Omega') && !content.text.contains('SECRET'), 'native WebView form exclusion');
      await page.webView.runJavaScript('''
        var range = document.createRange();
        range.setStart(document.getElementById('article').firstChild, 6);
        range.setEnd(document.getElementById('article').firstChild, 11);
        getSelection().removeAllRanges(); getSelection().addRange(range);
      ''');
      check((await page.extract(selection: true)).text == 'Omega', 'native WebView partial selection');
      // Chromium intentionally skips script-created history without a user
      // gesture. A real device tap makes this a normal navigable SPA entry.
      await page.webView.runJavaScript('''
        var button = document.createElement('button');
        button.textContent = 'Continue SPA test';
        button.style.cssText = 'position:fixed;left:20px;top:200px;width:300px;height:100px';
        button.onclick = () => { button.remove(); history.pushState({}, '', '/next?token=PROBE#part'); };
        document.body.appendChild(button);
      ''');
      debugPrint('BROWSER_PROBE WAIT_TAP');
      await until(() => page.url.path == '/next' && page.canGoBack);
      final source = await page.extract();
      check(source.url.toString() == 'https://example.com/next', 'SPA source and query redaction');
      await page.back();
      await until(() => page.ready && page.url.path == '/');
      check((await page.extract()).text.contains('Alpha Omega'), 'same-document history back');
      await page.reload();
      check(!page.ready, 'reload retires extraction immediately');
      await until(() => page.ready);
      check((await page.extract()).text == initial.text, 'reload completes with current document');
      check(BrowserPolicy.parseAddress('http://127.0.0.1:3080') == null, 'local engine navigation refused');
      await page.load(Uri.parse('https://github.com/ccch1mneyyy/dsh-Go'));
      await until(() => page.ready);
      check((await page.extract()).text.toLowerCase().contains('dsh'), 'public GitHub project browsing');
      status = 'PASS: ${passed.length} device checks';
      debugPrint('BROWSER_PROBE COMPLETE ${jsonEncode(passed)}');
    } on Object catch (error, stack) {
      status = 'FAILED: $error';
      debugPrint('BROWSER_PROBE FAILED $error\n$stack');
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(status)),
    body: WebViewWidget(controller: page.webView),
  );
}
