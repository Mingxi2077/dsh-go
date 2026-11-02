// 书签与历史: this phone's browser data, not the conversation's. Bookmarks
// open, are renamed or re-addressed, and deleted; history entries open and
// are removed one by one, or all at once after asking. Picking one closes
// the page with its address for the tab that opened it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_library.dart';
import '../../browser/browser_omnibox.dart';
import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_site.dart';

enum BrowserLibraryTab { bookmarks, history }

/// The address picked, if any.
Future<Uri?> openBrowserLibrary(BuildContext context, {BrowserLibraryTab tab = BrowserLibraryTab.bookmarks}) =>
    Navigator.of(context).push(MaterialPageRoute<Uri>(builder: (_) => BrowserLibraryPage(initial: tab)));

class BrowserLibraryPage extends ConsumerStatefulWidget {
  const BrowserLibraryPage({super.key, this.initial = BrowserLibraryTab.bookmarks});

  final BrowserLibraryTab initial;

  @override
  ConsumerState<BrowserLibraryPage> createState() => _BrowserLibraryPageState();
}

class _BrowserLibraryPageState extends ConsumerState<BrowserLibraryPage> {
  late BrowserLibraryTab _tab = widget.initial;

  void _toast(String message) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _clear() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.browserHistoryClearConfirm),
        content: Text(l10n.browserHistoryClearNote),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            key: const ValueKey('browser-history-clear-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.browserHistoryClear),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(browserLibraryProvider.notifier).clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final library = ref.watch(browserLibraryProvider);
    final history = _tab == BrowserLibraryTab.history;
    final List<Widget> rows;
    if (!library.loaded) {
      rows = const [
        Padding(
          padding: EdgeInsets.only(top: 48),
          child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      ];
    } else if (history) {
      rows = library.history.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.only(top: 48),
                child: EmptyView(icon: AppIcons.history, title: l10n.browserNoHistory),
              ),
            ]
          : [
              ListPageCard(
                children: [
                  for (final entry in library.history)
                    ListPageRow(
                      key: ValueKey('browser-history-${entry.id}'),
                      leading: BrowserSiteMark(url: entry.url, size: 28),
                      title: browserTitle(entry.title, entry.url),
                      subtitle: browserSite(entry.url),
                      onTap: () => Navigator.of(context).pop(entry.url),
                      trailing: _RowKey(
                        icon: AppIcons.close,
                        tooltip: l10n.browserHistoryRemove,
                        onTap: () => unawaited(ref.read(browserLibraryProvider.notifier).removeHistory(entry.id)),
                      ),
                    ),
                ],
              ),
            ];
    } else {
      rows = library.bookmarks.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.only(top: 48),
                child: EmptyView(
                  icon: AppIcons.bookmark,
                  title: l10n.browserNoBookmarks,
                  message: l10n.browserNoBookmarksHint,
                ),
              ),
            ]
          : [
              ListPageCard(
                children: [
                  for (final mark in library.bookmarks)
                    ListPageRow(
                      key: ValueKey('browser-bookmark-${mark.id}'),
                      leading: BrowserSiteMark(url: mark.url, size: 28),
                      title: browserTitle(mark.title, mark.url),
                      subtitle: mark.url.toString(),
                      onTap: () => Navigator.of(context).pop(mark.url),
                      trailing: _RowKey(
                        icon: AppIcons.edit,
                        tooltip: l10n.browserBookmarkEdit,
                        onTap: () async {
                          final removed = await showBookmarkEditor(context, bookmark: mark);
                          if (removed && context.mounted) _toast(context.l10n.browserBookmarkRemoved);
                        },
                      ),
                    ),
                ],
              ),
            ];
    }
    return AppPage.list(
      title: l10n.browserLibrary,
      actions: [
        if (history && library.history.isNotEmpty)
          GlassIconButton(
            key: const ValueKey('browser-history-clear'),
            icon: AppIcons.clearAll,
            tooltip: l10n.browserHistoryClear,
            onPressed: () => unawaited(_clear()),
          ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SegmentedPill<BrowserLibraryTab>(
            segments: [
              PillSegment(BrowserLibraryTab.bookmarks, l10n.browserBookmarks),
              PillSegment(BrowserLibraryTab.history, l10n.browserHistory),
            ],
            selected: _tab,
            onChanged: (tab) => setState(() => _tab = tab),
          ),
        ),
        if (library.persistenceFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              l10n.browserLibraryUnsaved,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ),
        ...rows,
      ],
    );
  }
}

/// A 44 key at a row's end (edit, remove).
class _RowKey extends StatelessWidget {
  const _RowKey({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      onTap: onTap,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox.square(dimension: 44, child: Icon(icon, size: 18, color: DshColors.of(context).textTertiary)),
      ),
    ),
  );
}

/// Adds [url] (with [title]) as a bookmark or edits [bookmark]: its name and
/// address, or deletes it. True when it was deleted.
Future<bool> showBookmarkEditor(BuildContext context, {BrowserBookmark? bookmark, Uri? url, String title = ''}) async =>
    await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      builder: (_) => _BookmarkEditor(bookmark: bookmark, url: url, title: title),
    ) ??
    false;

class _BookmarkEditor extends ConsumerStatefulWidget {
  const _BookmarkEditor({this.bookmark, this.url, this.title = ''});

  final BrowserBookmark? bookmark;
  final Uri? url;
  final String title;

  @override
  ConsumerState<_BookmarkEditor> createState() => _BookmarkEditorState();
}

class _BookmarkEditorState extends ConsumerState<_BookmarkEditor> {
  late final _name = TextEditingController(text: widget.bookmark?.title ?? widget.title);
  late final _address = TextEditingController(text: (widget.bookmark?.url ?? widget.url)?.toString() ?? '');
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    // The same reading as the address field: a typed site gets https; a
    // search or a blocked address is not a bookmark.
    final intent = BrowserOmnibox.resolve(_address.text);
    if (intent == null || intent.isSearch) {
      setState(() => _problem = l10n.browserAddressInvalid);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(browserLibraryProvider.notifier)
          .saveBookmark(intent.url, title: _name.text.trim(), id: widget.bookmark?.id);
      if (mounted) Navigator.of(context).pop(false);
    } on FormatException {
      if (mounted) setState(() => _problem = l10n.browserAddressInvalid);
    } on StateError catch (e) {
      if (mounted) {
        setState(
          () => _problem = e.message == 'bookmark_limit' ? l10n.browserBookmarkLimit : l10n.browserBookmarkMissing,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = widget.bookmark?.id;
    if (id == null) return;
    await ref.read(browserLibraryProvider.notifier).removeBookmark(id);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final editing = widget.bookmark != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(editing ? l10n.browserBookmarkEdit : l10n.browserBookmarkAdd),
                TextField(
                  key: const ValueKey('browser-bookmark-name'),
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(labelText: l10n.browserBookmarkTitle),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('browser-bookmark-url'),
                  controller: _address,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) {
                    if (_problem != null) setState(() => _problem = null);
                  },
                  onSubmitted: (_) => unawaited(_save()),
                  decoration: InputDecoration(labelText: l10n.browserBookmarkUrl, errorText: _problem),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const ValueKey('browser-bookmark-save'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _busy ? null : () => unawaited(_save()),
                  child: Text(l10n.commonSave),
                ),
                if (editing) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('browser-bookmark-delete'),
                    style: TextButton.styleFrom(foregroundColor: colors.danger, minimumSize: const Size.fromHeight(44)),
                    onPressed: _busy ? null : () => unawaited(_delete()),
                    child: Text(l10n.commonDelete),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
