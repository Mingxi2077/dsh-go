// 引用到对话: read the selection or the page's text when asked, show what was
// read and where it goes, and put it in that conversation's draft only once
// confirmed. A page that moves on retires what was read.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_page_controller.dart';
import '../../browser/browser_policy.dart';
import '../../browser/browser_workspace.dart';
import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/smooth_size.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_site.dart' show browserSite;

/// Where a quote goes, as people read it: the conversation, then the host.
typedef BrowserQuoteTarget = ({String chat, String host});

/// True once the quote is in the inbox for [scope]'s draft.
Future<bool> showBrowserQuoteSheet(
  BuildContext context, {
  required BrowserPageController page,
  required BrowserScope scope,
  required BrowserQuoteTarget target,
  BrowserPageContent? initialContent,
}) async =>
    await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      builder: (_) => BrowserQuoteSheet(page: page, scope: scope, target: target, initialContent: initialContent),
    ) ??
    false;

/// The words for what reading the page threw (the backend's codes).
String browserExtractProblem(Object error) {
  final l10n = appL10n;
  return switch (error) {
    StateError(message: 'empty_selection') => l10n.browserNoSelection,
    StateError(message: 'empty_page') => l10n.browserEmptyPage,
    _ => l10n.browserExtractFailed,
  };
}

class BrowserQuoteSheet extends ConsumerStatefulWidget {
  const BrowserQuoteSheet({
    super.key,
    required this.page,
    required this.scope,
    required this.target,
    this.initialContent,
  });

  final BrowserPageController page;
  final BrowserScope scope;
  final BrowserQuoteTarget target;
  final BrowserPageContent? initialContent;

  @override
  ConsumerState<BrowserQuoteSheet> createState() => _BrowserQuoteSheetState();
}

class _BrowserQuoteSheetState extends ConsumerState<BrowserQuoteSheet> {
  /// Which read is running (true: the selection); null when none is.
  bool? _reading;

  /// What was read, and the page address it was read at.
  BrowserPageContent? _content;
  Uri? _readAt;
  int? _readRevision;
  bool _stale = false;
  String? _problem;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    widget.page.addListener(_onPage);
    final initial = widget.initialContent;
    if (initial != null) {
      final page = widget.page;
      // Verify initialContent.url matches the page's saved URL (policy-normalized)
      if (page.ready && BrowserPolicy.savedUrl(page.url) == initial.url) {
        _content = initial;
        _readAt = page.url;
        _readRevision = page.revision;
      }
    }
  }

  @override
  void dispose() {
    widget.page.removeListener(_onPage);
    super.dispose();
  }

  /// A load, a renderer loss or another address retires what was read.
  void _onPage() {
    final page = widget.page;
    if (_content == null || _stale) return;
    // Compare full URLs: page.url != _readAt
    if (!page.ready || page.url != _readAt || page.revision != _readRevision) {
      setState(() => _stale = true);
    }
  }

  Future<void> _read({required bool selection}) async {
    final page = widget.page;
    final attempt = ++_attempt;
    final revision = page.revision;
    final url = page.url;
    setState(() {
      _reading = selection;
      _problem = null;
      _stale = false;
    });
    try {
      final content = await page.extract(selection: selection);
      if (!mounted || attempt != _attempt) return;
      if (!page.ready || page.revision != revision || page.url != url) {
        throw StateError('page_changed');
      }
      setState(() {
        _reading = null;
        _content = content;
        _readAt = url;
        _readRevision = revision;
      });
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      // No selection is said as such: the page's text is never read instead.
      setState(() {
        _reading = null;
        _content = null;
        _problem = browserExtractProblem(error);
      });
    }
  }

  void _add() {
    _onPage();
    final content = _content;
    if (content == null || _stale) return;
    try {
      ref.read(browserReferenceInboxProvider.notifier).add(BrowserReference(scope: widget.scope, content: content));
    } on StateError {
      setState(() => _problem = context.l10n.browserReferenceLimit);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final content = _content;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(l10n.browserQuote),
            Flexible(
              child: SingleChildScrollView(
                child: SmoothSize(
                  duration: AppMotion.of(context, AppMotion.standard),
                  curve: AppMotion.std,
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Target(target: widget.target),
                      if (content == null) _choices(context) else _Preview(content: content, stale: _stale),
                      if (_problem case final problem?) _Hint(problem),
                    ],
                  ),
                ),
              ),
            ),
            if (content != null) _actions(context, content),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _choices(BuildContext context) {
    final l10n = context.l10n;
    final page = widget.page;
    final busy = _reading != null;
    final ready = page.ready;
    Widget? ring(bool selection) => _reading == selection
        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : null;
    return SheetGroup(
      children: [
        ListPageRow(
          key: const ValueKey('browser-quote-selection'),
          icon: AppIcons.selectText,
          title: l10n.browserQuoteSelection,
          subtitle: l10n.browserQuoteSelectionHint,
          trailing: ring(true),
          chevron: false,
          onTap: busy || !ready ? null : () => unawaited(_read(selection: true)),
        ),
        ListPageRow(
          key: const ValueKey('browser-quote-page'),
          icon: AppIcons.article,
          title: l10n.browserQuotePage,
          subtitle: l10n.browserQuotePageHint,
          trailing: ring(false),
          chevron: false,
          onTap: busy || !ready ? null : () => unawaited(_read(selection: false)),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context, BrowserPageContent content) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 0),
      child: FilledButton(
        key: const ValueKey('browser-quote-confirm'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _reading != null
            ? null
            : _stale
            ? () => unawaited(_read(selection: content.selection))
            : _add,
        child: Text(_stale ? l10n.commonRetry : l10n.browserAddToDraft),
      ),
    );
  }
}

/// Where the quote goes: the conversation, the host under it.
class _Target extends StatelessWidget {
  const _Target({required this.target});

  final BrowserQuoteTarget target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter + 8, 0, kSheetGutter + 8, 10),
      child: Row(
        children: [
          Icon(AppIcons.chat, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(target.chat, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                Text(
                  target.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What was read: its source, then the text as a quote.
class _Preview extends StatelessWidget {
  const _Preview({required this.content, required this.stale});

  final BrowserPageContent content;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary);
    final site = browserSite(content.url);
    final title = content.title.trim().isEmpty ? site : content.title.trim();
    final kind = content.selection ? l10n.browserQuoteSelection : l10n.browserQuotePage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter + 8, 4, kSheetGutter + 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 2),
          Text(
            '$site · $kind · ${l10n.browserCharCount(content.text.length)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.tabular(small ?? const TextStyle()),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.36),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: BorderDirectional(start: BorderSide(color: scheme.outlineVariant, width: 3)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsetsDirectional.only(start: 12),
                child: Text(
                  key: const ValueKey('browser-quote-text'),
                  content.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: stale ? colors.textDisabled : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (content.truncated) Text(l10n.browserTruncated, style: small),
          Text(stale ? l10n.browserPreviewStale : l10n.browserNotSent, style: small),
        ],
      ),
    );
  }
}

/// One quiet line for what didn't work (nothing selected, a page that
/// changed), read out when it appears.
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter + 8, 10, kSheetGutter + 8, 0),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(AppIcons.info, size: 16, color: colors.textTertiary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}
