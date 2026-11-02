// Device-only integration probe; never the product entrypoint. Uses public
// example.com documents and process-local tab registration, no account state.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../browser/browser_models.dart';
import '../browser/browser_navigation.dart';
import '../browser/browser_page_controller.dart';
import '../browser/browser_selection.dart';
import '../performance/refresh_rate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  RefreshRateService.instance.start();
  runApp(const MaterialApp(home: _NavigationProbe()));
}

class _NavigationProbe extends StatefulWidget {
  const _NavigationProbe();
  @override
  State<_NavigationProbe> createState() => _NavigationProbeState();
}

class _NavigationProbeState extends State<_NavigationProbe> {
  final owner = Object();
  final selection = BrowserSelectionBinding();
  BrowserPageController? page;
  String status = 'Native navigation probe';
  int passes = 0;
  final first = Uri.parse('https://example.com/');
  final second = Uri.parse('https://example.com/?round5=second');
  final third = Uri.parse('https://example.com/?round5=third');

  @override
  void initState() {
    super.initState();
    BrowserNavigation.instance.synchronize(owner, [
      BrowserTab(
        id: 'device-navigation-probe',
        scope: const BrowserScope(hostKey: 'local:probe'),
        url: first,
        title: '',
        updatedAt: DateTime.now(),
      ),
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(run()));
  }

  void log(String message) => debugPrint('NAVIGATION_PROBE $message');

  void check(bool value, String message) {
    if (!value) throw StateError(message);
    passes++;
    log('PASS $message');
  }

  Future<void> until(bool Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (!condition()) {
      if (!mounted || DateTime.now().isAfter(end)) {
        throw StateError('timeout status=$status ready=${page?.ready} url=${page?.url} error=${page?.error}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<BrowserPageController> create(Uri url) async {
    final next = BrowserPageController(initialUrl: url, onPageChanged: (_, _) {})
      ..configureNavigation('device-navigation-probe');
    setState(() => page = next);
    await next.initialize(dark: false);
    await until(() => next.ready);
    return next;
  }

  Future<BrowserPageController> replace() async {
    final old = page!;
    final url = old.url;
    selection.hide();
    setState(() => page = null);
    await WidgetsBinding.instance.endOfFrame;
    old.dispose();
    return create(url);
  }

  Future<void> navigate(Uri url) async {
    await page!.load(url);
    await until(() => page!.ready && page!.url == url);
  }

  Future<void> run() async {
    try {
      await create(first);
      await navigate(second);
      await navigate(third);
      check(page!.canGoBack, 'A B C have native back history');
      await replace();
      check(page!.url == third && page!.canGoBack, 'recreated controller retains C and back history');
      await page!.back();
      await until(() => page!.ready && page!.url == second);
      check(page!.canGoBack && page!.canGoForward, 'back to B retains both directions');
      await page!.back();
      await until(() => page!.ready && page!.url == first);
      check(!page!.canGoBack && page!.canGoForward, 'back to A reaches native start');
      await replace();
      check(page!.canGoForward, 'recreated at A retains forward branch');
      await page!.forward();
      await until(() => page!.ready && page!.url == second);
      check(page!.canGoBack && page!.canGoForward, 'restored forward arrives at B');
      await page!.webView.runJavaScript('''
        document.body.innerHTML = '<button id="spa" style="position:fixed;top:80px;left:24px;font:24px sans-serif;padding:24px">SPA step 1</button>';
        var step = 0;
        document.getElementById('spa').onclick = () => {
          step++;
          history.pushState({probeStep: step}, '', '#spa-' + step);
          document.getElementById('spa').textContent = 'SPA step ' + (step + 1);
        };
      ''');
      log('WAIT_SPA_TAPS');
      status = 'Tap SPA step 1, then SPA step 2';
      setState(() {});
      await until(() => page!.ready && page!.url.fragment == 'spa-2');
      await replace();
      check(page!.url.fragment == 'spa-2', 'native restore retains SPA current entry');
      await page!.back();
      await until(() => page!.ready && page!.url.fragment == 'spa-1');
      final state = await page!.webView.runJavaScriptReturningResult('JSON.stringify(history.state)');
      check(state.toString().contains('probeStep') && state.toString().contains('1'), 'native restore retains SPA back state');
      await page!.back();
      await until(() => page!.ready && page!.url == second);
      check(page!.canGoForward, 'SPA back returns to original document with forward branch');
      await RefreshRateService.instance.requestActivity();
      log('DISPLAY ${jsonEncode(await RefreshRateService.instance.diagnostics())}');
      status = 'Long press Example Domain, then 引用';
      setState(() {});
      selection.show(
        page: page!,
        label: '引用',
        onQuote: (content) async {
          try {
            check(content.selection && content.text.isNotEmpty, 'native selection reaches bounded extraction');
            log('SELECTION ${jsonEncode(content.text)}');
            status = 'PASS $passes native checks';
            if (mounted) setState(() {});
          } on Object catch (error) {
            log('FAILED $error');
          }
        },
      );
      log('WAIT_SELECTION $passes checks passed');
    } on Object catch (error, stack) {
      status = 'FAILED: $error';
      log('FAILED $error\n$stack');
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    selection.dispose();
    page?.dispose();
    BrowserNavigation.instance.release(owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(status, style: const TextStyle(fontSize: 14))),
    body: page == null ? const SizedBox.expand() : WebViewWidget(key: ObjectKey(page), controller: page!.webView),
  );
}
