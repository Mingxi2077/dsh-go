// 下载确认sheet: 显示文件名、来源、大小、保存位置，可修改文件夹
// 返回String? folderId: null=取消，空串=默认，非空=选中的目录ID

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_download_helpers.dart';
import '../../browser/browser_downloads.dart';
import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Show download confirmation sheet. Returns folderId: null if cancelled, empty string for default, non-empty for selected.
Future<String?> showBrowserDownloadConfirmation(BuildContext context, BrowserDownloadRequest request) async {
  return showAppSheet<String?>(
    context,
    isScrollControlled: true,
    builder: (_) => _BrowserDownloadConfirmSheet(request: request),
  );
}

class _BrowserDownloadConfirmSheet extends ConsumerStatefulWidget {
  const _BrowserDownloadConfirmSheet({required this.request});

  final BrowserDownloadRequest request;

  @override
  ConsumerState<_BrowserDownloadConfirmSheet> createState() => _BrowserDownloadConfirmSheetState();
}

class _BrowserDownloadConfirmSheetState extends ConsumerState<_BrowserDownloadConfirmSheet> {
  bool _loaded = false;
  bool _firstTime = false;
  bool _starting = false;
  bool _changing = false;
  bool _retrying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.ready;
      if (!mounted) return;
      final state = ref.read(browserDownloadsProvider);
      setState(() {
        _loaded = true;
        _firstTime = state.firstDownload;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = browserDownloadErrorText(context, null);
      });
    }
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _error = null;
    });
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.refresh();
      if (!mounted) return;
      await _loadState();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = browserDownloadErrorText(context, null));
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _changeFolder() async {
    if (_changing) return;
    setState(() => _changing = true);
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.chooseFolder();
      if (!mounted) return;
      setState(() => _error = null);
    } on PlatformException catch (e) {
      if (!mounted) return;
      // User cancelled: no error
      if (e.code == 'cancelled' || e.code == 'CANCELLED') {
        setState(() => _error = null);
      } else {
        setState(() => _error = browserDownloadErrorText(context, e.code));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = browserDownloadErrorText(context, null));
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _resetFolder() async {
    if (_changing) return;
    setState(() => _changing = true);
    final controller = ref.read(browserDownloadsProvider.notifier);
    try {
      await controller.resetFolder();
      if (!mounted) return;
      setState(() => _error = null);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = browserDownloadErrorText(context, e.code));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = browserDownloadErrorText(context, null));
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  void _confirm() {
    if (_starting || !_loaded) return;
    final state = ref.read(browserDownloadsProvider);
    if (state.error != null) return;
    setState(() => _starting = true);
    final folderId = state.folder.id;
    Navigator.of(context).pop(folderId);
  }

  void _cancel() {
    if (_starting) return;
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final state = ref.watch(browserDownloadsProvider);
    final request = widget.request;

    if (!request.supported) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(l10n.browserDownload),
              const SizedBox(height: 16),
              Text(
                browserDownloadErrorText(context, 'unsupported'),
                style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _cancel, child: Text(l10n.commonClose)),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    }

    if (!_loaded) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(l10n.browserDownloadConfirm),
              const SizedBox(height: 32),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 32),
            ],
          ),
        ),
      );
    }

    if (state.error != null) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(l10n.browserDownloadConfirm),
              const SizedBox(height: 16),
              Text(
                browserDownloadErrorText(context, state.error),
                style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _retrying ? null : _retry,
                  child: _retrying
                      ? SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onPrimary),
                        )
                      : Text(l10n.browserDownloadRetry),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(onPressed: _retrying ? null : _cancel, child: Text(l10n.commonCancel)),
              ),
            ],
          ),
        ),
      );
    }

    final sizeText = request.bytes < 0 ? l10n.browserDownloadSizeUnknown : browserDownloadFormatBytes(request.bytes);

    final canConfirm = _loaded && !_starting && state.error == null;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(l10n.browserDownloadConfirm),
              if (_firstTime) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(AppIcons.info, size: 16, color: colors.textTertiary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.browserDownloadFirstTimeNote,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SheetGroup(
                children: [
                  _InfoRow(label: l10n.browserDownloadFileName, value: request.filename),
                  _InfoRow(label: l10n.browserDownloadSource, value: request.url.host),
                  _InfoRow(label: l10n.browserDownloadFileSize, value: sizeText),
                ],
              ),
              const SizedBox(height: 16),
              SheetGroup(
                children: [
                  ListPageRow(
                    key: const ValueKey('download-folder'),
                    icon: AppIcons.files,
                    title: l10n.browserDownloadLocation,
                    value: state.folder.label,
                    chevron: true,
                    onTap: (_starting || _changing) ? null : _changeFolder,
                  ),
                  if (!state.folder.isDefault)
                    ListPageRow(
                      key: const ValueKey('download-folder-reset'),
                      icon: AppIcons.refresh,
                      title: l10n.browserDownloadFolderReset,
                      chevron: false,
                      onTap: (_starting || _changing) ? null : _resetFolder,
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('download-start'),
                onPressed: canConfirm ? _confirm : null,
                child: Text(l10n.browserDownloadStart),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: _starting ? null : _cancel, child: Text(l10n.commonCancel)),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
