import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/foundation/achievements.dart';

/// 成就徽章。
///
/// 六边形金属牌 + 内圈凹槽 + 档位星标，越高的档颜色越亮、外发光越强、
/// 底部的星标越多。四档共用同一套画法，所以从青铜升到白银时形状不变、
/// 材质和星标变了，一眼能看出「升了一级」而不是「换了一个图标」。
///
/// 未点亮时是灰底描边、图标半透明——同一套几何形状，所以锁着的徽章也
/// 能看出将来长什么样。
class AchievementBadge extends StatelessWidget {
  const AchievementBadge({
    super.key,
    required this.icon,
    required this.tier,
    this.size = 56,
    this.ratio,
    this.glow = true,
  });

  final IconData icon;

  final AchievementTier tier;

  final double size;

  /// 距下一档的进度（0-1）。传 null 不画进度环。
  final double? ratio;

  /// 是否画外发光（列表里关掉更省，详情里打开更漂亮）。
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lockedStroke = colors.onSurfaceVariant.withValues(alpha: 0.28);
    final lockedFill = colors.surfaceContainerHighest.withValues(alpha: 0.55);
    final railColor = colors.onSurface.withValues(alpha: 0.10);

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BadgePainter(
          tier: tier,
          ratio: ratio,
          lockedFill: lockedFill,
          lockedStroke: lockedStroke,
          railColor: railColor,
          glow: glow,
        ),
        child: Center(
          child: Icon(
            icon,
            size: size * 0.36,
            color: tier.isUnlocked
                ? tier.onBadge
                : colors.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }
}

class _BadgePainter extends CustomPainter {
  _BadgePainter({
    required this.tier,
    required this.ratio,
    required this.lockedFill,
    required this.lockedStroke,
    required this.railColor,
    required this.glow,
  });

  final AchievementTier tier;
  final double? ratio;
  final Color lockedFill;
  final Color lockedStroke;
  final Color railColor;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    // 留一圈给进度环和发光，所以徽章本体只占 0.78。
    final radius = side * 0.39;
    final path = _hexPath(center, radius);
    final unlocked = tier.isUnlocked;

    if (unlocked && glow) {
      canvas.drawPath(
        path,
        Paint()
          ..color = tier.glow.withValues(alpha: 0.30)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, side * 0.10),
      );
    }

    if (!unlocked) {
      canvas.drawPath(path, Paint()..color = lockedFill);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = lockedStroke,
      );
      _paintProgress(canvas, center, side, Colors.transparent);
      return;
    }

    // 金属本体：左上高光 → 本体色 → 右下暗部
    final body = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [tier.light, tier.base, tier.deep],
        stops: const [0.0, 0.52, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawPath(path, body);

    // 上半部再叠一层白色反光，金属感靠这一层
    canvas.save();
    canvas.clipPath(path);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.52),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.34),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.52)),
    );
    canvas.restore();

    // 外描边 + 内圈凹槽
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.022
        ..color = Colors.white.withValues(alpha: 0.55),
    );
    final innerPath = _hexPath(
      center.translate(0, side * 0.012),
      radius * 0.74,
    );
    canvas.drawPath(
      innerPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.016
        ..color = Colors.white.withValues(alpha: 0.30),
    );

    _paintTierMarks(canvas, center, radius);
    _paintProgress(canvas, center, side, tier.glow);
  }

  /// 六边形：尖角朝上，像一枚挂着的奖牌。
  Path _hexPath(Offset center, double radius) {
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final angle = -math.pi / 2 + i * math.pi / 3;
      final point = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  /// 档位星标：青铜 0 颗，之后每档多一颗，画在徽章下沿。
  void _paintTierMarks(Canvas canvas, Offset center, double radius) {
    final count = tier.index - 1;
    if (count <= 0) {
      return;
    }
    final starSize = radius * 0.15;
    final gap = starSize * 2.3;
    final startX = center.dx - gap * (count - 1) / 2;
    final y = center.dy + radius * 0.62;
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.85);
    for (var i = 0; i < count; i++) {
      _drawStar(canvas, Offset(startX + gap * i, y), starSize, paint);
    }
  }

  void _drawStar(Canvas canvas, Offset center, double radius, Paint paint) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final angle = -math.pi / 2 + i * math.pi / 4;
      final r = i.isEven ? radius : radius * 0.36;
      final point = Offset(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(path..close(), paint);
  }

  /// 外圈进度：从正上方顺时针走到下一档。
  void _paintProgress(Canvas canvas, Offset center, double side, Color color) {
    final value = ratio;
    if (value == null) {
      return;
    }
    final radius = side * 0.46;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.035
        ..color = railColor,
    );
    if (value <= 0) {
      return;
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * value.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.035
        ..strokeCap = StrokeCap.round
        ..color = color == Colors.transparent ? lockedStroke : color,
    );
  }

  @override
  bool shouldRepaint(_BadgePainter oldDelegate) {
    return oldDelegate.tier != tier ||
        oldDelegate.ratio != ratio ||
        oldDelegate.lockedFill != lockedFill ||
        oldDelegate.railColor != railColor;
  }
}
