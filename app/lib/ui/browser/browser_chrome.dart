// The pieces of 网页's frame: the live page with its progress line and load
// failure, the line under the address, the tab count key and the bottom
// capsule's keys.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_page_controller.dart';
import '../../l10n/l10n.dart';
import '../common/empty_view.dart';
import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_entry.dart' show browserViewBuilderProvider;

abstract final class BrowserChrome {
  /// Height of the top bar's keys and the address.
  static const bar = 44.0;

  /// Side and bottom margin of the floating controls.
  static const edge = 12.0;
}

/// The live page: the WebView, a thin progress line over its top while it
/// loads, and a designed state in its place when it didn't load.
class BrowserPageView extends ConsumerWidget {
  const BrowserPageView({super.key, required this.page, required this.onRetry});

  final BrowserPageController page;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final failed = page.error != null && page.error != 'blocked_url';
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          KeyedSubtree(key: ObjectKey(page), child: ref.watch(browserViewBuilderProvider)(context, page)),
          if (failed)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: SingleChildScrollView(
                  child: EmptyView(
                    icon: AppIcons.offline,
                    title: l10n.webPageNotOpened,
                    message: l10n.browserLoadFailed,
                    actionLabel: l10n.commonRetry,
                    onAction: onRetry,
                  ),
                ),
              ),
            ),
          if (page.loading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: page.progress <= 0 ? null : page.progress / 100,
                minHeight: 2,
                borderRadius: BorderRadius.zero,
                backgroundColor: Colors.transparent,
              ),
            ),
        ],
      ),
    );
  }
}

/// A line under the address while it can't be opened.
class BrowserAddressProblem extends StatelessWidget {
  const BrowserAddressProblem({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.std,
      alignment: Alignment.topCenter,
      child: visible
          ? Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(BrowserChrome.edge + 16, 0, BrowserChrome.edge + 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    context.l10n.browserAddressInvalid,
                    style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
                  ),
                ),
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

/// The tab count in a rounded square, on the bar's round glass key.
class BrowserTabsButton extends StatelessWidget {
  const BrowserTabsButton({super.key, required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final label = l10n.browserTabCount(count);
    return Tooltip(
      message: l10n.browserTabs,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Pressable(
          child: SizedBox.square(
            key: const ValueKey('browser-tabs'),
            dimension: BrowserChrome.bar,
            child: GlassSurface(
              tier: GlassTier.chrome,
              circle: true,
              grouped: true,
              onTap: onPressed,
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: ShapeDecoration(
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: BorderSide(color: scheme.onSurface, width: 1.5),
                    ),
                  ),
                  // The badge keeps its size: the digit is the whole content.
                  child: Text(
                    '$count',
                    textScaler: TextScaler.noScaling,
                    style: AppType.tabular(
                      TextStyle(fontSize: 12, height: 1, fontWeight: FontWeight.w600, color: scheme.onSurface),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round key in the bottom capsule: 44, glyph 22, no fill of its own.
class BrowserToolButton extends StatelessWidget {
  const BrowserToolButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = enabled ? Theme.of(context).colorScheme.onSurface : DshColors.of(context).textDisabled;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            onTap: onPressed,
            radius: 22,
            child: SizedBox.square(dimension: 44, child: Icon(icon, size: 22, color: color)),
          ),
        ),
      ),
    );
  }
}

/// Refresh icon that spins continuously while [loading], stops and resets when
/// loading finishes. When [reducedMotion] is true, shows a static icon.
class BrowserReloadIcon extends StatefulWidget {
  const BrowserReloadIcon({super.key, required this.loading, required this.reducedMotion, required this.color});

  final bool loading;
  final bool reducedMotion;
  final Color color;

  @override
  State<BrowserReloadIcon> createState() => _BrowserReloadIconState();
}

class _BrowserReloadIconState extends State<BrowserReloadIcon> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(seconds: 1), vsync: this);
    if (widget.loading && !widget.reducedMotion) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(BrowserReloadIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading != oldWidget.loading || widget.reducedMotion != oldWidget.reducedMotion) {
      if (widget.loading && !widget.reducedMotion) {
        _controller.repeat();
      } else {
        _controller.stop();
        _controller.reset();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reducedMotion || !widget.loading) {
      return Icon(AppIcons.refresh, size: 22, color: widget.color);
    }
    return RotationTransition(
      turns: _controller,
      child: Icon(AppIcons.refresh, size: 22, color: widget.color),
    );
  }
}
