import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/web_quote.dart';
import '../../browser/browser_site.dart';
import '../../common/app_sheet.dart';
import '../../theme/theme.dart';

/// A compact card for a web quote in the composer tray: site mark, title,
/// meta line. Tap opens a local snapshot preview sheet.
class WebQuoteCard extends StatelessWidget {
  const WebQuoteCard({super.key, required this.quote});

  final DraftWebQuote quote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final site = browserSite(quote.url);
    final title = quote.title.trim().isEmpty ? site : quote.title.trim();
    final kind = quote.selection ? context.l10n.chatWebQuoteSelection : context.l10n.chatWebQuotePage;
    return Semantics(
      button: true,
      label: '${context.l10n.chatWebQuote}: $title, $site',
      child: InkWell(
        key: ValueKey('web-quote-${quote.id}'),
        onTap: () => _showPreview(context),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 56,
          constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          decoration: ShapeDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            shape: Squircle.border(16),
          ),
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SiteMark(url: quote.url, size: 40),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
                      Text(
                        '$site · $kind',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showPreview(BuildContext context) {
    return showAppSheet<void>(context, isScrollControlled: true, builder: (_) => _PreviewSheet(quote: quote));
  }
}

/// Simplified site mark: first letter in identity color, no favicon fetch.
class _SiteMark extends StatelessWidget {
  const _SiteMark({required this.url, required this.size});

  final Uri url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final site = browserSite(url);
    final tint = site.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff) % colors.identity.length;
    final letter = site.isEmpty ? '?' : String.fromCharCode(site.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(color: colors.identity[tint], shape: const CircleBorder()),
          child: Center(
            child: Text(
              letter,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: size * 0.44,
                height: 1,
                fontWeight: FontWeight.w600,
                color: colors.onIdentity[tint],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview sheet: URL, title, text, selection/truncation state. Local only.
class _PreviewSheet extends StatelessWidget {
  const _PreviewSheet({required this.quote});

  final DraftWebQuote quote;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final site = browserSite(quote.url);
    final title = quote.title.trim().isEmpty ? site : quote.title.trim();
    final kind = quote.selection ? l10n.chatWebQuoteSelection : l10n.chatWebQuotePage;
    final small = theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(l10n.chatWebQuotePreview),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(kSheetGutter + 8, 4, kSheetGutter + 8, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    SelectableText(quote.url.toString(), style: AppType.tabular(small ?? const TextStyle())),
                    const SizedBox(height: 2),
                    Text(
                      '$site · $kind · ${l10n.browserCharCount(quote.text.length)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.tabular(small ?? const TextStyle()),
                    ),
                    const SizedBox(height: 12),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: BorderDirectional(start: BorderSide(color: scheme.outlineVariant, width: 3)),
                      ),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 12),
                        child: SelectableText(
                          quote.text,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                    if (quote.truncated) ...[const SizedBox(height: 10), Text(l10n.browserTruncated, style: small)],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
