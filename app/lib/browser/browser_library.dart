import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'browser_models.dart';
import 'browser_omnibox.dart';
import 'browser_policy.dart';
import 'browser_workspace.dart' show BrowserStorage;

export 'browser_omnibox.dart' show BrowserSearchEngine;

Uri _canonical(Uri url) => url.path.isEmpty ? url.replace(path: '/') : url;
String _newId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class BrowserBookmark {
  const BrowserBookmark({required this.id, required this.url, required this.title, required this.updatedAt});
  final String id;
  final Uri url;
  final String title;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url.toString(),
    'title': title,
    'at': updatedAt.millisecondsSinceEpoch,
  };
}

class BrowserHistoryEntry {
  const BrowserHistoryEntry({required this.id, required this.url, required this.title, required this.visitedAt});
  final String id;
  final Uri url;
  final String title;
  final DateTime visitedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url.toString(),
    'title': title,
    'at': visitedAt.millisecondsSinceEpoch,
  };
}

class BrowserSuggestion {
  const BrowserSuggestion({required this.url, required this.title, required this.bookmarked});
  final Uri url;
  final String title;
  final bool bookmarked;
}

class BrowserLibraryState {
  const BrowserLibraryState({
    this.loaded = false,
    this.persistenceFailed = false,
    this.engine = BrowserSearchEngine.bing,
    this.textZoom = 100,
    this.bookmarks = const [],
    this.history = const [],
  });
  final bool loaded;
  final bool persistenceFailed;
  final BrowserSearchEngine engine;
  final int textZoom;
  final List<BrowserBookmark> bookmarks;
  final List<BrowserHistoryEntry> history;

  BrowserBookmark? bookmarkFor(Uri url) => bookmarks.where((item) => item.url == _canonical(url)).firstOrNull;

  List<BrowserSuggestion> suggestions(String input, {int limit = 6}) {
    final needle = input.trim().toLowerCase();
    final seen = <Uri>{};
    final result = <BrowserSuggestion>[];
    if (limit <= 0) return result;
    bool matches(Uri url, String title) =>
        needle.isEmpty || title.toLowerCase().contains(needle) || url.toString().toLowerCase().contains(needle);
    for (final item in [
      ...bookmarks.map((b) => BrowserSuggestion(url: b.url, title: b.title, bookmarked: true)),
      ...history.map((h) => BrowserSuggestion(url: h.url, title: h.title, bookmarked: false)),
    ]) {
      if (matches(item.url, item.title) && seen.add(item.url)) result.add(item);
      if (result.length >= limit.clamp(1, 20)) break;
    }
    return List.unmodifiable(result);
  }

  BrowserLibraryState copyWith({
    bool? loaded,
    bool? persistenceFailed,
    BrowserSearchEngine? engine,
    int? textZoom,
    List<BrowserBookmark>? bookmarks,
    List<BrowserHistoryEntry>? history,
  }) => BrowserLibraryState(
    loaded: loaded ?? this.loaded,
    persistenceFailed: persistenceFailed ?? this.persistenceFailed,
    engine: engine ?? this.engine,
    textZoom: textZoom ?? this.textZoom,
    bookmarks: bookmarks == null ? this.bookmarks : List.unmodifiable(bookmarks),
    history: history == null ? this.history : List.unmodifiable(history),
  );
}

class PreferencesBrowserLibraryStorage implements BrowserStorage {
  static const key = 'browser_library_v1';
  @override
  Future<String?> read() async => (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) throw StateError('storage_failed');
  }
}

final browserLibraryStorageProvider = Provider<BrowserStorage>((ref) => PreferencesBrowserLibraryStorage());
final browserLibraryProvider = NotifierProvider<BrowserLibraryController, BrowserLibraryState>(
  BrowserLibraryController.new,
);

/// Local browser data, shared across the device's browser workspaces. This
/// never contains extracted page bodies and never controls a chat destination.
class BrowserLibraryController extends Notifier<BrowserLibraryState> {
  static const maxBookmarks = 200;
  static const maxHistory = 300;
  late Future<void> _ready;
  Future<void> _writes = Future.value();
  Future<void> get ready => _ready;

  @override
  BrowserLibraryState build() {
    final storage = ref.read(browserLibraryStorageProvider);
    _ready = Future<void>.microtask(() => _restore(storage));
    return const BrowserLibraryState();
  }

  Future<void> _restore(BrowserStorage storage) async {
    var restored = const BrowserLibraryState(loaded: true);
    try {
      final raw = await storage.read();
      if (raw != null) {
        if (raw.length > 6000000) throw const FormatException('oversized_library');
        final data = jsonDecode(raw);
        if (data is! Map || data['v'] != 1) throw const FormatException('invalid_library');
        final bookmarks = <BrowserBookmark>[];
        final history = <BrowserHistoryEntry>[];
        final bookmarkIds = <String>{}, historyIds = <String>{};
        final bookmarkUrls = <Uri>{}, historyUrls = <Uri>{};
        for (final raw in (data['bookmarks'] is List ? data['bookmarks'] as List : const []).take(maxBookmarks * 2)) {
          final item = _record(raw);
          if (item == null || !bookmarkIds.add(item.id) || !bookmarkUrls.add(item.url)) continue;
          bookmarks.add(BrowserBookmark(id: item.id, url: item.url, title: item.title, updatedAt: item.at));
          if (bookmarks.length == maxBookmarks) break;
        }
        for (final raw in (data['history'] is List ? data['history'] as List : const []).take(maxHistory * 2)) {
          final item = _record(raw);
          if (item == null) continue;
          final url = _canonical(BrowserOmnibox.restorableUrl(item.url));
          if (!historyIds.add(item.id) || !historyUrls.add(url)) continue;
          history.add(BrowserHistoryEntry(id: item.id, url: url, title: item.title, visitedAt: item.at));
          if (history.length == maxHistory) break;
        }
        bookmarks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        history.sort((a, b) => b.visitedAt.compareTo(a.visitedAt));
        restored = restored.copyWith(
          bookmarks: bookmarks,
          history: history,
          engine: BrowserSearchEngine.values.where((engine) => engine.name == data['engine']).firstOrNull,
          textZoom: data['textZoom'] is int ? (data['textZoom'] as int).clamp(75, 200) : 100,
        );
      }
    } on Object {
      restored = restored.copyWith(persistenceFailed: true);
    }
    if (ref.mounted) state = restored;
  }

  ({String id, Uri url, String title, DateTime at})? _record(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['url'] is! String || raw['at'] is! int) return null;
    try {
      final id = raw['id'] as String;
      final url = Uri.tryParse(raw['url'] as String);
      if (id.isEmpty || id.length > 100 || url == null || !BrowserPolicy.allows(url)) return null;
      final title = cleanBrowserTitle(raw['title'] is String ? raw['title'] as String : '');
      return (
        id: id,
        url: _canonical(url),
        title: title.isEmpty ? url.host : title,
        at: DateTime.fromMillisecondsSinceEpoch(raw['at'] as int),
      );
    } on Object {
      return null;
    }
  }

  Future<void> setEngine(BrowserSearchEngine engine) async {
    await ready;
    if (!ref.mounted) return;
    state = state.copyWith(engine: engine);
    await flush();
  }

  Future<void> setTextZoom(int percent) async {
    await ready;
    if (!ref.mounted) return;
    state = state.copyWith(textZoom: percent.clamp(75, 200));
    await flush();
  }

  Future<BrowserBookmark> saveBookmark(Uri url, {String title = '', String? id}) async {
    if (!BrowserPolicy.allows(url)) throw const FormatException('blocked_url');
    await ready;
    if (!ref.mounted) throw StateError('disposed');
    final canonical = _canonical(url);
    final existing = id == null ? state.bookmarkFor(canonical) : state.bookmarks.where((b) => b.id == id).firstOrNull;
    if (id != null && existing == null) throw StateError('bookmark_missing');
    if (existing == null && state.bookmarks.length >= maxBookmarks) throw StateError('bookmark_limit');
    final cleanedTitle = cleanBrowserTitle(title);
    final saved = BrowserBookmark(
      id: existing?.id ?? _newId(),
      url: canonical,
      title: cleanedTitle.isEmpty ? canonical.host : cleanedTitle,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(bookmarks: [saved, ...state.bookmarks.where((b) => b.id != saved.id && b.url != canonical)]);
    await flush();
    return saved;
  }

  Future<void> removeBookmark(String id) async {
    await ready;
    if (!ref.mounted) return;
    state = state.copyWith(bookmarks: state.bookmarks.where((b) => b.id != id).toList());
    await flush();
  }

  Future<void> recordVisit(Uri url, String title) async {
    if (!BrowserPolicy.allows(url)) return;
    await ready;
    if (!ref.mounted) return;
    final savedUrl = _canonical(BrowserOmnibox.restorableUrl(url));
    final existing = state.history.where((h) => h.url == savedUrl).firstOrNull;
    final cleanedTitle = cleanBrowserTitle(title);
    final visit = BrowserHistoryEntry(
      id: existing?.id ?? _newId(),
      url: savedUrl,
      title: cleanedTitle.isEmpty ? savedUrl.host : cleanedTitle,
      visitedAt: DateTime.now(),
    );
    state = state.copyWith(
      history: [visit, ...state.history.where((h) => h.url != savedUrl)].take(maxHistory).toList(),
    );
    await flush();
  }

  Future<void> removeHistory(String id) async {
    await ready;
    if (!ref.mounted) return;
    state = state.copyWith(history: state.history.where((h) => h.id != id).toList());
    await flush();
  }

  Future<void> clearHistory() async {
    await ready;
    if (!ref.mounted) return;
    state = state.copyWith(history: const []);
    await flush();
  }

  Future<void> flush() async {
    await ready;
    if (!ref.mounted) return;
    final storage = ref.read(browserLibraryStorageProvider);
    final snapshot = jsonEncode({
      'v': 1,
      'engine': state.engine.name,
      'textZoom': state.textZoom,
      'bookmarks': state.bookmarks.map((b) => b.toJson()).toList(),
      'history': state.history.map((h) => h.toJson()).toList(),
    });
    _writes = _writes.then((_) async {
      var failed = false;
      try {
        await storage.write(snapshot);
      } on Object {
        failed = true;
      }
      if (ref.mounted && state.persistenceFailed != failed) state = state.copyWith(persistenceFailed: failed);
    });
    await _writes;
  }
}
