// 恢复旧草稿: drafts an older version saved by conversation only, with no
// host. Pick one, read it whole, and only then add it after the draft of the
// conversation on screen. The old drafts stay where they are.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/draft_store.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/smooth_size.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The old draft picked and read in full.
typedef LegacyDraftPick = ({String key, String text});

/// There is an old draft with words in it to restore.
bool hasLegacyDrafts(DraftState state) => state.legacyDrafts.values.any((d) => d.text.trim().isNotEmpty);

/// [chat] and [host] name where it goes, fixed when the sheet opens.
Future<LegacyDraftPick?> showLegacyDraftsSheet(BuildContext context, {required String chat, required String host}) =>
    showAppSheet<LegacyDraftPick>(
      context,
      isScrollControlled: true,
      builder: (_) => LegacyDraftsSheet(chat: chat, host: host),
    );

class LegacyDraftsSheet extends ConsumerStatefulWidget {
  const LegacyDraftsSheet({super.key, required this.chat, required this.host});

  final String chat;
  final String host;

  @override
  ConsumerState<LegacyDraftsSheet> createState() => _LegacyDraftsSheetState();
}

class _LegacyDraftsSheetState extends ConsumerState<LegacyDraftsSheet> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final legacy = ref.watch(draftStoreProvider.select((s) => s.legacyDrafts));
    final entries = legacy.entries.where((e) => e.value.text.trim().isNotEmpty).toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    final open = _open == null ? null : legacy[_open];
    String name(String key) => key == 'new' ? l10n.chatLegacyDraftNew : l10n.chatLegacyDraftChat;
    final small = theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary);

    final Widget body;
    if (open == null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter + 8, 0, kSheetGutter + 8, 10),
            child: Text(l10n.chatLegacyDraftsHint, style: small),
          ),
          SheetGroup(
            children: [
              for (final e in entries)
                ListPageRow(
                  key: ValueKey('legacy-draft-${e.key}'),
                  icon: AppIcons.document,
                  title: name(e.key),
                  subtitle: e.value.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
                  onTap: () => setState(() => _open = e.key),
                ),
            ],
          ),
        ],
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(kSheetGutter + 8, 0, kSheetGutter + 8, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(name(_open!), style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(l10n.chatLegacyDraftsHint, style: small),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: BorderDirectional(start: BorderSide(color: theme.colorScheme.outlineVariant, width: 3)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsetsDirectional.only(start: 12),
                  child: Text(
                    key: const ValueKey('legacy-draft-text'),
                    open.text,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            // Where it goes: the conversation, the host under it.
            Row(
              key: const ValueKey('legacy-draft-target'),
              children: [
                Icon(AppIcons.chat, size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.chat,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(widget.host, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l10n.chatLegacyDraftTarget, style: small),
          ],
        ),
      );
    }

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              l10n.chatLegacyDrafts,
              actions: [
                if (open != null)
                  SheetIconButton(
                    icon: AppIcons.back,
                    tooltip: l10n.commonBack,
                    onPressed: () => setState(() => _open = null),
                  ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                child: SmoothSize(
                  duration: AppMotion.of(context, AppMotion.standard),
                  curve: AppMotion.std,
                  alignment: Alignment.topCenter,
                  child: body,
                ),
              ),
            ),
            if (open != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 0),
                child: FilledButton(
                  key: const ValueKey('legacy-draft-append'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => Navigator.of(context).pop((key: _open!, text: open.text)),
                  child: Text(l10n.chatLegacyDraftAppend),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
