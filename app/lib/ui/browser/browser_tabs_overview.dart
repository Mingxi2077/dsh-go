// 标签页总览: one conversation's tabs as page cards, two across on a phone.
// It opens with the current page shrinking from where it was into its card
// (corners rounding as it goes) while the grid fades in around it; picking a
// card grows that card back into the page. (Spatial reference: Edge's tab
// switcher, 0.8–1.6 s in and 2.0–2.9 s out; see
// docs/design/browser-motion-refresh.md.) What flies is a bitmap — the page's
// last in-memory snapshot, or a native face drawn from the tab's own data —
// never the live WebView, which stays offstage under the overview. The cross
// closes (with 撤销), ＋ opens a new home page, and 关闭全部 asks first. The
// page does the closing so it can keep a page open.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_workspace.dart';
import '../../l10n/l10n.dart';
import '../../performance/refresh_rate.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_home.dart' show BrowserWordmark;
import 'browser_site.dart';

export 'browser_site.dart' show browserSite;

/// What the page does for the overview.
class BrowserTabsActions {
  const BrowserTabsActions({required this.newTab, required this.close, required this.restore, required this.closeAll});

  /// A new home page (it becomes the open tab).
  final Future<void> Function() newTab;

  /// Closes a tab; the record, for 撤销, when it was there.
  final Future<BrowserTab?> Function(String id) close;

  /// Puts a closed tab back; false when it can't come back (full, gone).
  final Future<bool> Function(BrowserTab tab) restore;

  /// Closes every tab of the conversation (asked already).
  final Future<void> Function() closeAll;
}

/// A tab's last snapshot, in memory only: never saved, drafted or recorded.
class BrowserTabPreview {
  BrowserTabPreview({required this.image, required this.url, required this.revision, required this.owner});

  final MemoryImage image;

  /// The address and document revision it shows, and the live page it was
  /// drawn from (a new page for the tab is a different document).
  final Uri url;
  final int revision;
  final Object owner;

  /// Shown for [tab] only while the tab is still on that address.
  bool shows(BrowserTab tab) => tab.url == url;
}

/// Card geometry, shared by the grid and the flight.
class _Grid {
  _Grid(Size size, EdgeInsets inset, double scale, this.count) {
    columns = size.width >= 600 ? 3 : 2;
    cardWidth = (size.width - inset.horizontal - pad * 2 - gap * (columns - 1)) / columns;
    header = (36 + (scale - 1) * 20).clamp(36.0, 48.0);
    thumb = cardWidth * 1.3;
    cardHeight = header + thumb + 4;
    left = inset.left + pad;
    right = inset.right + pad;
    top = inset.top;
    bottom = inset.bottom;
    viewport = size.height - inset.vertical;
    final rows = (count / columns).ceil();
    extent = pad * 2 + rows * cardHeight + math.max(0, rows - 1) * gap;
  }

  static const pad = 12.0;
  static const gap = 12.0;
  final int count;
  late final int columns;
  late final double cardWidth, header, thumb, cardHeight, left, right, top, bottom, viewport, extent;

  double get maxScroll => math.max(0, extent - viewport);

  Rect card(int index, double scroll) {
    final row = index ~/ columns;
    final col = index % columns;
    return Rect.fromLTWH(
      left + col * (cardWidth + gap),
      top + pad + row * (cardHeight + gap) - scroll,
      cardWidth,
      cardHeight,
    );
  }

  /// Where the page's picture sits inside the card.
  Rect thumbOf(Rect card) => Rect.fromLTWH(card.left + 4, card.top + header, card.width - 8, thumb);

  /// A scroll that shows [index] (its row in the middle when it can).
  double reveal(int index) {
    if (index < 0) return 0;
    final row = index ~/ columns;
    final y = pad + row * (cardHeight + gap);
    return (y - (viewport - cardHeight) / 2).clamp(0.0, maxScroll);
  }
}

class BrowserTabsOverview extends ConsumerStatefulWidget {
  const BrowserTabsOverview({
    super.key,
    required this.scope,
    required this.actions,
    required this.previews,
    required this.origin,
    required this.onDismissed,
    this.onRevealPage,
  });

  final BrowserScope scope;
  final BrowserTabsActions actions;

  /// Snapshots by tab id.
  final Map<String, BrowserTabPreview> previews;

  /// Where the open page is drawn, in this widget's coordinates.
  final Rect origin;

  /// The overview finished growing back into the open tab.
  final VoidCallback onDismissed;

  /// Called when leaving: notifies parent to reveal the real page under the overview.
  final VoidCallback? onRevealPage;

  /// Card corner radius the flight ends at.
  static const radius = 12.0;

  @override
  ConsumerState<BrowserTabsOverview> createState() => BrowserTabsOverviewState();
}

class BrowserTabsOverviewState extends ConsumerState<BrowserTabsOverview> with TickerProviderStateMixin {
  /// 0: the page fills [BrowserTabsOverview.origin]; 1: it sits in its card.
  late final AnimationController _t = AnimationController(vsync: this);

  /// Fade-out controller for snapshot/overview during leave.
  late final AnimationController _fade = AnimationController(vsync: this, value: 1.0);
  ScrollController? _scroll;
  bool _started = false;
  bool _leaving = false;
  bool _done = false;

  /// The tab closed last, until it is restored or another one closes.
  BrowserTab? _closed;
  String? _note;
  final _closing = <String>{};

  @override
  void initState() {
    super.initState();
    // Request high refresh rate for the duration of the flight.
    RefreshRateService.instance.requestActivity();
    // Start the flight after the first frame: the grid and bitmap are laid
    // out, and the snapshot is decoded (capped at 300 ms in the page).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started) {
        _started = true;
        unawaited(_run(1, AppMotion.emphasized));
      }
    });
  }

  @override
  void dispose() {
    _t.dispose();
    _fade.dispose();
    _scroll?.dispose();
    super.dispose();
  }

  Future<void> _run(double to, Duration duration) async {
    try {
      await _t.animateTo(to, duration: AppMotion.of(context, duration), curve: AppMotion.glide).orCancel;
    } on TickerCanceled {
      return;
    }
  }

  /// Back to the open tab ([pick] first becomes the open tab), from wherever
  /// the flight is: a back press mid-way turns it around.
  Future<void> leave({String? pick}) async {
    if (_done || !mounted) return;
    if (_leaving) return;
    setState(() => _leaving = true);
    if (pick != null) {
      // Activate the tab now: the page under the overview switches.
      unawaited(ref.read(browserWorkspaceProvider.notifier).activate(pick).catchError((_) {}));
    }
    if (!mounted || _done) return;
    // Notify parent to reveal the real page underneath.
    widget.onRevealPage?.call();
    // Wait for the end of the frame for the platform view to mount.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _done) return;
    RefreshRateService.instance.requestActivity();
    // Run the fly-back animation to full-screen rect.
    await _run(0, AppMotion.collapse);
    if (!mounted || _done || _t.value > 0) return;
    // Now fade out snapshot and overview (Material surface) over 160ms.
    final fadeDuration = AppMotion.of(context, const Duration(milliseconds: 160));
    if (fadeDuration == Duration.zero) {
      _fade.value = 0.0;
    } else {
      try {
        await _fade.animateTo(0.0, duration: fadeDuration, curve: Curves.easeOut).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted || _done) return;
    _done = true;
    widget.onDismissed();
  }

  Future<void> _close(BrowserTab tab) async {
    if (!_closing.add(tab.id)) return;
    setState(() {});
    // Let the card fade before the grid closes the gap.
    await Future<void>.delayed(AppMotion.of(context, AppMotion.quick));
    final closed = await widget.actions.close(tab.id);
    if (!mounted) return;
    setState(() {
      _closing.remove(tab.id);
      _closed = closed;
      _note = null;
    });
  }

  Future<void> _undo() async {
    final tab = _closed;
    if (tab == null) return;
    setState(() => _closed = null);
    final ok = await widget.actions.restore(tab);
    if (!ok && mounted) setState(() => _note = context.l10n.browserTabLimit);
  }

  Future<void> _newTab() async {
    await widget.actions.newTab();
    if (mounted) await leave();
  }

  Future<void> _closeAll(int count) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.browserCloseAllConfirm(count)),
        content: Text(l10n.browserCloseAllNote),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            key: const ValueKey('browser-close-all-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _closed = null);
    await widget.actions.closeAll();
    if (mounted) await leave();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final workspace = ref.watch(browserWorkspaceProvider);
    final tabs = workspace.tabsFor(widget.scope);
    final selected = workspace.selectedFor(widget.scope);
    final full =
        tabs.length >= BrowserWorkspaceController.maxTabsPerScope ||
        workspace.tabs.length >= BrowserWorkspaceController.maxTabs;
    final scale = (media.textScaler.scale(16) / 16).clamp(1.0, 2.0);
    final headerHeight = 56.0 + (scale - 1) * 16;
    final bottomHeight = 72.0 + media.viewPadding.bottom;

    // System back is the page's: it calls [leave].
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: l10n.browserTabs,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final inset = EdgeInsets.fromLTRB(
            media.padding.left,
            media.padding.top + headerHeight,
            media.padding.right,
            bottomHeight,
          );
          final grid = _Grid(size, inset, scale, tabs.length);
          final scroll = _scroll ??= ScrollController(
            initialScrollOffset: grid.reveal(tabs.indexWhere((t) => t.id == selected?.id)),
          );
          return AnimatedBuilder(
            animation: Listenable.merge([_t, _fade, scroll]),
            builder: (context, _) {
              final t = _t.value;
              final fade = _fade.value;
              final offset = scroll.hasClients ? scroll.offset : scroll.initialScrollOffset;
              final flying = t < 1 || _leaving;
              final index = tabs.indexWhere((tab) => tab.id == selected?.id);
              final flightTab = index < 0 ? null : tabs[index];
              final cardRect = index < 0 ? null : grid.card(index, offset);
              // When origin is empty (no live WebView) or showing 首页, the
              // target is the card's own center; never a degenerate rect.
              final hasOrigin = widget.origin.width > 1 && widget.origin.height > 1;
              final target = cardRect == null
                  ? (hasOrigin
                        ? Rect.fromCenter(center: widget.origin.center, width: grid.cardWidth, height: grid.thumb)
                        : Rect.fromLTWH(
                            size.width / 2 - grid.cardWidth / 2,
                            size.height / 2 - grid.thumb / 2,
                            grid.cardWidth,
                            grid.thumb,
                          ))
                  : grid.thumbOf(cardRect);
              final originRect = hasOrigin
                  ? widget.origin
                  : Rect.fromCenter(center: target.center, width: target.width * 0.9, height: target.height * 0.9);
              final chrome = const Interval(0.35, 1, curve: Curves.easeOut).transform(t);
              final backdrop = const Interval(0, 0.45, curve: Curves.easeOut).transform(t);
              return Stack(
                key: const ValueKey('browser-tabs-overview'),
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: backdrop * fade,
                        child: ColoredBox(color: scheme.surfaceContainerLow),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: _leaving || t < 0.5,
                      child: Opacity(
                        opacity: chrome * fade,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: _cards(
                                context,
                                grid: grid,
                                scroll: scroll,
                                tabs: tabs,
                                selected: selected?.id,
                                hidden: flying ? flightTab?.id : null,
                              ),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              height: inset.top,
                              child: _header(context, tabs.length, top: media.padding.top),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _bottom(context, tabs.length, full: full, gesture: media.viewPadding.bottom),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (flying && flightTab != null)
                    Positioned.fromRect(
                      rect: Rect.lerp(originRect, target, t)!,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: fade,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(lerpDouble(0, BrowserTabsOverview.radius, t)!),
                            child: BrowserTabFace(tab: flightTab, preview: widget.previews[flightTab.id]),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, int count, {required double top}) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, top, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  l10n.browserTabCount(count),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('browser-tabs-done'),
              onPressed: () => unawaited(leave()),
              child: Text(l10n.browserTabsDone),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottom(BuildContext context, int count, {required bool full, required double gesture}) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final closed = _closed;
    final note = _note ?? (full ? l10n.browserTabLimit : null);
    final small = theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 4, 8, math.max(gesture, 8)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (closed != null)
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${l10n.browserTabClosed} · ${closed.url == null ? l10n.browserHome : browserTitle(closed.title, closed.url!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('browser-tab-undo'),
                      onPressed: () => unawaited(_undo()),
                      child: Text(l10n.browserUndo),
                    ),
                  ],
                ),
              ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(note, style: small),
              ),
            if (ref.watch(browserWorkspaceProvider.select((s) => s.persistenceFailed)))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(l10n.browserTabsUnsaved, style: small),
              ),
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: count > 1
                          ? TextButton(
                              key: const ValueKey('browser-close-all'),
                              style: TextButton.styleFrom(foregroundColor: colors.danger),
                              onPressed: () => unawaited(_closeAll(count)),
                              child: Text(l10n.browserCloseAll, maxLines: 1, overflow: TextOverflow.ellipsis),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  Tooltip(
                    message: l10n.browserNewTab,
                    child: Semantics(
                      button: true,
                      enabled: !full,
                      label: l10n.browserNewTab,
                      excludeSemantics: true,
                      child: Opacity(
                        // Dimmed when full: the note above says why.
                        opacity: full ? 0.4 : 1,
                        // The theme's icon buttons are onSurfaceVariant: a
                        // filled key pairs primary with onPrimary itself.
                        child: IconButton.filled(
                          key: const ValueKey('browser-tabs-new'),
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            foregroundColor: Theme.of(context).colorScheme.onPrimary,
                            disabledBackgroundColor: Theme.of(context).colorScheme.primary,
                            disabledForegroundColor: Theme.of(context).colorScheme.onPrimary,
                            minimumSize: const Size.square(52),
                          ),
                          onPressed: full ? null : () => unawaited(_newTab()),
                          icon: const Icon(AppIcons.add, size: 24),
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cards(
    BuildContext context, {
    required _Grid grid,
    required ScrollController scroll,
    required List<BrowserTab> tabs,
    required String? selected,
    required String? hidden,
  }) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (tabs.isEmpty) {
      return Center(
        child: Text(
          l10n.browserNoTabs,
          style: theme.textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
        ),
      );
    }
    return GridView.builder(
      controller: scroll,
      padding: EdgeInsets.fromLTRB(grid.left, grid.top + _Grid.pad, grid.right, grid.bottom + _Grid.pad),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: grid.columns,
        mainAxisSpacing: _Grid.gap,
        crossAxisSpacing: _Grid.gap,
        mainAxisExtent: grid.cardHeight,
      ),
      itemCount: tabs.length,
      itemBuilder: (context, i) {
        final tab = tabs[i];
        return _TabCard(
          key: ValueKey('browser-tab-${tab.id}'),
          tab: tab,
          preview: widget.previews[tab.id],
          header: grid.header,
          selected: tab.id == selected,
          hidden: tab.id == hidden,
          closing: _closing.contains(tab.id),
          onOpen: () => unawaited(leave(pick: tab.id)),
          onClose: () => unawaited(_close(tab)),
        );
      },
    );
  }
}

/// One tab: its mark, title and a cross over the page's picture; the open
/// one outlined in the accent.
class _TabCard extends StatelessWidget {
  const _TabCard({
    super.key,
    required this.tab,
    required this.preview,
    required this.header,
    required this.selected,
    required this.hidden,
    required this.closing,
    required this.onOpen,
    required this.onClose,
  });

  final BrowserTab tab;
  final BrowserTabPreview? preview;
  final double header;
  final bool selected;

  /// Its picture is in flight: the card shows only its frame.
  final bool hidden;
  final bool closing;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final url = tab.url;
    final title = url == null ? l10n.browserHome : browserTitle(tab.title, url);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(BrowserTabsOverview.radius + 4),
      side: selected
          ? BorderSide(color: scheme.primary, width: 2)
          : BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6), width: 0.75),
    );
    return AnimatedOpacity(
      opacity: closing ? 0 : 1,
      duration: AppMotion.of(context, AppMotion.quick),
      child: AnimatedScale(
        scale: closing ? 0.92 : 1,
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.exit,
        child: Semantics(
          selected: selected,
          button: true,
          label: url == null ? title : '$title, ${browserSite(url)}',
          onTap: onOpen,
          child: Material(
            color: scheme.surface,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            elevation: selected ? 2 : 0.5,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            child: InkWell(
              onTap: onOpen,
              excludeFromSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: header,
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        BrowserSiteMark(url: url, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: ExcludeSemantics(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: selected ? scheme.primary : scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                        Tooltip(
                          message: l10n.browserCloseTab,
                          child: Semantics(
                            button: true,
                            label: l10n.browserCloseTab,
                            onTap: onClose,
                            excludeSemantics: true,
                            child: InkResponse(
                              onTap: onClose,
                              radius: 20,
                              child: SizedBox(
                                width: 40,
                                height: header,
                                child: Icon(AppIcons.close, size: 16, color: colors.textTertiary),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                      child: Opacity(
                        opacity: hidden ? 0 : 1,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(BrowserTabsOverview.radius),
                          child: BrowserTabFace(tab: tab, preview: preview),
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
    );
  }
}

/// A tab's picture: its last snapshot while it is still on that address; a
/// drawn 首页 for a home tab; else the site's mark, title and host — nothing
/// made up about the page's content.
class BrowserTabFace extends StatelessWidget {
  const BrowserTabFace({super.key, required this.tab, this.preview});

  final BrowserTab tab;
  final BrowserTabPreview? preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final url = tab.url;
    final preview = this.preview;
    Widget face;
    if (url == null) {
      face = const Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(padding: EdgeInsets.all(12), child: BrowserWordmark(size: 22)),
        ),
      );
    } else if (preview != null && preview.shows(tab)) {
      face = Image(
        key: const ValueKey('browser-tab-preview'),
        image: preview.image,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => _Site(url: url, title: tab.title),
      );
    } else {
      face = _Site(url: url, title: tab.title);
    }
    return ExcludeSemantics(
      child: ColoredBox(
        color: url == null ? scheme.surfaceContainerLowest : colors.textTertiary.withValues(alpha: 0.04),
        child: SizedBox.expand(child: face),
      ),
    );
  }
}

class _Site extends StatelessWidget {
  const _Site({required this.url, required this.title});

  final Uri url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final name = browserTitle(title, url);
    final site = browserSite(url);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Center(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BrowserSiteMark(url: url, size: 40),
              const SizedBox(height: 10),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
              ),
              if (name != site) ...[
                const SizedBox(height: 2),
                Text(
                  site,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
