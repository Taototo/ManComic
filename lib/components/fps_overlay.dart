import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:venera/foundation/display_refresh.dart';

/// 右下角的帧率读数（诊断用，设置里可以打开）。
///
/// 只统计，不干预渲染。数值来自 [SchedulerBinding.addTimingsCallback]：
/// 拿的是引擎实际提交的每一帧，所以屏幕上看到多少就是多少，不受 UI 线程
/// 自己"以为"的帧率影响。
///
/// 显示三项：
/// - `fps`：最近 0.5 秒内实际出帧数 / 时长
/// - `b` / `r`：这一窗口内 build（UI 线程）与 raster（GPU）的平均耗时
/// - `jank`：超过屏幕刷新周期 1.5 倍的帧数，掉帧主要看它
class FpsOverlay extends StatefulWidget {
  const FpsOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<FpsOverlay> createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<FpsOverlay> {
  static const _window = Duration(milliseconds: 500);

  final _stats = ValueNotifier<_Stats>(_Stats.empty);

  Timer? _timer;

  int _frames = 0;
  int _jank = 0;
  double _buildSum = 0;
  double _rasterSum = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(_window, (_) => _flush());
  }

  @override
  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _stats.dispose();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    // 屏幕刷新率可能在运行中被系统改掉（省电模式、切后台），每帧都取一次。
    final budget = 1000000 / DisplayRefresh.refreshRate;
    for (final t in timings) {
      _frames++;
      final build = t.buildDuration.inMicroseconds.toDouble();
      final raster = t.rasterDuration.inMicroseconds.toDouble();
      _buildSum += build;
      _rasterSum += raster;
      if (t.totalSpan.inMicroseconds > budget * 1.5) {
        _jank++;
      }
    }
  }

  void _flush() {
    if (!mounted) return;
    final frames = _frames;
    if (frames == 0) {
      // 静止画面时引擎不出帧，这不是卡住，显示为空即可。
      _stats.value = _Stats.empty;
      return;
    }
    _stats.value = _Stats(
      fps: frames / (_window.inMilliseconds / 1000),
      buildMs: _buildSum / frames / 1000,
      rasterMs: _rasterSum / frames / 1000,
      jank: _jank,
    );
    _frames = 0;
    _jank = 0;
    _buildSum = 0;
    _rasterSum = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        Positioned(
          right: 8,
          bottom: MediaQuery.of(context).padding.bottom + 72,
          child: IgnorePointer(
            child: ValueListenableBuilder<_Stats>(
              valueListenable: _stats,
              builder: (context, stats, _) {
                if (stats.isEmpty) return const SizedBox.shrink();
                return _Badge(stats: stats);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _Stats {
  const _Stats({
    required this.fps,
    required this.buildMs,
    required this.rasterMs,
    required this.jank,
  });

  static const empty = _Stats(fps: 0, buildMs: 0, rasterMs: 0, jank: 0);

  final double fps;
  final double buildMs;
  final double rasterMs;
  final int jank;

  bool get isEmpty => fps == 0;
}

class _Badge extends StatelessWidget {
  const _Badge({required this.stats});

  final _Stats stats;

  @override
  Widget build(BuildContext context) {
    // 目标帧率取屏幕刷新率；达到 90% 算流畅，低于 75% 标红。
    final target = DisplayRefresh.refreshRate;
    final ratio = target <= 0 ? 1.0 : stats.fps / target;
    final color = ratio >= 0.9
        ? const Color(0xFF4ADE80)
        : ratio >= 0.75
            ? const Color(0xFFFBBF24)
            : const Color(0xFFF87171);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            "${stats.fps.toStringAsFixed(0)} fps",
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            "b ${stats.buildMs.toStringAsFixed(1)} · r ${stats.rasterMs.toStringAsFixed(1)} ms",
            style: const TextStyle(
              color: Color(0xFFE5E7EB),
              fontSize: 10,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (stats.jank > 0)
            Text(
              "${stats.jank} jank",
              style: const TextStyle(
                color: Color(0xFFF87171),
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}
