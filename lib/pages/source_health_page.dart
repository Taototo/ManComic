import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/translations.dart';

/// 单个源的检测结果
enum SourceHealthStatus { waiting, testing, ok, empty, error, unsupported }

class SourceHealth {
  final ComicSource source;

  SourceHealthStatus status;

  /// 毫秒
  int? latency;

  int? count;

  String? message;

  SourceHealth(this.source, {this.status = SourceHealthStatus.waiting});
}

/// 漫画源体检：并发探测每个源的搜索接口，给出耗时与可用性。
class SourceHealthPage extends StatefulWidget {
  const SourceHealthPage({super.key});

  @override
  State<SourceHealthPage> createState() => _SourceHealthPageState();
}

class _SourceHealthPageState extends State<SourceHealthPage> {
  final _items = <SourceHealth>[];

  bool _running = false;

  /// 用于探测的关键词，尽量短的常见字，多数源都能返回结果
  static const _probeKeyword = 'a';

  static const _timeout = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    for (final source in ComicSource.all()) {
      final item = SourceHealth(source);
      if (source.searchPageData == null) {
        item.status = SourceHealthStatus.unsupported;
      }
      _items.add(item);
    }
    _items.sort((a, b) => a.source.name.compareTo(b.source.name));
    WidgetsBinding.instance.addPostFrameCallback((_) => _runAll());
  }

  Future<void> _runOne(SourceHealth item) async {
    if (item.source.searchPageData == null) {
      return;
    }
    setState(() {
      item.status = SourceHealthStatus.testing;
      item.latency = null;
      item.count = null;
      item.message = null;
    });
    final data = item.source.searchPageData!;
    final options =
        (data.searchOptions ?? []).map((e) => e.defaultValue).toList();
    final watch = Stopwatch()..start();
    try {
      Future<dynamic> task;
      if (data.loadPage != null) {
        task = data.loadPage!(_probeKeyword, 1, options);
      } else if (data.loadNext != null) {
        task = data.loadNext!(_probeKeyword, null, options);
      } else {
        if (mounted) {
          setState(() {
            item.status = SourceHealthStatus.unsupported;
          });
        }
        return;
      }
      final res = await task.timeout(_timeout);
      watch.stop();
      if (!mounted) return;
      setState(() {
        item.latency = watch.elapsedMilliseconds;
        if (res.error == true) {
          item.status = SourceHealthStatus.error;
          item.message = res.errorMessage ?? "Unknown error".tl;
        } else {
          final count = (res.data as List?)?.length ?? 0;
          item.count = count;
          item.status =
              count > 0 ? SourceHealthStatus.ok : SourceHealthStatus.empty;
        }
      });
    } catch (e) {
      watch.stop();
      Log.info("SourceHealth", "${item.source.key} failed: $e");
      if (!mounted) return;
      setState(() {
        item.latency = watch.elapsedMilliseconds;
        item.status = SourceHealthStatus.error;
        item.message = e is TimeoutException
            ? "Timeout".tl
            : e.toString().split('\n').first;
      });
    }
  }

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
    });
    const concurrency = 4;
    var index = 0;
    Future<void> worker() async {
      while (index < _items.length) {
        final item = _items[index++];
        if (!mounted) return;
        await _runOne(item);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (mounted) {
      setState(() {
        _running = false;
      });
    }
  }

  Color _statusColor(ColorScheme colors, SourceHealthStatus status) {
    switch (status) {
      case SourceHealthStatus.ok:
        return Colors.green;
      case SourceHealthStatus.empty:
        return Colors.orange;
      case SourceHealthStatus.error:
        return colors.error;
      case SourceHealthStatus.testing:
        return colors.primary;
      case SourceHealthStatus.waiting:
      case SourceHealthStatus.unsupported:
        return colors.onSurfaceVariant;
    }
  }

  String _statusText(SourceHealth item) {
    switch (item.status) {
      case SourceHealthStatus.ok:
        return "${item.count} 条".tl;
      case SourceHealthStatus.empty:
        return "无结果".tl;
      case SourceHealthStatus.error:
        return "失败".tl;
      case SourceHealthStatus.testing:
        return "检测中".tl;
      case SourceHealthStatus.waiting:
        return "待检测".tl;
      case SourceHealthStatus.unsupported:
        return "不支持搜索".tl;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final okCount = _items
        .where((e) =>
            e.status == SourceHealthStatus.ok ||
            e.status == SourceHealthStatus.empty)
        .length;
    final tested = _items
        .where((e) => e.status != SourceHealthStatus.waiting)
        .length;
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(
          title: Text("Source health".tl),
          actions: [
            IconButton(
              tooltip: "Test again".tl,
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: _running ? null : _runAll,
            ),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              "可用 $okCount / 已检测 $tested / 共 ${_items.length}"
                  .tl,
              style: ts.s12.withColor(colors.onSurfaceVariant),
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = _items[index];
              final color = _statusColor(colors, item.status);
              return ListTile(
                dense: true,
                title: Text(item.source.name, maxLines: 1),
                subtitle: item.message == null
                    ? null
                    : Text(
                        item.message!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s10.withColor(colors.onSurfaceVariant),
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.latency != null)
                      Text(
                        "${item.latency}ms",
                        style: ts.s10.withColor(colors.onSurfaceVariant),
                      ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _statusText(item),
                        style: ts.s10.withColor(color),
                      ),
                    ),
                  ],
                ),
                onTap: item.status == SourceHealthStatus.testing
                    ? null
                    : () => _runOne(item),
              );
            },
            childCount: _items.length,
          ),
        ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }
}
