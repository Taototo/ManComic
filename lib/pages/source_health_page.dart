import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/source_health.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/translations.dart';

/// 漫画源体检：并发探测每个源的搜索接口，给出耗时与可用性。
class SourceHealthPage extends StatefulWidget {
  const SourceHealthPage({super.key});

  @override
  State<SourceHealthPage> createState() => _SourceHealthPageState();
}

class _SourceHealthPageState extends State<SourceHealthPage> {
  final _service = SourceHealthService.instance;

  var _items = <SourceHealth>[];

  @override
  void initState() {
    super.initState();
    _items = _service.ofAll(ComicSource.all())
      ..sort((a, b) => a.source.name.compareTo(b.source.name));
    _service.addListener(_onChanged);
    // 有结果就不再重跑，只有新增的源才会被测。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _service.testAll(_items.map((e) => e.source), force: false);
    });
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  Color _statusColor(ColorScheme colors, SourceHealthStatus status) {
    switch (status) {
      case SourceHealthStatus.ok:
        return const Color(0xFF34C759);
      case SourceHealthStatus.empty:
        return const Color(0xFFFF9F0A);
      case SourceHealthStatus.error:
        return colors.error;
      case SourceHealthStatus.testing:
        return colors.primary;
      case SourceHealthStatus.waiting:
      case SourceHealthStatus.unsupported:
        return colors.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final usable = _items
        .where(
          (e) =>
              e.status == SourceHealthStatus.ok ||
              e.status == SourceHealthStatus.empty,
        )
        .length;
    final tested = _items.where((e) => e.tested).length;
    final avg = _averageLatency();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const GlassPageBackdrop(),
          SmoothCustomScrollView(
            slivers: [
              SliverAppbar(
                title: Text("Source health".tl),
                style: AppbarStyle.shadow,
                actions: [
                  IconButton(
                    tooltip: "Test again".tl,
                    icon: _service.running
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    onPressed: _service.running
                        ? null
                        : () => _service.testAll(
                              _items.map((e) => e.source),
                              force: true,
                            ),
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: LiquidGlass(
                    borderRadius: BorderRadius.circular(20),
                    blur: 18,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Row(
                        children: [
                          _SummaryStat(
                            value: "$usable",
                            label: "Available".tl,
                            color: const Color(0xFF34C759),
                          ),
                          _Divider(color: colors.outlineVariant),
                          _SummaryStat(
                            value: "$tested/${_items.length}",
                            label: "Tested".tl,
                            color: colors.onSurface,
                          ),
                          _Divider(color: colors.outlineVariant),
                          _SummaryStat(
                            value: avg == null ? "—" : "${avg}ms",
                            label: "Avg latency".tl,
                            color: colors.onSurface,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    "Tap a row to retest".tl,
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: LiquidGlass(
                    borderRadius: BorderRadius.circular(22),
                    blur: 18,
                    // 透明的 Material 只为给 InkWell 提供水波纹图层；
                    // 没有它会画到玻璃下面的 Scaffold 上，等于看不见。
                    child: Material(
                      type: MaterialType.transparency,
                      borderRadius: BorderRadius.circular(22),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var i = 0; i < _items.length; i++)
                            _HealthRow(
                              item: _items[i],
                              color: _statusColor(colors, _items[i].status),
                              showDivider: i != _items.length - 1,
                              onTap:
                                  _items[i].status == SourceHealthStatus.testing
                                      ? null
                                      : () => _service.testOne(_items[i]),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int? _averageLatency() {
    final latencies = _items
        .where((e) => e.status == SourceHealthStatus.ok && e.latency != null)
        .map((e) => e.latency!)
        .toList();
    if (latencies.isEmpty) {
      return null;
    }
    return latencies.reduce((a, b) => a + b) ~/ latencies.length;
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;

  final String label;

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: ts.s20.withColor(color).merge(
                  const TextStyle(fontWeight: FontWeight.w600),
                ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: ts.s10.withColor(context.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.7,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: color.withValues(alpha: 0.35),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({
    required this.item,
    required this.color,
    required this.showDivider,
    this.onTap,
  });

  final SourceHealth item;

  final Color color;

  final bool showDivider;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 14, 11),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s14,
                      ),
                      if (item.message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            item.message!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts.s10.withColor(colors.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
                if (item.latency != null)
                  Text(
                    "${item.latency}ms",
                    style: ts.s10.withColor(colors.onSurfaceVariant),
                  ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(item.statusText, style: ts.s10.withColor(color)),
                ),
              ],
            ),
          ),
          if (showDivider)
            Container(
              height: 0.7,
              margin: const EdgeInsets.only(left: 36),
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
  }
}
