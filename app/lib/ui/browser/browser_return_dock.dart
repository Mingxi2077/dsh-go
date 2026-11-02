// BrowserReturnDock: a side badge showing the quoted browser page, visible
// only in its original host/conversation. Taps the screen edge to expand: the
// page's thumbnail, title and domain, and two actions — remove the badge
// (leaves the tab open), or reopen the browser to that tab. Collapses back to
// the edge, or swipes off. Supports multiple tabs: each tab one entry, shows list when tapped.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_return.dart';
import '../../browser/browser_workspace.dart' show BrowserScope;
import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_entry.dart';
import 'browser_site.dart';

/// Wraps ChatScreen: shows the return badge when the current route is the chat
/// and a BrowserReturnItem exists for the active host/session scope.
class BrowserReturnDock extends ConsumerStatefulWidget {
  const BrowserReturnDock({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<BrowserReturnDock> createState() => _BrowserReturnDockState();
}

class _BrowserReturnDockState extends ConsumerState<BrowserReturnDock> with SingleTickerProviderStateMixin {
  /// 0: collapsed against the edge; 1: expanded panel or list.
  late final AnimationController _t = AnimationController(vsync: this, duration: Duration.zero);
  BrowserScope? _lastScope;
  List<BrowserReturnItem> _items = [];
  bool _openPending = false;

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  Future<void> _open(BrowserReturnItem item) async {
    if (_openPending) return;
    setState(() => _openPending = true);
    try {
      final success = await reopenBrowserReturn(context, item);
      if (!mounted) return;
      if (success) {
        // Confirm the current scope still matches before collapsing.
        final currentHost = ref.read(activeHostProvider);
        final currentSessionId = ref.read(currentSessionProvider);
        final currentScope = browserScopeFor(currentHost, currentSessionId);
        if (currentScope == item.scope) {
          await _collapse();
        }
      } else {
        // Failed: just collapse without removing the badge.
        final currentHost = ref.read(activeHostProvider);
        final currentSessionId = ref.read(currentSessionProvider);
        final currentScope = browserScopeFor(currentHost, currentSessionId);
        if (currentScope == item.scope) {
          await _collapse();
        }
      }
    } catch (_) {
      // Exception during reopen: keep the badge, do nothing.
    } finally {
      if (mounted) {
        setState(() => _openPending = false);
      }
    }
  }

  void _dismiss(BrowserReturnItem item) {
    ref.read(browserReturnProvider.notifier).dismiss(item.scope, tabId: item.tabId);
  }

  Future<void> _expand() async {
    try {
      await _t.animateTo(1, duration: AppMotion.of(context, AppMotion.quick), curve: AppMotion.std).orCancel;
    } on TickerCanceled {
      // Dismissed mid-flight.
    }
  }

  Future<void> _collapse() async {
    try {
      await _t.animateTo(0, duration: AppMotion.of(context, AppMotion.collapse), curve: AppMotion.std).orCancel;
    } on TickerCanceled {
      // Dismissed mid-flight.
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(activeHostProvider);
    final sessionId = ref.watch(currentSessionProvider);
    final scope = browserScopeFor(host, sessionId);
    final items = ref.watch(browserReturnProvider.select((s) => s.itemsFor(scope)));
    // Only show when the current route is (approximately) the chat: not over a sheet/dialog/browser.
    final route = ModalRoute.of(context);
    final visible = route?.isCurrent == true && items.isNotEmpty;

    // Update local state when scope changes or items change.
    // Use listEquals to avoid new list instance causing spurious resets.
    final scopeChanged = _lastScope != scope;
    if (visible) {
      if (scopeChanged || !listEquals(_items, items)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _lastScope = scope;
              _items = List.from(items);
            });
            // Reset animation only when scope changes.
            if (scopeChanged) {
              _t.value = 0;
            }
          }
        });
      }
    } else if (_lastScope != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _lastScope = null;
            _items = [];
          });
          _t.value = 0;
        }
      });
    }

    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final scheme = theme.colorScheme;

    // Badge on the right edge, avoiding the keyboard and safe areas.
    final screenWidth = media.size.width;
    final screenHeight = media.size.height;
    final keyboardHeight = media.viewInsets.bottom;
    final safeTop = media.padding.top;
    final safeBottom = math.max(media.padding.bottom, keyboardHeight);
    final safeHorizontal = media.padding.left + media.padding.right;
    final availableHeight = screenHeight - safeTop - safeBottom;

    // Collapsed badge at 40% of available height.
    final collapsedBadgeTop = safeTop + availableHeight * 0.4;

    return Stack(
      children: [
        widget.child,
        if (visible && _items.isNotEmpty && _lastScope == scope)
          AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              // Hide if no space available.
              if (availableHeight < 56.0 || screenWidth - safeHorizontal - 24 <= 0) {
                return const SizedBox.shrink();
              }

              final t = _t.value.clamp(0.0, 1.0);
              final hasMultiple = _items.length > 1;

              // Collapsed: 44dp wide transparent hit area on-screen, 12dp visual edge.
              // Expanded: 280-wide card or list, constrained by screen width.
              const hitWidth = 44.0;
              const collapsedVisualWidth = 12.0;
              final maxExpandedWidth = math.min(280.0, screenWidth - safeHorizontal - 24);
              final containerWidth = lerpDouble(hitWidth, maxExpandedWidth, t)!;
              final visualWidth = lerpDouble(collapsedVisualWidth, maxExpandedWidth, t)!;

              // Visual height: collapsed 56, expanded to fit content or list.
              const collapsedVisualHeight = 56.0;
              final maxExpandedHeight = hasMultiple
                  ? math.min(400.0, availableHeight * 0.7)
                  : math.min(300.0, availableHeight * 0.5);
              final visualHeight = lerpDouble(collapsedVisualHeight, maxExpandedHeight, t)!;

              // Expanded top must stay within [safeTop, screenHeight - safeBottom - visualHeight].
              // Collapsed at 40%, expanded clamped to fit.
              final expandedTop = (collapsedBadgeTop + collapsedVisualHeight * 0.5 - visualHeight * 0.5).clamp(
                safeTop,
                screenHeight - safeBottom - visualHeight,
              );
              final badgeTop = lerpDouble(collapsedBadgeTop, expandedTop, t)!;

              // Collapsed: container right=0 (44dp on-screen), visual content right-aligned.
              // Expanded: container right=12.
              final containerRight = lerpDouble(0.0, 12.0, t)!;

              final firstItem = _items.first;

              return Positioned(
                top: badgeTop,
                right: containerRight,
                child: GestureDetector(
                  onTap: t > 0.5 ? null : () => unawaited(_expand()),
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: containerWidth,
                    height: visualHeight,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(lerpDouble(collapsedVisualHeight * 0.5, 16.0, t)!),
                        child: SizedBox(
                          width: visualWidth,
                          height: visualHeight,
                          child: Container(
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4), width: 0.75),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: theme.brightness == Brightness.dark ? 0.32 : 0.15,
                                  ),
                                  blurRadius: 12,
                                  offset: const Offset(-2, 4),
                                ),
                              ],
                            ),
                            child: Stack(
                              children: [
                                // Collapsed preview thumbnail with badge for multiple items.
                                if (t < 0.3)
                                  Positioned.fill(
                                    child: Opacity(
                                      opacity: 1.0 - (t / 0.3),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          firstItem.preview != null
                                              ? Image.memory(
                                                  firstItem.preview!,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (context, error, stack) =>
                                                      Center(child: BrowserSiteMark(url: firstItem.url, size: 24)),
                                                )
                                              : Center(child: BrowserSiteMark(url: firstItem.url, size: 24)),
                                          if (hasMultiple)
                                            Positioned(
                                              top: 4,
                                              right: 4,
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: scheme.primary,
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  '${_items.length}',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    height: 1,
                                                    fontWeight: FontWeight.w600,
                                                    color: scheme.onPrimary,
                                                  ),
                                                  textScaler: TextScaler.noScaling,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                // Expanded panel or list.
                                if (t > 0.3)
                                  Opacity(
                                    opacity: (t - 0.3) / 0.7,
                                    child: hasMultiple
                                        ? _ReturnItemsList(
                                            items: _items,
                                            onOpen: _open,
                                            onDismiss: _dismiss,
                                            onCollapse: _collapse,
                                          )
                                        : OverflowBox(
                                            alignment: Alignment.topRight,
                                            minWidth: maxExpandedWidth,
                                            maxWidth: maxExpandedWidth,
                                            minHeight: 0,
                                            maxHeight: maxExpandedHeight,
                                            child: ConstrainedBox(
                                              constraints: BoxConstraints(
                                                minWidth: maxExpandedWidth,
                                                maxWidth: maxExpandedWidth,
                                                minHeight: 0,
                                                maxHeight: maxExpandedHeight,
                                              ),
                                              child: _ExpandedBadge(
                                                item: firstItem,
                                                onOpen: () => _open(firstItem),
                                                onDismiss: () => _dismiss(firstItem),
                                                onCollapse: _collapse,
                                              ),
                                            ),
                                          ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _ExpandedBadge extends StatelessWidget {
  const _ExpandedBadge({required this.item, required this.onOpen, required this.onDismiss, required this.onCollapse});

  final BrowserReturnItem item;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);

    return Semantics(
      label: l10n.browserReturnToChat,
      button: true,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header: site icon, title/domain, collapse button.
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    BrowserSiteMark(url: item.url, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            browserSite(item.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    Tooltip(
                      message: '收起',
                      child: GestureDetector(
                        onTap: onCollapse,
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Center(child: Icon(AppIcons.collapse, size: 16, color: colors.textTertiary)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Preview thumbnail.
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: double.infinity,
                  height: 120,
                  child: item.preview != null
                      ? Image.memory(
                          item.preview!,
                          width: double.infinity,
                          height: 120,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) => Container(
                            width: double.infinity,
                            height: 120,
                            color: scheme.surfaceContainerHighest,
                            child: Center(child: BrowserSiteMark(url: item.url, size: 32)),
                          ),
                        )
                      : Container(
                          width: double.infinity,
                          height: 120,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Center(child: BrowserSiteMark(url: item.url, size: 32)),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              // Action buttons.
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        key: ValueKey('return-remove-${item.tabId}'),
                        label: l10n.browserRemoveReturn,
                        icon: AppIcons.close,
                        onTap: onDismiss,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        key: ValueKey('return-open-${item.tabId}'),
                        label: l10n.browserReopenBrowser,
                        icon: AppIcons.forward,
                        onTap: onOpen,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: colors.textTertiary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReturnItemsList extends StatelessWidget {
  const _ReturnItemsList({
    required this.items,
    required this.onOpen,
    required this.onDismiss,
    required this.onCollapse,
  });

  final List<BrowserReturnItem> items;
  final void Function(BrowserReturnItem) onOpen;
  final void Function(BrowserReturnItem) onDismiss;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.browserReturnMultiple(items.length),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Tooltip(
                message: '收起',
                child: GestureDetector(
                  onTap: onCollapse,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(child: Icon(AppIcons.collapse, size: 16, color: colors.textTertiary)),
                  ),
                ),
              ),
            ],
          ),
        ),
        // List
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemBuilder: (context, index) {
              final item = items[index];
              return _ReturnItemRow(
                key: ValueKey('return-item-${item.tabId}'),
                item: item,
                onOpen: () => onOpen(item),
                onDismiss: () => onDismiss(item),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ReturnItemRow extends StatelessWidget {
  const _ReturnItemRow({super.key, required this.item, required this.onOpen, required this.onDismiss});

  final BrowserReturnItem item;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('return-open-${item.tabId}'),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 60,
                    height: 45,
                    child: item.preview != null
                        ? Image.memory(
                            item.preview!,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => Container(
                              color: scheme.surfaceContainerLowest,
                              child: Center(child: BrowserSiteMark(url: item.url, size: 16)),
                            ),
                          )
                        : Container(
                            color: scheme.surfaceContainerLowest,
                            child: Center(child: BrowserSiteMark(url: item.url, size: 16)),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        browserSite(item.url),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                      ),
                    ],
                  ),
                ),
                // Delete button
                Tooltip(
                  message: '移除',
                  child: GestureDetector(
                    key: ValueKey('return-remove-${item.tabId}'),
                    onTap: onDismiss,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 44,
                      height: 45,
                      child: Center(child: Icon(AppIcons.close, size: 14, color: colors.textTertiary)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
