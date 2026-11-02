// The 网页 menu (⋯): what to do with the page (bookmark it, share, copy,
// open in the system browser, reload), then the browser's own things
// (bookmarks and history, text size, search engine). On the home page only
// the second group shows: the first has no page to act on.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_library.dart';
import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_entry.dart' show browserEngineName;

enum BrowserMenuChoice { bookmark, share, copy, external, library, downloads, textSize, engine }

/// [page] null: the home page. [bookmarked]: the page is already saved.
Future<BrowserMenuChoice?> showBrowserMenu(BuildContext context, {Uri? page, bool bookmarked = false}) {
  final l10n = context.l10n;
  Widget row(BrowserMenuChoice choice, IconData icon, String title, {String? value}) => Builder(
    builder: (context) => ListPageRow(
      key: ValueKey('browser-menu-${choice.name}'),
      icon: icon,
      title: title,
      value: value,
      chevron: false,
      onTap: () => Navigator.pop(context, choice),
    ),
  );
  return showAppSheet<BrowserMenuChoice>(
    context,
    isScrollControlled: true,
    builder: (sheet) => Consumer(
      builder: (context, ref, _) {
        final library = ref.watch(browserLibraryProvider);
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (page != null)
                  SheetGroup(
                    children: [
                      row(
                        BrowserMenuChoice.bookmark,
                        bookmarked ? AppIcons.bookmarkActive : AppIcons.bookmark,
                        bookmarked ? l10n.browserBookmarkEdit : l10n.browserBookmarkAdd,
                      ),
                      row(BrowserMenuChoice.share, AppIcons.share, l10n.browserShare),
                      row(BrowserMenuChoice.copy, AppIcons.link, l10n.commonCopyLink),
                      row(BrowserMenuChoice.external, AppIcons.openExternal, l10n.browserOpenExternal),
                    ],
                  ),
                SheetGroup(
                  children: [
                    row(BrowserMenuChoice.library, AppIcons.bookmark, l10n.browserLibrary),
                    row(BrowserMenuChoice.downloads, AppIcons.download, l10n.browserDownloads),
                    row(
                      BrowserMenuChoice.textSize,
                      AppIcons.textSize,
                      l10n.browserTextSize,
                      value: '${library.textZoom}%',
                    ),
                    row(
                      BrowserMenuChoice.engine,
                      AppIcons.search,
                      l10n.browserEngine,
                      value: browserEngineName(library.engine, l10n),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 网页文字大小: 75–200 % in steps of 25, applied as it moves.
Future<void> showBrowserTextSizeSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (_) => Consumer(
    builder: (context, ref, _) {
      final l10n = context.l10n;
      final theme = Theme.of(context);
      final zoom = ref.watch(browserLibraryProvider.select((s) => s.textZoom));
      final library = ref.read(browserLibraryProvider.notifier);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(l10n.browserTextSize),
              Row(
                children: [
                  Text('A', textScaler: TextScaler.noScaling, style: theme.textTheme.bodySmall),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('browser-text-size'),
                      value: zoom.clamp(75, 200).toDouble(),
                      min: 75,
                      max: 200,
                      divisions: 5,
                      label: '$zoom%',
                      semanticFormatterCallback: (v) => '${v.round()}%',
                      onChanged: (v) => library.setTextZoom(v.round()),
                    ),
                  ),
                  Text('A', textScaler: TextScaler.noScaling, style: theme.textTheme.titleLarge),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text('$zoom%', style: AppType.tabular(theme.textTheme.bodyMedium ?? const TextStyle())),
                  ),
                  TextButton(
                    onPressed: zoom == 100 ? null : () => library.setTextZoom(100),
                    child: Text(l10n.browserTextSizeReset),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  ),
);

/// 搜索引擎: one of four, the chosen one marked; it closes on a pick.
Future<void> showBrowserEngineSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => Consumer(
    builder: (context, ref, _) {
      final l10n = context.l10n;
      final scheme = Theme.of(context).colorScheme;
      final current = ref.watch(browserLibraryProvider.select((s) => s.engine));
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(l10n.browserEngine),
            SheetGroup(
              children: [
                for (final engine in BrowserSearchEngine.values)
                  Semantics(
                    selected: engine == current,
                    inMutuallyExclusiveGroup: true,
                    child: ListPageRow(
                      key: ValueKey('browser-engine-${engine.name}'),
                      title: browserEngineName(engine, l10n),
                      trailing: engine == current ? Icon(AppIcons.selected, size: 20, color: scheme.primary) : null,
                      chevron: false,
                      onTap: () {
                        ref.read(browserLibraryProvider.notifier).setEngine(engine);
                        Navigator.of(sheet).pop();
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
    },
  ),
);
