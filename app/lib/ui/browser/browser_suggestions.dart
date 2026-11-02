// What the address field offers while typing: first what Enter would do (go
// to the address, or search with the chosen engine), then matching
// bookmarks and history from this phone. Nothing typed leaves the phone
// until it is submitted.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_library.dart';
import '../../browser/browser_omnibox.dart';
import '../../l10n/l10n.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_entry.dart' show browserEngineName;
import 'browser_site.dart';

class BrowserSuggestions extends ConsumerWidget {
  const BrowserSuggestions({super.key, required this.input, required this.onOpen});

  /// What is typed so far.
  final String input;

  /// Go to this address (a suggestion, or what Enter would open).
  final ValueChanged<Uri> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final library = ref.watch(browserLibraryProvider);
    final text = input.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final intent = BrowserOmnibox.resolve(text, engine: library.engine);
    final matches = library.loaded ? library.suggestions(text) : const <BrowserSuggestion>[];
    if (intent == null && matches.isEmpty) return const SizedBox.shrink();
    final colors = DshColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        key: const ValueKey('browser-suggestions'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
        children: [
          ListPageCard(
            margin: EdgeInsets.zero,
            children: [
              if (intent != null)
                ListPageRow(
                  key: const ValueKey('browser-suggestion-go'),
                  icon: intent.isSearch ? AppIcons.search : AppIcons.webApp,
                  title: intent.isSearch ? intent.query! : browserSite(intent.url),
                  subtitle: intent.isSearch
                      ? l10n.browserSearchWith(browserEngineName(library.engine, l10n))
                      : intent.url.toString(),
                  chevron: false,
                  onTap: () => onOpen(intent.url),
                ),
              for (final s in matches)
                ListPageRow(
                  key: ValueKey('browser-suggestion-${s.url}'),
                  leading: Icon(
                    s.bookmarked ? AppIcons.bookmark : AppIcons.history,
                    size: 20,
                    color: colors.textTertiary,
                  ),
                  title: browserTitle(s.title, s.url),
                  subtitle: s.url.toString(),
                  chevron: false,
                  onTap: () => onOpen(s.url),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
