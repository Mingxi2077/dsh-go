// 返回会话按钮，第五项工具栏按钮带任务状态指示器。右上角显示运行中的细线加载环或完成的蓝点。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_conversation_activity.dart';
import '../../l10n/l10n.dart';
import '../../state/notify_state.dart' show appForegroundProvider;
import '../theme/app_icons.dart';

/// 返回会话工具按钮，带运行中 / 完成状态标记。
class BrowserConversationButton extends ConsumerStatefulWidget {
  const BrowserConversationButton({
    super.key,
    required this.target,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final BrowserConversationTarget target;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  ConsumerState<BrowserConversationButton> createState() => _BrowserConversationButtonState();
}

class _BrowserConversationButtonState extends ConsumerState<BrowserConversationButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinController = AnimationController(
    duration: const Duration(milliseconds: 1200),
    vsync: this,
  );

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activity = ref.watch(browserConversationActivityProvider(widget.target));
    final scheme = Theme.of(context).colorScheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final appForeground = ref.watch(appForegroundProvider);
    final l10n = context.l10n;

    final shouldSpin =
        activity == BrowserConversationActivity.running &&
        widget.active &&
        !reducedMotion &&
        tickerEnabled &&
        appForeground;

    if (shouldSpin && !_spinController.isAnimating) {
      _spinController.repeat();
    } else if (!shouldSpin && _spinController.isAnimating) {
      _spinController.stop();
      _spinController.reset();
    }

    final color = scheme.onSurface;
    final isDark = scheme.brightness == Brightness.dark;
    final indicatorColor = isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    final String tooltipMessage;
    final String semanticLabel;
    switch (activity) {
      case BrowserConversationActivity.running:
        tooltipMessage = l10n.browserReturnToChatRunning;
        semanticLabel = l10n.browserReturnToChatRunning;
        break;
      case BrowserConversationActivity.completed:
        tooltipMessage = l10n.browserReturnToChatCompleted;
        semanticLabel = l10n.browserReturnToChatCompleted;
        break;
      case BrowserConversationActivity.idle:
        tooltipMessage = widget.tooltip;
        semanticLabel = widget.tooltip;
        break;
    }

    return Tooltip(
      message: tooltipMessage,
      child: Semantics(
        button: true,
        enabled: true,
        label: semanticLabel,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            onTap: widget.onPressed,
            radius: 22,
            child: SizedBox.square(
              dimension: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(AppIcons.chat, size: 22, color: color),
                  if (activity == BrowserConversationActivity.running)
                    Positioned(
                      key: const ValueKey('browser-conversation-running'),
                      right: 3,
                      top: 3,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surface),
                        child: Center(
                          child: SizedBox.square(
                            dimension: 11,
                            child: reducedMotion
                                ? _LoadingRing(color: indicatorColor)
                                : RotationTransition(
                                    key: const ValueKey('browser-conversation-spin'),
                                    turns: _spinController,
                                    child: _LoadingRing(color: indicatorColor),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  if (activity == BrowserConversationActivity.completed)
                    Positioned(
                      key: const ValueKey('browser-conversation-completed'),
                      right: 3,
                      top: 3,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surface),
                        child: Center(
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: indicatorColor),
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

/// 细线加载环(运行中)。
class _LoadingRing extends StatelessWidget {
  const _LoadingRing({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _LoadingRingPainter(color: color));
  }
}

class _LoadingRingPainter extends CustomPainter {
  _LoadingRingPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    // 绘制 270 度弧
    const startAngle = -3.14159 / 2;
    const sweepAngle = 3.14159 * 1.5;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 0.75), startAngle, sweepAngle, false, paint);
  }

  @override
  bool shouldRepaint(_LoadingRingPainter oldDelegate) => oldDelegate.color != color;
}
