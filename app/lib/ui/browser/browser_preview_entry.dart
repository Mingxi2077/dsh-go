import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_workspace.dart';
import '../../l10n/l10n.dart';
import '../../remote/ssh/ssh_link.dart';
import '../../remote/ssh/ssh_transport.dart' show TunnelRefused;
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import 'browser_entry.dart' show browserScopeFor;
import 'browser_page.dart';

Future<void> openSshWebPreview(
  BuildContext context, {
  required HostRef host,
  required String? sessionId,
  required bool Function() ownsSession,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final link = container.read(hostLinkProvider(host));
  if (link is! SshHostLink) return;
  final route = ModalRoute.of(context);
  final l10n = context.l10n;
  bool current() =>
      ownsSession() && route?.isCurrent == true && identical(container.read(hostLinkProvider(host)), link);

  final port = await _askPort(context);
  if (port == null || !context.mounted || !current()) return;

  SshWebPreview? preview;
  try {
    preview = await link.openWebPreview(port);
    if (!current()) return;
    final workspace = container.read(browserWorkspaceProvider.notifier);
    final tab = await workspace.openWebPreview(browserScopeFor(host, sessionId), preview);
    if (!context.mounted || !current()) {
      await workspace.close(tab.id);
      return;
    }
    preview = null; // The tab owns it now.
    unawaited(Navigator.of(context).push(BrowserPage.route(host: host, sessionId: sessionId)));
  } on Object catch (error) {
    if (!context.mounted || !current()) return;
    final message = switch (error) {
      TunnelRefused() => l10n.browserPreviewPortUnreachable(port),
      StateError(message: 'tab_limit') => l10n.browserTabLimit,
      StateError(message: 'ssh_not_connected') => l10n.webConnectHostFirst(link.config.name),
      _ => '${l10n.browserPreviewFailed} $error',
    };
    showBriefNotice(context, message);
  } finally {
    await preview?.close();
  }
}

Future<int?> _askPort(BuildContext context) {
  final form = GlobalKey<FormState>();
  int? port;
  return showAppDialog<int>(
    context: context,
    builder: (dialog) {
      final l10n = dialog.l10n;
      void submit() {
        if (form.currentState!.validate()) Navigator.pop(dialog, port);
      }

      return AlertDialog(
        title: Text(l10n.browserPreview),
        content: Form(
          key: form,
          child: TextFormField(
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(labelText: l10n.browserPreviewPort, hintText: '5173'),
            validator: (value) {
              port = int.tryParse(value?.trim() ?? '', radix: 10);
              return port != null && port! >= 1 && port! <= 65535 ? null : l10n.browserPreviewInvalidPort;
            },
            onFieldSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: submit, child: Text(l10n.commonOpen)),
        ],
      );
    },
  );
}
