import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Format bytes to human readable string (B/KB/MB/GB).
String browserDownloadFormatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Localize download error code.
String browserDownloadErrorText(BuildContext context, String? code) {
  final l10n = context.l10n;
  return switch (code) {
    'unsupported' => l10n.browserDownloadUnsupported,
    'expired' => l10n.browserDownloadExpired,
    'folder_changed' => l10n.browserDownloadFolderChanged,
    'directory' => l10n.browserDownloadDirectoryError,
    'permission' => l10n.browserDownloadPermissionError,
    'network' => l10n.browserDownloadNetworkError,
    'http' => l10n.browserDownloadHttpError,
    'incomplete' => l10n.browserDownloadIncomplete,
    'storage' => l10n.browserDownloadStorageError,
    'interrupted' => l10n.browserDownloadInterrupted,
    'no_app' => l10n.browserDownloadNoApp,
    'missing' => l10n.browserDownloadMissing,
    'too_large' => l10n.browserDownloadTooLarge,
    'busy' => l10n.browserDownloadBusy,
    'failed' => l10n.browserDownloadFailed,
    _ => l10n.browserDownloadError,
  };
}
