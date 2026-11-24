import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachments.dart';
import 'web_quote.dart';

/// Storage identity shared by composer drafts and quotes. [hostKey] is the
/// stable `${host.kind.name}:${host.id}`; null [sessionId] means a new chat.
/// Capture the key with its owner, rather than reading the active host when an
/// asynchronous operation completes. A literal session id `new` is distinct.
String draftStorageKey({required String hostKey, required String? sessionId}) => jsonEncode([2, hostKey, sessionId]);

/// What is in the composer of one conversation and not sent yet.
class ChatDraft {
  const ChatDraft({this.text = '', this.attachments = const [], this.webQuotes = const [], required this.updatedAt});

  final String text;
  final List<DraftAttachment> attachments;
  final List<DraftWebQuote> webQuotes;
  final DateTime updatedAt;
}

class DraftState {
  const DraftState({this.drafts = const {}, this.legacyDrafts = const {}, this.loaded = false});

  /// By [draftStorageKey], including the host and nullable session id.
  final Map<String, ChatDraft> drafts;

  /// Unscoped records, keyed by their original session id / `new`. Their host is
  /// unknown: show only for manual recovery, never as a current draft fallback.
  final Map<String, ChatDraft> legacyDrafts;

  /// The saved texts are in (they arrive a moment after launch).
  final bool loaded;
}

/// Composer drafts per host/conversation. Callers pass [draftStorageKey] to
/// save, clear and forget. The text of the latest 30 survives a restart;
/// attachments only live as long as the app.
///
/// Unscoped `chat_drafts_v1` and earlier `chat_drafts_v2` records remain
/// available for manual recovery; they are never current-draft fallbacks.
class DraftStore extends Notifier<DraftState> {
  static const preferenceKey = 'chat_drafts_v2';
  static const legacyPreferenceKey = 'chat_drafts_v1';
  static const limit = 30;

  Timer? _write;
  final _forgotten = <String>{};
  final _editedBeforeRestore = <String>{};
  late Future<void> _restored;
  Future<void> _writes = Future.value();

  @override
  DraftState build() {
    ref.onDispose(() => _write?.cancel());
    _restored = _restore();
    return const DraftState();
  }

  Future<void> _restore() async {
    var restored = const <String, ChatDraft>{};
    var legacy = const <String, ChatDraft>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      // Parse independently: corruption in either version cannot hide the other.
      final saved = _readSaved(prefs, preferenceKey);
      restored = Map.fromEntries(saved.entries.where((entry) => _isScopedKey(entry.key)));
      legacy = _readSaved(prefs, legacyPreferenceKey);
      for (final entry in saved.entries.where((entry) => !_isScopedKey(entry.key))) {
        final previous = legacy[entry.key];
        if (previous == null || previous.updatedAt.isBefore(entry.value.updatedAt)) {
          legacy[entry.key] = entry.value;
        }
      }
    } catch (_) {
      // No preferences backend (tests) or an unreadable value: start empty.
    }
    if (!ref.mounted) return;
    // Deleting a draft is an edit too. Absence from state.drafts alone cannot
    // distinguish a cleared slot from one that has not been restored yet.
    final untouched = {...restored}..removeWhere((key, _) => _editedBeforeRestore.contains(key));
    _editedBeforeRestore.clear();
    state = DraftState(
      drafts: _latest({...untouched, ...state.drafts}..removeWhere((key, _) => _forgotten.contains(key))),
      legacyDrafts: Map.unmodifiable(legacy),
      loaded: true,
    );
  }

  Map<String, ChatDraft> _readSaved(SharedPreferences prefs, String preference) {
    final restored = <String, ChatDraft>{};
    try {
      final raw = prefs.getString(preference);
      if (raw == null) return restored;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return restored;
      for (final MapEntry(:key, :value) in decoded.entries) {
        if (key is! String || value is! Map || value['t'] is! String || value['at'] is! int) continue;
        try {
          final text = _textWithoutPastedImageBytes(value['t'] as String);
          final webQuotes = DraftWebQuote.readList(value['webQuotes']);
          if (text.isEmpty && webQuotes.isEmpty) continue;
          restored[key] = ChatDraft(
            text: text,
            webQuotes: webQuotes,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(value['at'] as int),
          );
        } on Object {
          // A damaged record must not hide other recoverable drafts.
        }
      }
    } on Object {
      // Keep the original preference intact even if it cannot be decoded.
    }
    return restored;
  }

  String _textWithoutPastedImageBytes(String text) {
    final jpeg = text.indexOf('\ufffd\ufffd\ufffd\ufffd\x00\x10JFIF');
    final png = text.indexOf('\ufffdPNG\r\n\x1a\n');
    final starts = [jpeg, png].where((index) => index >= 0).toList();
    if (starts.isEmpty) return text;
    starts.sort();
    return text.substring(0, starts.first).trimRight();
  }

  Map<String, ChatDraft> _latest(Map<String, ChatDraft> drafts) {
    final entries = drafts.entries.toList()..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return Map.unmodifiable(Map.fromEntries(entries.take(limit)));
  }

  /// [key] is a [draftStorageKey]. Empty text and no attachments drops the slot.
  void save(String key, String text, List<DraftAttachment> attachments, {List<DraftWebQuote>? webQuotes}) {
    if (_forgotten.contains(key)) return;
    final current = state.drafts[key];
    // Older text/attachment-only callers must not erase independent references.
    final references = webQuotes ?? current?.webQuotes ?? const <DraftWebQuote>[];
    if ((current?.text ?? '') == text &&
        listEquals(current?.attachments ?? const [], attachments) &&
        listEquals(current?.webQuotes ?? const [], references)) {
      return;
    }
    if (!state.loaded) _editedBeforeRestore.add(key);
    final next = {...state.drafts};
    if (text.isEmpty && attachments.isEmpty && references.isEmpty) {
      next.remove(key);
    } else {
      next[key] = ChatDraft(
        text: text,
        attachments: List.unmodifiable(attachments),
        webQuotes: List.unmodifiable(references),
        updatedAt: DateTime.now(),
      );
    }
    state = DraftState(drafts: _latest(next), legacyDrafts: state.legacyDrafts, loaded: state.loaded);
    _scheduleWrite();
  }

  void _scheduleWrite() {
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  void clear(String key) {
    if (_forgotten.contains(key)) return;
    if (!state.loaded) {
      _editedBeforeRestore.add(key);
      _scheduleWrite();
    }
    save(key, '', const [], webQuotes: const []);
  }

  /// After the user previews and confirms [expectedText], append it to [targetKey]
  /// (a [draftStorageKey] captured with the destination). Callers must recheck that
  /// their displayed host/draft still owns that key after any confirmation await.
  /// This method is synchronous: it appends to the latest text, preserves target
  /// attachments and schedules the usual v2 save without a host-switch await gap.
  ///
  /// False means not loaded, missing/empty or changed preview, invalid destination
  /// or a deleted session. No writes happen on failure. Legacy records remain
  /// intact on success; another confirmed call deliberately appends again.
  bool importLegacy({
    required String legacyKey,
    required String expectedText,
    required String targetKey,
    List<DraftWebQuote> expectedWebQuotes = const [],
  }) {
    if (!state.loaded || _forgotten.contains(targetKey) || !_isScopedKey(targetKey)) return false;
    final legacy = state.legacyDrafts[legacyKey];
    if (legacy == null ||
        legacy.text != expectedText ||
        !listEquals(legacy.webQuotes, expectedWebQuotes) ||
        (legacy.text.trim().isEmpty && legacy.webQuotes.isEmpty)) {
      return false;
    }
    final current = state.drafts[targetKey];
    final text = current?.text ?? '';
    final quotes = <DraftWebQuote>[];
    for (final quote in [...?current?.webQuotes, ...legacy.webQuotes]) {
      if (quotes.length == DraftWebQuote.limit) break;
      if (!quotes.any((existing) => existing.id == quote.id)) quotes.add(quote);
    }
    save(
      targetKey,
      text.isEmpty
          ? legacy.text
          : legacy.text.isEmpty
          ? text
          : '$text\n\n${legacy.text}',
      current?.attachments ?? const [],
      webQuotes: quotes,
    );
    return true;
  }

  bool _isScopedKey(String key) {
    try {
      final decoded = jsonDecode(key);
      if (decoded is! List || decoded.length != 3 || decoded[0] != 2) return false;
      final host = decoded[1];
      final session = decoded[2];
      return host is String &&
          host.isNotEmpty &&
          (session == null || session is String) &&
          draftStorageKey(hostKey: host, sessionId: session as String?) == key;
    } on FormatException {
      return false;
    }
  }

  /// A deleted session cannot regain a draft through a late preferences load
  /// or the outgoing chat screen's save-on-selection/dispose callback.
  bool isForgotten(String key) => _forgotten.contains(key);

  /// Retire both already restored content and any pending recovery of [key].
  void forget(String key) {
    _forgotten.add(key);
    state = DraftState(
      drafts: Map.unmodifiable({...state.drafts}..remove(key)),
      legacyDrafts: state.legacyDrafts,
      loaded: state.loaded,
    );
    _scheduleWrite();
  }

  /// Writes the texts now (also done 400 ms after the last change).
  Future<void> flush() async {
    _write?.cancel();
    _write = null;
    // Writing before the saved drafts are in would drop them.
    await _restored;
    if (!ref.mounted) return;
    String encode(Map<String, ChatDraft> drafts) => jsonEncode({
      for (final MapEntry(:key, :value) in drafts.entries)
        if (value.text.isNotEmpty || value.webQuotes.isNotEmpty)
          key: {
            't': value.text,
            'at': value.updatedAt.millisecondsSinceEpoch,
            if (value.webQuotes.isNotEmpty) 'webQuotes': value.webQuotes.map((q) => q.toJson()).toList(),
          },
    });
    final json = encode(state.drafts);
    final legacyJson = encode(state.legacyDrafts);
    // A slow older platform write must finish before a newer edit/deletion.
    // Catch inside the queue so one failed write cannot block future saves.
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(preferenceKey, json);
        await prefs.setString(legacyPreferenceKey, legacyJson);
      } catch (_) {}
    });
    await _writes;
  }
}

final draftStoreProvider = NotifierProvider<DraftStore, DraftState>(DraftStore.new);
