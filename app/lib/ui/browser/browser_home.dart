// 首页: a native page, no WebView. One real search box in the middle, the
// Dsh-Go wordmark above it and bookmarks (a few well-known sites while there
// are none) with their icons below. Tapping the box focuses that same field
// (it is never rebuilt, so the IME and Chinese composing survive): it glides
// down to sit above the keyboard while the wordmark and bookmarks fade out
// and this phone's recent history fades in above it; typing turns the history
// into suggestions. Leaving edit plays it back. (Spatial reference: Quark's
// home → search, 0.4–1.0 s; see docs/design/browser-motion-refresh.md.)

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_library.dart';
import '../../browser/browser_workspace.dart';
import '../../l10n/l10n.dart';
import '../../pets/pet_signals.dart';
import '../../pets/pet_state.dart';
import '../common/list_page_row.dart';
import '../common/pressable.dart';
import '../features/all_features_page.dart' show FeatureGroupLabel;
import '../pets/pet_sprite.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_site.dart';
import 'browser_suggestions.dart';

/// A shortcut on the home page.
typedef BrowserShortcut = ({String title, Uri url});

/// What the home page offers before there are any bookmarks.
List<BrowserShortcut> browserDefaultShortcuts(L10n l10n) => [
  (title: l10n.browserSiteGithub, url: Uri.parse('https://github.com/ccch1mneyyy/dsh-go')),
  (title: l10n.browserEngineBing, url: Uri.parse('https://www.bing.com/')),
  (title: l10n.browserSiteWikipedia, url: Uri.parse('https://www.wikipedia.org/')),
];

/// The 首页 wordmark: "Dsh", a short glowing bar, and "Go", all in a unified
/// accent gradient. Drawn in code, no images.
class BrowserWordmark extends StatelessWidget {
  const BrowserWordmark({super.key, this.size = 40});

  /// The letters' size.
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = DshSurfaces.of(context);
    final dark = theme.brightness == Brightness.dark;
    final baseStyle = TextStyle(fontSize: size, height: 1, fontWeight: FontWeight.w800, letterSpacing: -size * 0.045);
    final accent = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [scheme.primary, Color.lerp(scheme.primary, surfaces.glowSecondary, dark ? 0.35 : 0.55)!],
    );
    return Semantics(
      header: true,
      label: 'Dsh-Go',
      excludeSemantics: true,
      // A brand mark keeps its size: it never wraps on a narrow phone.
      child: MediaQuery.withNoTextScaling(
        child: ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: accent.createShader,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('Dsh', maxLines: 1, style: baseStyle.copyWith(color: Colors.white)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: size * 0.12),
                child: Container(
                  width: size * 0.32,
                  height: size * 0.11,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(size),
                    boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: size * 0.2)],
                  ),
                ),
              ),
              Text('Go', maxLines: 1, style: baseStyle.copyWith(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

class BrowserHome extends ConsumerStatefulWidget {
  const BrowserHome({
    super.key,
    required this.scope,
    required this.field,
    required this.editing,
    required this.input,
    required this.bottomReserve,
    this.knownKeyboard,
    required this.onSearch,
    required this.onOpen,
    required this.onPick,
    required this.onOpenTab,
    required this.onHistory,
    this.active = true,
  });

  final BrowserScope scope;

  /// The one address field (its TextField), placed in the box by the page.
  final Widget field;

  /// The field has focus: the box sits above the keyboard.
  final bool editing;

  /// Page is visible and not covered (e.g., by tab overview).
  final bool active;

  /// What is typed (history while empty, suggestions after).
  final ValueListenable<TextEditingValue> input;

  /// Room the page's bottom capsule takes while not editing.
  final double bottomReserve;

  /// The height the keyboard came to rest at last time in a window this
  /// wide (null: not known yet).
  final double? knownKeyboard;

  /// Focus the field.
  final VoidCallback onSearch;

  /// Go to an address in this tab (a bookmark).
  final ValueChanged<Uri> onOpen;

  /// A suggestion or a recent page, picked while editing.
  final ValueChanged<Uri> onPick;

  /// Switch to an open page.
  final ValueChanged<String> onOpenTab;

  /// 全部历史.
  final VoidCallback onHistory;

  /// Shortcuts shown at most.
  static const shortcuts = 8;

  /// Recent pages shown while editing at most.
  static const recent = 8;

  /// The box's height at text size 1.
  static const box = 52.0;

  /// Gap between the box and the keyboard.
  static const keyboardGap = 12.0;

  /// Before any keyboard was seen: its share of the screen's height.
  static const guessKeyboard = 0.4;

  /// To the keyboard, and back (Quark's box takes about half a second).
  static const enter = Duration(milliseconds: 420);
  static const leave = Duration(milliseconds: 360);

  /// The pet sprite's body height (logical pixels) at rest.
  static const petHeight = 36.0;

  @override
  ConsumerState<BrowserHome> createState() => _BrowserHomeState();
}

class _BrowserHomeState extends ConsumerState<BrowserHome> with SingleTickerProviderStateMixin {
  /// 0: at rest; 1: editing. Linear in time; each part shapes it itself.
  late final AnimationController _t = AnimationController(vsync: this, value: widget.editing ? 1 : 0);

  /// Wordmark and bookmarks: out over the first 70% (in over the last 70%
  /// back). History: in over the last 70%. Whole fades, never cut short.
  late final Animation<double> _stay = ReverseAnimation(
    CurvedAnimation(
      parent: _t,
      curve: const Interval(0, 0.7, curve: Curves.easeOut),
    ),
  );
  late final Animation<double> _come = CurvedAnimation(
    parent: _t,
    curve: const Interval(0.3, 1, curve: Curves.easeOut),
  );

  @override
  void didUpdateWidget(BrowserHome old) {
    super.didUpdateWidget(old);
    if (old.editing != widget.editing) {
      // From wherever it is now: a quick tap back mid-way turns it around.
      final duration = widget.editing ? BrowserHome.enter : BrowserHome.leave;
      _t.animateTo(widget.editing ? 1 : 0, duration: AppMotion.of(context, duration), curve: Curves.linear);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  Widget _reach({required bool on, required Widget child}) => IgnorePointer(
    ignoring: !on,
    child: ExcludeSemantics(excluding: !on, child: child),
  );

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing;
    // Built once per change of state, not per frame: the layout below only
    // moves them, and the fades only repaint.
    return _HomeLayout(
      key: const ValueKey('browser-home'),
      t: _t,
      editing: editing,
      knownKeyboard: widget.knownKeyboard,
      bottomReserve: widget.bottomReserve,
      lower: _reach(
        on: !editing,
        child: FadeTransition(
          opacity: _stay,
          child: _Lower(scope: widget.scope, onOpen: widget.onOpen, onOpenTab: widget.onOpenTab),
        ),
      ),
      logo: _reach(
        on: !editing,
        child: FadeTransition(
          opacity: _stay,
          child: const Center(child: BrowserWordmark()),
        ),
      ),
      pet: _reach(
        on: !editing,
        child: FadeTransition(
          opacity: _stay,
          child: Center(child: _HomePet(paused: editing || !widget.active)),
        ),
      ),
      above: _reach(
        on: editing,
        child: FadeTransition(
          opacity: _come,
          child: _Above(input: widget.input, onPick: widget.onPick, onHistory: widget.onHistory),
        ),
      ),
      box: BrowserSearchBox(onTap: widget.onSearch, child: widget.field),
    );
  }
}

/// Where the parts of 首页 are at [t]. The box glides from where it really
/// is to above where the keyboard will be (the height it came to last time,
/// or a fair guess before any; never the 0 of a keyboard not up yet),
/// widening and growing a little. A keyboard taller than that lifts it as it
/// rises; a closing one never drags it down: the box keeps its seat until
/// the edit ends, then glides back. Only this rebuilds per frame, and only
/// positions: its children come built from the home page.
class _HomeLayout extends StatefulWidget {
  const _HomeLayout({
    super.key,
    required this.t,
    required this.editing,
    required this.knownKeyboard,
    required this.bottomReserve,
    required this.lower,
    required this.logo,
    required this.pet,
    required this.above,
    required this.box,
  });

  final Animation<double> t;
  final bool editing;
  final double? knownKeyboard;
  final double bottomReserve;
  final Widget lower, logo, pet, above, box;

  @override
  State<_HomeLayout> createState() => _HomeLayoutState();
}

class _HomeLayoutState extends State<_HomeLayout> with SingleTickerProviderStateMixin {
  /// Controls the keyboard seat height, so a better idea of it eases over
  /// without rebuilding the TextField.
  late final AnimationController _keyboardSeat = AnimationController.unbounded(vsync: this, value: 0);

  Timer? _stableTimer;
  double _lastLive = 0;
  bool _hasStable = false;
  bool _closing = false;
  double _targetSeat = 0;
  bool _initialized = false;

  void _beginEdit() {
    _stableTimer?.cancel();
    _stableTimer = null;
    _lastLive = 0;
    _hasStable = false;
    _closing = false;
    final size = MediaQuery.sizeOf(context);
    final live = MediaQuery.viewInsetsOf(context).bottom;
    final predicted = (live > 0) ? live : (widget.knownKeyboard ?? size.height * BrowserHome.guessKeyboard);
    _keyboardSeat.stop();
    _keyboardSeat.value = predicted;
    _targetSeat = predicted;
    _initialized = true;

    // If live > 0, start tracking for stable correction.
    if (live > 0) {
      _updateSeat();
    }
  }

  void _updateSeat() {
    if (!widget.editing) {
      _stableTimer?.cancel();
      _stableTimer = null;
      _keyboardSeat.stop();
      return;
    }

    final live = MediaQuery.viewInsetsOf(context).bottom;

    // Same live as last call: no-op (don't restart timer or re-animate).
    if ((live - _lastLive).abs() < 0.1) return;

    if (live > 0) {
      // Keyboard rising or changed: reset stable timer, keep predicted seat.
      if (_hasStable && live < _lastLive - 1) {
        // Keyboard dropping after stable: freeze at current seat, mark closing.
        _closing = true;
        _stableTimer?.cancel();
        _stableTimer = null;
        _keyboardSeat.stop();
        _lastLive = live;
        return;
      }

      if (_closing) {
        // Already closing, ignore further drops.
        _lastLive = live;
        return;
      }

      // Cancel any pending stable timer.
      _stableTimer?.cancel();

      // Start 80ms stable timer.
      _stableTimer = Timer(const Duration(milliseconds: 80), () {
        if (!mounted || !widget.editing) return;
        final current = MediaQuery.viewInsetsOf(context).bottom;
        if ((current - live).abs() < 0.1) {
          // Stable at this height: animate seat to actual live.
          _hasStable = true;
          if ((live - _targetSeat).abs() > 1) {
            _keyboardSeat.stop();
            _targetSeat = live;
            _keyboardSeat.animateTo(live, duration: AppMotion.of(context, AppMotion.standard), curve: AppMotion.std);
          }
        }
      });

      _lastLive = live;
    } else {
      // Keyboard at 0: cancel timer and stop regardless of hasStable.
      _stableTimer?.cancel();
      _stableTimer = null;
      _keyboardSeat.stop();
      _lastLive = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.editing && !_initialized) {
      _beginEdit();
    } else if (widget.editing) {
      _updateSeat();
    }
  }

  @override
  void didUpdateWidget(_HomeLayout old) {
    super.didUpdateWidget(old);
    if (widget.editing && !old.editing) {
      // Entering edit: initialize state, snap to predicted seat.
      _beginEdit();
    } else if (widget.editing) {
      _updateSeat();
    } else if (!widget.editing && old.editing) {
      // Exiting edit: cancel timer, stop seat (stays put for glide back).
      _stableTimer?.cancel();
      _stableTimer = null;
      _keyboardSeat.stop();
      _initialized = false;
    }
    // On exit (!widget.editing), _keyboardSeat stays put so the box glides
    // back from where it is.
  }

  @override
  void dispose() {
    _stableTimer?.cancel();
    _keyboardSeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gesture = MediaQuery.viewPaddingOf(context).bottom;
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final boxHeight = (BrowserHome.box + (scale - 1) * 24).clamp(BrowserHome.box, 68.0);
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: Listenable.merge([widget.t, _keyboardSeat]),
        builder: (context, _) => _layout(constraints.biggest, _keyboardSeat.value, gesture, boxHeight, widget.t.value),
      ),
    );
  }

  Widget _layout(Size size, double keyboard, double gesture, double boxHeight, double t) {
    final height = size.height;
    final width = size.width;
    final move = Curves.easeInOutCubic.transform(t);
    final restSide = math.max(24.0, (width - 560) / 2);
    final editSide = math.max(12.0, (width - 600) / 2);
    final side = lerpDouble(restSide, editSide, move)!;
    final box = boxHeight + 6 * move;
    const logo = 64.0;
    const petSlotHeight = BrowserHome.petHeight + 12;
    final rest = height - widget.bottomReserve;
    // Box position: a little above middle, always leaving logo, pet slot, and gaps room.
    final restTop = math
        .max(logo + 36 + petSlotHeight + 10, rest * 0.36 - boxHeight / 2)
        .clamp(0.0, math.max(0.0, rest - boxHeight));
    final editTop = math.max(0.0, height - math.max(keyboard, gesture) - boxHeight - 6 - BrowserHome.keyboardGap);
    final top = lerpDouble(restTop, editTop, move)!;
    // Pet slot: bottom edge is at restTop - 10 (gap above search box).
    final petSlotBottom = restTop - 10;
    final petTop = petSlotBottom - petSlotHeight;
    return Stack(
      children: [
        // Below the box: bookmarks and open pages, drifting down as they fade.
        Positioned(
          left: 0,
          right: 0,
          top: restTop + boxHeight + 20 + 24 * move,
          height: math.max(0.0, rest - restTop - boxHeight - 20),
          child: widget.lower,
        ),
        Positioned(
          left: restSide,
          right: restSide,
          top: petTop - logo - 16 + 12 * move,
          height: logo,
          child: widget.logo,
        ),
        // Pet strictly between logo and search box, with clear bottom gap.
        Positioned(left: restSide, right: restSide, top: petTop + 8 * move, height: petSlotHeight, child: widget.pet),
        // Above the box while editing: history, then suggestions, settling
        // 8 down into place as they come.
        Positioned(left: 0, right: 0, top: -8 * (1 - move), height: math.max(0, top - 8), child: widget.above),
        Positioned(left: side, right: side, top: top, height: box, child: widget.box),
      ],
    );
  }
}

/// The home search box: rounded, a hairline, a soft shadow cast down and a
/// touch to the right as from a light above-left, and a faint top highlight.
class BrowserSearchBox extends StatelessWidget {
  const BrowserSearchBox({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final shadow = dark ? Colors.black : const Color(0xFF1B2440);
    const radius = BorderRadius.all(Radius.circular(AppShape.lg));
    return DecoratedBox(
      key: const ValueKey('browser-home-search'),
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: shadow.withValues(alpha: dark ? 0.42 : 0.10),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(2, 10),
          ),
          BoxShadow(
            color: shadow.withValues(alpha: dark ? 0.30 : 0.06),
            blurRadius: 4,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: dark ? 0.55 : 0.7), width: 0.75),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? [scheme.surfaceContainerHigh, scheme.surfaceContainer]
                  : [
                      scheme.surfaceContainerLowest,
                      Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.015), scheme.surfaceContainerLowest),
                    ],
            ),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            // The field takes the taps on itself; the rim around it focuses.
            excludeFromSemantics: true,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(AppIcons.search, size: 20, color: colors.textTertiary),
                const SizedBox(width: 8),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bookmarks, then the conversation's other open pages.
class _Lower extends ConsumerWidget {
  const _Lower({required this.scope, required this.onOpen, required this.onOpenTab});

  final BrowserScope scope;
  final ValueChanged<Uri> onOpen;
  final ValueChanged<String> onOpenTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final library = ref.watch(browserLibraryProvider);
    final workspace = ref.watch(browserWorkspaceProvider);
    final open = [
      for (final tab in workspace.tabsFor(scope))
        if (tab.url != null) tab,
    ];
    final List<BrowserShortcut> marks = library.bookmarks.isEmpty
        ? browserDefaultShortcuts(l10n)
        : [
            for (final b in library.bookmarks.take(BrowserHome.shortcuts))
              (title: browserTitle(b.title, b.url), url: b.url),
          ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (library.loaded) _Shortcuts(marks: marks, onOpen: onOpen),
        if (open.isNotEmpty) ...[
          FeatureGroupLabel(l10n.browserOpenPages),
          ListPageCard(
            children: [
              for (final tab in open)
                ListPageRow(
                  key: ValueKey('browser-home-tab-${tab.id}'),
                  leading: BrowserSiteMark(url: tab.url, size: 28),
                  title: browserTitle(tab.title, tab.url!),
                  subtitle: browserSite(tab.url!),
                  onTap: () => onOpenTab(tab.id),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// While editing: suggestions for what is typed, else recent history.
class _Above extends ConsumerWidget {
  const _Above({required this.input, required this.onPick, required this.onHistory});

  final ValueListenable<TextEditingValue> input;
  final ValueChanged<Uri> onPick;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final history = ref.watch(browserLibraryProvider.select((s) => s.history)).take(BrowserHome.recent).toList();
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: input,
      builder: (context, value, _) {
        if (value.text.trim().isNotEmpty) return BrowserSuggestions(input: value.text, onOpen: onPick);
        if (history.isEmpty) return const SizedBox.shrink();
        return ListView(
          key: const ValueKey('browser-home-recent'),
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          children: [
            FeatureGroupLabel(l10n.browserRecent),
            ListPageCard(
              children: [
                for (final entry in history)
                  ListPageRow(
                    key: ValueKey('browser-home-recent-${entry.id}'),
                    leading: BrowserSiteMark(url: entry.url, size: 28),
                    title: browserTitle(entry.title, entry.url),
                    subtitle: browserSite(entry.url),
                    chevron: false,
                    onTap: () => onPick(entry.url),
                  ),
                ListPageRow(
                  key: const ValueKey('browser-home-history'),
                  icon: AppIcons.history,
                  title: l10n.browserAllHistory,
                  onTap: onHistory,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Bookmarks as a grid of marks with their names, four across on a phone.
class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.marks, required this.onOpen});

  final List<BrowserShortcut> marks;
  final ValueChanged<Uri> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final across = (constraints.maxWidth / 84).floor().clamp(3, 6);
          final width = constraints.maxWidth / across;
          return Wrap(
            alignment: marks.length < across ? WrapAlignment.center : WrapAlignment.start,
            children: [
              for (final mark in marks)
                SizedBox(
                  width: width,
                  child: Pressable(
                    onTap: () => onOpen(mark.url),
                    semanticLabel: mark.title,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BrowserSiteMark(url: mark.url, size: 48),
                          const SizedBox(height: 8),
                          Text(
                            mark.title,
                            key: ValueKey('browser-shortcut-${mark.url}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Deepy 小鲸鱼 sprite shown between the logo and search box on the home page.
/// Plays idle animation with reduced motion and pause support. No user
/// interaction or state changes.
class _HomePet extends ConsumerWidget {
  const _HomePet({required this.paused});

  final bool paused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packAsync = ref.watch(petPackProvider('deepy-whale'));
    final pack = packAsync.value;
    if (pack == null) return const SizedBox.shrink();

    final anim = pack.animFor(PetStateName.idle);
    final box = anim.box;
    final canvas = pack.canvas;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    // Target body height in dp: BrowserHome.petHeight.
    const targetHeight = BrowserHome.petHeight;
    // Integer device pixel scale: k = max(1, round(targetHeight * dpr / box.height)).
    final k = math.max(1, (targetHeight * dpr / box.height).round());
    final scale = k / dpr;

    final bodyWidth = box.width * scale;
    final bodyHeight = box.height * scale;
    final canvasWidth = canvas.width * scale;
    final canvasHeight = canvas.height * scale;

    return RepaintBoundary(
      child: SizedBox(
        width: bodyWidth,
        height: bodyHeight,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: -box.left * scale,
              top: -box.top * scale,
              width: canvasWidth,
              height: canvasHeight,
              child: PetSprite(pack: pack, anim: anim, scale: scale, paused: paused),
            ),
          ],
        ),
      ),
    );
  }
}
