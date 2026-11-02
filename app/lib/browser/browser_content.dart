import 'dart:convert';

import 'browser_models.dart';
import 'browser_policy.dart';

/// Small seam for exercising late navigation and renderer loss without a
/// platform WebView. It is implemented by the browser page controller.
abstract interface class BrowserDocument {
  int get revision;
  bool get ready;
  Future<String?> currentUrl();
  Future<Object> runJavaScriptReturningResult(String script);
}

abstract final class BrowserContentReader {
  static Future<BrowserPageContent> read(BrowserDocument document, {bool selection = false}) =>
      _read(document, selection: selection).timeout(const Duration(seconds: 8));

  static Future<BrowserPageContent> _read(BrowserDocument document, {required bool selection}) async {
    if (!document.ready) throw StateError('page_not_ready');
    final revision = document.revision;
    final before = await document.currentUrl();
    final uri = Uri.tryParse(before ?? '');
    if (uri == null || !BrowserPolicy.allows(uri)) throw StateError('blocked_url');
    void check() {
      if (!document.ready || revision != document.revision) throw StateError('page_changed');
    }

    check();
    final result = await document.runJavaScriptReturningResult(extractionScript(selection: selection));
    check();
    final after = await document.currentUrl();
    check();
    if (after != before) throw StateError('page_changed');
    Object? decoded = result;
    // Android returns JSON text; some platform adapters return a JSON-quoted
    // string. Neither representation is allowed to bypass the payload limit.
    for (var i = 0; i < 2 && decoded is String; i++) {
      if (decoded.length > BrowserPageContent.maxChars * 8 + BrowserPolicy.maxUrlChars * 2) {
        throw StateError('content_too_large');
      }
      decoded = jsonDecode(decoded);
    }
    if (decoded is! Map || decoded['url'] != before || decoded['text'] is! String || decoded['title'] is! String) {
      throw StateError('page_changed');
    }
    var text = (decoded['text'] as String)
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ')
        .trim();
    if (text.isEmpty) throw StateError(selection ? 'empty_selection' : 'empty_page');
    final truncated = decoded['truncated'] == true || text.length > BrowserPageContent.maxChars;
    if (text.length > BrowserPageContent.maxChars) text = text.substring(0, BrowserPageContent.maxChars);
    return BrowserPageContent(
      url: BrowserPolicy.savedUrl(uri),
      title: cleanBrowserTitle(decoded['title'] as String),
      text: text,
      selection: selection,
      truncated: truncated,
    );
  }

  /// Reads visible text only, without form values, cookies, storage or network
  /// access. Bounded DOM traversal also avoids running over huge documents.
  static String extractionScript({bool selection = false}) =>
      '''
(() => {
  const selectedOnly = ${selection ? 'true' : 'false'};
  const limit = ${BrowserPageContent.maxChars};
  const skip = 'script,style,noscript,template,input,textarea,select,button,iframe,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"]';
  const selection = selectedOnly ? window.getSelection() : null;
  const range = selection && selection.rangeCount ? selection.getRangeAt(0) : null;
  const parts = [];
  let length = 0, visited = 0, truncated = false;
  const root = document.body;
  const budgetExceeded = {};
  function excluded(node) {
    if (node.matches(skip) || node.isContentEditable) return true;
    const style = window.getComputedStyle(node);
    return style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0' || style.contentVisibility === 'hidden';
  }
  let rootExcluded = !root;
  for (let ancestor = root; ancestor; ancestor = ancestor.parentElement) {
    if (excluded(ancestor)) { rootExcluded = true; break; }
  }
  if (!rootExcluded && (!selectedOnly || (range && !range.collapsed))) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (++visited > 12000) { truncated = true; throw budgetExceeded; }
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (excluded(node)) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_SKIP;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    let node;
    try {
    while ((node = walker.nextNode())) {
      if (selectedOnly && !range.intersectsNode(node)) continue;
      let text = node.textContent || '';
      if (selectedOnly) {
        const end = node === range.endContainer ? range.endOffset : text.length;
        const start = node === range.startContainer ? range.startOffset : 0;
        text = text.slice(start, end);
      }
      text = text.replace(/\\s+/g, ' ').trim();
      if (!text) continue;
      const available = limit - length;
      if (text.length > available) { text = text.slice(0, available); truncated = true; }
      parts.push(text);
      length += text.length + 1;
      if (length >= limit) { truncated = true; break; }
    }
    } catch (error) {
      if (error !== budgetExceeded) throw error;
    }
  }
  return JSON.stringify({url: location.href, title: document.title.slice(0, 200), text: parts.join('\\n').slice(0, limit), truncated});
})()
''';
}
