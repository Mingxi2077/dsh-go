// 下载管理页面: 显示所有下载项，进度、状态、操作（打开文件、取消、加入会话）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_download_attachment.dart';
import '../../browser/browser_download_helpers.dart';
import '../../browser/browser_downloads.dart';
import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../common/empty_view.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class BrowserDownloadsPage extends ConsumerStatefulWidget {
  const BrowserDownloadsPage({super.key, required this.host, this.sessionId});

  final HostRef host;
  final String? sessionId;

  /// Pops with `true` when the user asks to go back to the conversation
  /// (e.g. from the "加入当前会话" confirmation).
  static Route<bool> route({required HostRef host, String? sessionId}) => MaterialPageRoute<bool>(
    builder: (_) => BrowserDownloadsPage(host: host, sessionId: sessionId),
  );

  @override
  ConsumerState<BrowserDownloadsPage> createState() => _BrowserDownloadsPageState();
}

class _BrowserDownloadsPageState extends ConsumerState<BrowserDownloadsPage> {
  final _addingToChat = <String>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.ready;
      if (mounted) await controller.refresh();
    } catch (_) {}
  }

  Future<void> _changeFolder() async {
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.chooseFolder();
    } on PlatformException catch (e) {
      if (mounted) _showError(browserDownloadErrorText(context, e.code));
    } on StateError {
      if (mounted) _showError(browserDownloadErrorText(context, null));
    }
  }

  Future<void> _resetFolder() async {
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.resetFolder();
    } on PlatformException catch (e) {
      if (mounted) _showError(browserDownloadErrorText(context, e.code));
    } on StateError {
      if (mounted) _showError(browserDownloadErrorText(context, null));
    }
  }

  Future<void> _openFile(String id) async {
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.open(id);
    } on PlatformException catch (e) {
      if (mounted) _showError(browserDownloadErrorText(context, e.code));
    } on StateError {
      if (mounted) _showError(browserDownloadErrorText(context, null));
    }
  }

  Future<void> _cancel(String id) async {
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.cancel(id);
    } on PlatformException catch (e) {
      if (mounted) _showError(browserDownloadErrorText(context, e.code));
    } on StateError {
      if (mounted) _showError(browserDownloadErrorText(context, null));
    }
  }

  Future<void> _addToChat(String id) async {
    if (_addingToChat.contains(id)) return;

    final l10n = context.l10n;
    try {
      setState(() => _addingToChat.add(id));

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.browserDownloadAddToChat),
          content: Text(l10n.browserNotSent),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.browserAddToDraft)),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      final added = await addBrowserDownloadToDraft(
        ref,
        host: widget.host,
        sessionId: widget.sessionId,
        downloadId: id,
      );
      if (!mounted) return;
      if (added) {
        _showMessage(l10n.browserDownloadAddedToChat, goToChat: true);
      } else {
        _showError(l10n.browserDownloadChatChanged);
      }
    } on PlatformException catch (e) {
      if (mounted) _showError(browserDownloadErrorText(context, e.code));
    } catch (e) {
      if (mounted) _showError(browserDownloadErrorText(context, null));
    } finally {
      if (mounted) setState(() => _addingToChat.remove(id));
    }
  }

  void _showMessage(String message, {bool goToChat = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: goToChat
              ? SnackBarAction(
                  label: context.l10n.browserGoToChat,
                  onPressed: () {
                    // The page may already be gone (e.g. the user navigated back
                    // to the browser while this SnackBar was still visible).
                    // Never touch a disposed context and never pop a route that
                    // is no longer the current one.
                    if (!mounted) return;
                    if (ModalRoute.of(context)?.isCurrent != true) return;
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    messenger?.hideCurrentSnackBar();
                    Navigator.of(context).pop(true);
                  },
                )
              : null,
        ),
      );
  }

  void _showError(String error) {
    _showMessage(error);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final state = ref.watch(browserDownloadsProvider);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(l10n.browserDownloads),
        leading: IconButton(icon: const Icon(AppIcons.back), onPressed: () => Navigator.of(context).pop()),
      ),
      body: !state.loaded
          ? const Center(child: CircularProgressIndicator())
          : state.error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(AppIcons.error, size: 48, color: DshColors.of(context).danger),
                    const SizedBox(height: 16),
                    Text(
                      browserDownloadErrorText(context, state.error),
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: _refresh, child: Text(l10n.browserDownloadRetry)),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                // Always scrollable so pull-to-refresh still works when the
                // content is shorter than the viewport.
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  // Folder panel: scrolls with the list so a long path or a
                  // large text scale can never eat the whole viewport.
                  SliverToBoxAdapter(
                    child: Container(
                      padding: EdgeInsets.fromLTRB(16 + media.padding.left, 16, 16 + media.padding.right, 16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        border: Border(
                          bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.browserDownloadFolder,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: DshColors.of(context).textTertiary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          // The full path stays selectable and wraps; it never
                          // truncates the value the user needs to copy.
                          SelectableText(state.folder.label, style: theme.textTheme.bodyMedium),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: _changeFolder,
                                icon: const Icon(AppIcons.files, size: 18),
                                label: Text(l10n.browserDownloadFolderChoose),
                              ),
                              if (!state.folder.isDefault)
                                TextButton.icon(
                                  onPressed: _resetFolder,
                                  icon: const Icon(AppIcons.refresh, size: 18),
                                  label: Text(l10n.browserDownloadFolderReset),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (state.items.isEmpty)
                    // Fills the remaining viewport and stays centred, but still
                    // scrolls when the viewport is shorter than the content.
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: EmptyView(icon: AppIcons.download, title: l10n.browserDownloadNoDownloads),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        16 + media.padding.left,
                        8,
                        16 + media.padding.right,
                        8 + media.padding.bottom,
                      ),
                      sliver: SliverList.builder(
                        itemCount: state.items.length,
                        itemBuilder: (context, index) {
                          final item = state.items[index];
                          return _DownloadItemCard(
                            key: ValueKey('download-${item.id}'),
                            item: item,
                            adding: _addingToChat.contains(item.id),
                            onOpen: () => _openFile(item.id),
                            onCancel: () => _cancel(item.id),
                            onAddToChat: () => _addToChat(item.id),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _DownloadItemCard extends StatelessWidget {
  const _DownloadItemCard({
    super.key,
    required this.item,
    required this.adding,
    required this.onOpen,
    required this.onCancel,
    required this.onAddToChat,
  });

  final BrowserDownloadItem item;
  final bool adding;
  final VoidCallback onOpen;
  final VoidCallback onCancel;
  final VoidCallback onAddToChat;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);

    final statusText = switch (item.status) {
      BrowserDownloadStatus.queued => l10n.browserDownloadInProgress,
      BrowserDownloadStatus.downloading => l10n.browserDownloadInProgress,
      BrowserDownloadStatus.completed =>
        '${l10n.browserDownloadCompleted} · ${browserDownloadFormatBytes(item.received)}',
      BrowserDownloadStatus.failed =>
        item.error != null ? browserDownloadErrorText(context, item.error) : l10n.browserDownloadFailed,
      BrowserDownloadStatus.cancelled => l10n.browserDownloadCancelled,
    };

    final progress = item.total > 0 ? (item.received / item.total).clamp(0.0, 1.0) : null;
    final progressText = item.total < 0
        ? '${browserDownloadFormatBytes(item.received)} · ${l10n.browserDownloadSizeUnknown}'
        : '${browserDownloadFormatBytes(item.received)} / ${browserDownloadFormatBytes(item.total)}';

    final canOpen = item.status == BrowserDownloadStatus.completed;
    final canAddToChat = item.status == BrowserDownloadStatus.completed;
    final canCancel = item.active;
    final showFailedNote = item.status == BrowserDownloadStatus.failed;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconForStatus(item.status), size: 20, color: _colorForStatus(item.status, scheme, colors)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.filename,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.sourceHost,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (item.active) ...[
              LinearProgressIndicator(value: progress, backgroundColor: scheme.surfaceContainerHighest),
              const SizedBox(height: 4),
              Text(progressText, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
            ] else ...[
              Text(
                statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: item.status == BrowserDownloadStatus.failed ? colors.danger : colors.textTertiary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (showFailedNote) ...[
              const SizedBox(height: 4),
              Text(
                l10n.browserDownloadTryFromPage,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ],
            if (item.location.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                item.location,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (canOpen || canAddToChat || canCancel) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (canCancel) TextButton(onPressed: onCancel, child: Text(l10n.browserDownloadCancel)),
                  if (canOpen) TextButton(onPressed: onOpen, child: Text(l10n.browserDownloadOpenFile)),
                  if (canAddToChat)
                    FilledButton.tonal(
                      onPressed: adding ? null : onAddToChat,
                      child: adding
                          ? SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            )
                          : Text(l10n.browserDownloadAddToChat),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _iconForStatus(BrowserDownloadStatus status) {
    return switch (status) {
      BrowserDownloadStatus.queued => AppIcons.waiting,
      BrowserDownloadStatus.downloading => AppIcons.download,
      BrowserDownloadStatus.completed => AppIcons.done,
      BrowserDownloadStatus.failed => AppIcons.error,
      BrowserDownloadStatus.cancelled => AppIcons.close,
    };
  }

  Color _colorForStatus(BrowserDownloadStatus status, ColorScheme scheme, DshColors colors) {
    return switch (status) {
      BrowserDownloadStatus.queued => colors.textTertiary,
      BrowserDownloadStatus.downloading => scheme.primary,
      BrowserDownloadStatus.completed => colors.success,
      BrowserDownloadStatus.failed => colors.danger,
      BrowserDownloadStatus.cancelled => colors.textTertiary,
    };
  }
}
