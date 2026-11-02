import 'dart:async';

import 'package:flutter/services.dart';

import '../ui/web/web_view_guard.dart';
import 'browser_page_controller.dart';

/// A native selection-menu action for the visible ordinary browser only.
/// Text is read by the existing, bounded document extractor before Android
/// clears the selection. No JavaScript bridge is installed in the document.
class BrowserSelectionBinding {
  BrowserSelectionBinding({MethodChannel? channel, int? Function(BrowserPageController)? identifier})
    : _channel = channel ?? const MethodChannel('dsh/browser-selection'),
      _identifier = identifier ?? ((page) => WebViewGuard.identifierOf(page.webView));

  final MethodChannel _channel;
  final int? Function(BrowserPageController) _identifier;
  static int _sequence = 0;
  static BrowserSelectionBinding? _owner;
  BrowserPageController? _page;
  Future<void> Function(BrowserPageContent content)? _onQuote;
  String? _token;
  String? _label;
  int? _revision;
  bool _disposed = false;
  bool _busy = false;

  void show({
    required BrowserPageController page,
    required String label,
    required Future<void> Function(BrowserPageContent content) onQuote,
  }) {
    if (_disposed) return;
    if (!page.ready) {
      hide();
      return;
    }
    _onQuote = onQuote;
    if (identical(_owner, this) && identical(_page, page) && _revision == page.revision && _label == label) return;
    int? id;
    try {
      id = _identifier(page);
    } on Object {
      // Unsupported adapters can expose no Android controller at all.
      hide();
      return;
    }
    if (id == null) {
      hide();
      return;
    }
    _owner?.hide();
    _owner = this;
    _page = page;
    _revision = page.revision;
    _label = label;
    final token = _token = '${++_sequence}';
    _channel.setMethodCallHandler(_handle);
    unawaited(_invoke('show', {'id': id, 'token': token, 'label': label, 'url': page.url.toString()}));
  }

  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on Object {
      return null;
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'quote' || _disposed || _busy || !identical(_owner, this)) return false;
    final args = call.arguments;
    final page = _page;
    final token = _token;
    final action = _onQuote;
    if (args is! Map || page == null || token == null || action == null || args['token'] != token) return false;
    final revision = page.revision;
    final url = page.url;
    bool current() =>
        !_disposed &&
        identical(_owner, this) &&
        _token == token &&
        identical(_page, page) &&
        page.ready &&
        page.revision == revision &&
        page.url == url &&
        _revision == revision;
    if (!current() || args['url'] != url.toString()) return false;
    _busy = true;
    try {
      final content = await page.extract(selection: true);
      if (!current() || !content.selection || content.text.trim().isEmpty) return false;
      // Finish while the old registration still owns this native action mode.
      await _invoke('finish', {'token': token});
      if (!current()) return false;
      await action(content);
      return true;
    } on Object {
      return false;
    } finally {
      _busy = false;
    }
  }

  void hide() {
    final token = _token;
    _token = null;
    _page = null;
    _revision = null;
    _label = null;
    if (identical(_owner, this)) {
      _owner = null;
      _channel.setMethodCallHandler(null);
    }
    if (token != null) unawaited(_invoke('hide', {'token': token}));
  }

  void dispose() {
    if (_disposed) return;
    hide();
    _disposed = true;
    _onQuote = null;
  }
}
