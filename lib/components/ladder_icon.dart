part of 'components.dart';

/// 一把梯子。
///
/// Material 里没有梯子：`Icons.stairs` 画的是四层台阶，`Icons.swap_vert`
/// 是两个箭头，都不像「翻过去」用的那个东西。内置代理的开关用它当图标，
/// 所以干脆自己画：两根竖杆 + 四根横档，和 Material 的线性图标同一套视觉
/// （2px 描边、圆头、24 格画布）。
///
/// 开启状态不换形状、只加粗：顶栏的图标都吃 `onSurface@0.86` 这一档前景色，
/// 换成实心块会和旁边几颗完全不是一套。
class LadderIcon extends StatelessWidget {
  const LadderIcon({
    super.key,
    this.size = 22,
    required this.color,
    this.on = false,
  });

  final double size;

  final Color color;

  /// 代理开着时描边加粗一点。
  final bool on;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LadderPainter(color: color, on: on),
      ),
    );
  }
}

class _LadderPainter extends CustomPainter {
  _LadderPainter({required this.color, required this.on});

  final Color color;

  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = color
      ..strokeWidth = w * (on ? 0.13 : 0.10)
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 竖杆略微内收，横档才不会顶到画布边缘（Material 图标的留白习惯）。
    final left = w * 0.31;
    final right = w * 0.69;
    final top = h * 0.10;
    final bottom = h * 0.90;

    canvas.drawLine(Offset(left, top), Offset(left, bottom), paint);
    canvas.drawLine(Offset(right, top), Offset(right, bottom), paint);

    const rungs = 4;
    for (var i = 0; i < rungs; i++) {
      final y = top + (bottom - top) * (i / (rungs - 1));
      canvas.drawLine(Offset(left, y), Offset(right, y), paint);
    }
  }

  @override
  bool shouldRepaint(_LadderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.on != on;
}
