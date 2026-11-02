import 'dart:math';

import '../browser/browser_models.dart';
import '../browser/browser_policy.dart';

/// A captured passage, stored separately from the person's instructions.
/// It never fetches a URL; previews and sends use this exact local snapshot.
class DraftWebQuote {
  const DraftWebQuote._(this.id, this.content);

  static const limit = 16;
  final String id;
  final BrowserPageContent content;
  Uri get url => content.url;
  String get title => content.title;
  String get text => content.text;
  bool get selection => content.selection;
  bool get truncated => content.truncated;

  factory DraftWebQuote.fromContent(BrowserPageContent content) {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final quote = fromJson({
      'id': id,
      'url': content.url.toString(),
      'title': content.title,
      'text': content.text,
      'selection': content.selection,
      'truncated': content.truncated,
    });
    if (quote == null) throw const FormatException('Invalid web reference');
    return quote;
  }

  static DraftWebQuote? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'], address = value['url'], title = value['title'], text = value['text'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 100 ||
        address is! String ||
        address.length > BrowserPolicy.maxUrlChars ||
        title is! String ||
        text is! String) {
      return null;
    }
    final url = Uri.tryParse(address);
    if (url == null || !BrowserPolicy.allows(url)) return null;
    final cleaned = text.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ').trim();
    if (cleaned.isEmpty) return null;
    return DraftWebQuote._(
      id,
      BrowserPageContent(
        url: BrowserPolicy.savedUrl(url),
        title: cleanBrowserTitle(title),
        text: cleaned.substring(0, min(cleaned.length, BrowserPageContent.maxChars)),
        selection: value['selection'] == true,
        truncated: value['truncated'] == true || cleaned.length > BrowserPageContent.maxChars,
      ),
    );
  }

  static List<DraftWebQuote> readList(Object? value) {
    if (value is! List) return const [];
    final seen = <String>{};
    return List.unmodifiable([
      for (final entry in value.take(limit))
        if (fromJson(entry) case final quote? when seen.add(quote.id)) quote,
    ]);
  }

  Map<String, Object> toJson() => {
    'id': id,
    'url': url.toString(),
    'title': title,
    'text': text,
    'selection': selection,
    'truncated': truncated,
  };
}

/// Only the transport boundary flattens the snapshots. The composer and its
/// persisted draft always keep references out of the editable prompt text.
String withWebQuotes(String prompt, List<DraftWebQuote> quotes, {required bool english}) => [
  if (prompt.isNotEmpty) prompt,
  for (final quote in quotes) quote.content.toQuote(english: english).trimRight(),
].join('\n\n');

/// Local queue metadata, never serialized into an engine request or inferred
/// from arbitrary prompt text. A withdrawal can restore the original composer.
class WebQuoteComposition {
  WebQuoteComposition({required this.text, required List<DraftWebQuote> quotes, this.replyQuote})
    : quotes = List.unmodifiable(quotes);
  final String text;
  final List<DraftWebQuote> quotes;
  final String? replyQuote;
}
