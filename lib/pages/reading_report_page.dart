import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/achievements.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/foundation/reading_stats.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// 年度阅读报告：全部数据来自本地 [ReadingStats]，不联网。
class ReadingReportPage extends StatefulWidget {
  const ReadingReportPage({super.key, this.year});

  final int? year;

  @override
  State<ReadingReportPage> createState() => _ReadingReportPageState();
}

class _ReadingReportPageState extends State<ReadingReportPage> {
  late int _year;

  late ReadingSummary _summary;

  late WeeklySummary _week;

  List<int> _years = [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().year;
    final earliest = ReadingStats.earliestYear() ?? now;
    _years = [for (var y = now; y >= earliest; y--) y];
    if (_years.isEmpty) {
      _years = [now];
    }
    _year = widget.year ?? now;
    if (!_years.contains(_year)) {
      _years.insert(0, _year);
    }
    _summary = ReadingStats.summary(_year);
    _week = ReadingStats.week();
    super.initState();
  }

  void _switchYear(int year) {
    if (year == _year) return;
    setState(() {
      _year = year;
      _summary = ReadingStats.summary(year);
    });
  }

  String get _shareText {
    final s = _summary;
    final hours = (s.totalSeconds / 3600).toStringAsFixed(1);
    final topSource = _topSourceName();
    return [
      "我的 $_year 年漫画阅读报告",
      "阅读时长：$hours 小时",
      "阅读天数：${s.activeDays} 天（最长连续 ${s.longestStreak} 天）",
      "读过的作品：${s.comicCount} 部",
      if (topSource != null) "最常看的源：$topSource",
      "—— 来自 ManComic",
    ].join("\n");
  }

  String? _topSourceName() {
    if (_summary.bySource.isEmpty) return null;
    final entry = _summary.bySource.entries.reduce(
      (a, b) => a.value >= b.value ? a : b,
    );
    return ComicSource.find(entry.key)?.name ?? entry.key;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text("Yearly Report".tl),
            actions: [
              IconButton(
                tooltip: "Share".tl,
                icon: const Icon(Icons.ios_share),
                onPressed: () => Share.shareText(_shareText),
              ),
            ],
          ),
          if (_years.length > 1)
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: _years.map((year) {
                    final active = year == _year;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text("$year"),
                        selected: active,
                        onSelected: (_) => _switchYear(year),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: _summary.isEmpty
                ? _buildEmpty(colors)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildGoal(colors),
                      _buildWeek(colors),
                      _buildHeader(colors),
                      _buildTiles(colors),
                      _buildMonthChart(colors),
                      _buildSources(colors),
                      _buildHourInfo(colors),
                      _buildAchievements(colors),
                      const SizedBox(height: 32),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  String _durationText(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) {
      return "$h 小时 $m 分钟";
    }
    return "$m 分钟";
  }

  int get _monthReadMinutes {
    final now = DateTime.now();
    final summary =
        _year == now.year ? _summary : ReadingStats.summary(now.year);
    final index = now.month - 1;
    if (index < 0 || index >= summary.byMonth.length) return 0;
    return summary.byMonth[index] ~/ 60;
  }

  int get _goalMinutes {
    final raw = appdata.settings['monthlyGoal'];
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw') ?? 0;
  }

  Future<void> _editGoal() async {
    const presets = [60, 180, 300, 600];
    final current = _goalMinutes;
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Monthly Goal'.tl),
        children: [
          for (final minutes in presets)
            ListTile(
              title: Text('@a min'.tlParams({'a': '$minutes'})),
              trailing: minutes == current ? const Icon(Icons.check) : null,
              onTap: () => dialogContext.pop(minutes),
            ),
          ListTile(
            title: Text('Turn off'.tl),
            trailing: current == 0 ? const Icon(Icons.check) : null,
            onTap: () => dialogContext.pop(0),
          ),
        ],
      ),
    );
    if (result == null) return;
    appdata.settings['monthlyGoal'] = result;
    appdata.saveData();
    if (mounted) {
      setState(() {});
    }
  }

  /// 本月阅读目标：圆环进度 + 已读/目标分钟数，点一下换目标。
  Widget _buildGoal(ColorScheme colors) {
    final goal = _goalMinutes;
    final read = _monthReadMinutes;
    final ratio = goal <= 0 ? 0.0 : (read / goal).clamp(0.0, 1.0);
    final reached = goal > 0 && read >= goal;
    final accent = reached ? Colors.green : colors.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: colors.surfaceContainerLow,
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _editGoal,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: ratio),
                        duration: const Duration(milliseconds: 700),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) =>
                            CircularProgressIndicator(
                          value: goal <= 0 ? 0 : value,
                          strokeWidth: 6,
                          strokeCap: StrokeCap.round,
                          backgroundColor:
                              colors.outlineVariant.withValues(alpha: 0.3),
                          valueColor: AlwaysStoppedAnimation(accent),
                        ),
                      ),
                    ),
                    if (goal <= 0)
                      Icon(
                        Icons.flag_outlined,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      )
                    else if (reached)
                      Icon(Icons.check_rounded, size: 26, color: accent)
                    else
                      Text(
                        '${(ratio * 100).round()}%',
                        style: ts.s14.copyWith(
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Monthly Goal'.tl,
                      style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      goal <= 0
                          ? 'Set a goal'.tl
                          : reached
                              ? 'Goal reached · @a min'
                                  .tlParams({'a': '$read'})
                              : '@a / @b min'
                                  .tlParams({'a': '$read', 'b': '$goal'}),
                      style: ts.s12.withColor(colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWeek(ColorScheme colors) {
    final week = _week;
    final change = week.changeRatio;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: colors.surfaceContainerLow,
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                "This week".tl,
                style: ts.s14.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (change != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (change >= 0 ? Colors.green : Colors.orange)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        change >= 0
                            ? Icons.trending_up_rounded
                            : Icons.trending_down_rounded,
                        size: 13,
                        color: change >= 0 ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        "${change >= 0 ? '+' : ''}${(change * 100).round()}%",
                        style: ts.s10.withColor(
                          change >= 0 ? Colors.green : Colors.orange,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            week.isEmpty ? "No reading this week".tl : _durationText(week.totalSeconds),
            style: ts.s20.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            "${week.activeDays} 天有阅读 · 周一到周日 0-24 时".tl,
            style: ts.s10.withColor(colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _WeekHeatmap(week: week),
        ],
      ),
    );
  }

  /// 成就墙：全部由本地阅读记录与收藏数推导
  Widget _buildAchievements(ColorScheme colors) {
    final progress = Achievements.progress();
    final unlocked = progress.where((e) => e.unlocked).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: colors.surfaceContainerLow,
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                "Achievements".tl,
                style: ts.s14.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                "@a/@b".tlParams({
                  'a': unlocked.toString(),
                  'b': progress.length.toString(),
                }),
                style: ts.s10.withColor(colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 14,
            children:
                progress.map((p) => _buildBadge(p, colors)).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(AchievementProgress p, ColorScheme colors) {
    final on = p.unlocked;
    return SizedBox(
      width: 72,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest,
              border: Border.all(
                color: on
                    ? colors.primary.withValues(alpha: 0.45)
                    : colors.outlineVariant.withValues(alpha: 0.6),
                width: 0.8,
              ),
            ),
            child: Icon(
              p.achievement.icon,
              size: 24,
              color: on
                  ? colors.onPrimaryContainer
                  : colors.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            p.achievement.title.tl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: ts.s10.withColor(
              on
                  ? colors.onSurface
                  : colors.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            Achievements.progressText(p),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: ts.s10.withColor(
              on
                  ? colors.primary
                  : colors.onSurfaceVariant.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 0),
      child: Column(
        children: [
          Icon(Icons.auto_stories_outlined, size: 56, color: colors.outline),
          const SizedBox(height: 16),
          Text(
            "No reading records for this year".tl,
            style: ts.s16,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            "Read a few chapters and come back".tl,
            style: ts.s12.withColor(colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme colors) {
    final hours = _summary.totalSeconds / 3600;
    final text = hours >= 1
        ? hours.toStringAsFixed(1)
        : (_summary.totalSeconds / 60).toStringAsFixed(0);
    final unit = hours >= 1 ? "Hours" : "Minutes";
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "$_year",
            style: ts.s14.withColor(colors.onPrimaryContainer.toOpacity(0.7)),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                text,
                style: ts.s40.bold.withColor(colors.onPrimaryContainer),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 6),
                child: Text(
                  unit.tl,
                  style: ts.s14.withColor(colors.onPrimaryContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "Total reading time".tl,
            style: ts.s12.withColor(colors.onPrimaryContainer.toOpacity(0.7)),
          ),
        ],
      ),
    );
  }

  Widget _buildTiles(ColorScheme colors) {
    final avg = _summary.activeDays == 0
        ? 0
        : _summary.totalSeconds ~/ _summary.activeDays;
    final tiles = [
      (Icons.calendar_month, "${_summary.activeDays}", "Reading days"),
      (Icons.local_fire_department, "${_summary.longestStreak}", "Longest streak"),
      (Icons.menu_book, "${_summary.comicCount}", "Comics read"),
      (Icons.timelapse, "${avg ~/ 60}", "Avg minutes per day"),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: tiles.map((t) {
          return Container(
            width: (context.width - 44) / 2,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(t.$1, size: 20, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.$2, style: ts.s18.bold),
                      const SizedBox(height: 2),
                      Text(
                        t.$3.tl,
                        style: ts.s10.withColor(colors.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMonthChart(ColorScheme colors) {
    final max = _summary.byMonth.fold<int>(0, (a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Monthly rhythm".tl, style: ts.s14.bold),
          const SizedBox(height: 12),
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(12, (i) {
                final value = _summary.byMonth[i];
                final ratio = max == 0 ? 0.0 : value / max;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: 6 + 66 * ratio,
                          decoration: BoxDecoration(
                            color: ratio > 0
                                ? colors.primary.withValues(alpha: 0.35 + 0.55 * ratio)
                                : colors.outlineVariant.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "${i + 1}",
                          style: ts.s8.withColor(colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSources(ColorScheme colors) {
    final entries = _summary.bySource.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    final total = _summary.totalSeconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Favorite sources".tl, style: ts.s14.bold),
          const SizedBox(height: 10),
          ...entries.take(3).map((e) {
            final name = ComicSource.find(e.key)?.name ?? e.key;
            final ratio = total == 0 ? 0.0 : e.value / total;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(name, style: ts.s12, maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      Text(
                        "${(e.value / 3600).toStringAsFixed(1)}h",
                        style: ts.s12.withColor(colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: ratio.clamp(0.02, 1.0),
                      minHeight: 6,
                      backgroundColor: colors.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildHourInfo(ColorScheme colors) {
    if (_summary.totalSeconds == 0) {
      return const SizedBox.shrink();
    }
    var peak = 0;
    for (var i = 1; i < 24; i++) {
      if (_summary.byHour[i] > _summary.byHour[peak]) {
        peak = i;
      }
    }
    var night = 0;
    for (var i = 0; i < 24; i++) {
      if (i >= 22 || i <= 4) {
        night += _summary.byHour[i];
      }
    }
    final nightRatio = night / _summary.totalSeconds;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.nightlight_round, color: colors.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ("Peak reading hour: @h").tlParams({"h": "$peak:00"}),
                  style: ts.s14.withColor(colors.onSecondaryContainer),
                ),
                const SizedBox(height: 4),
                Text(
                  ("@p% of reading happened late at night")
                      .tlParams({"p": (nightRatio * 100).toStringAsFixed(0)}),
                  style: ts.s12.withColor(
                    colors.onSecondaryContainer.toOpacity(0.75),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// 7 x 24 的阅读热力图
class _WeekHeatmap extends StatelessWidget {
  const _WeekHeatmap({required this.week});

  final WeeklySummary week;

  static const _labels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final maxCell = week.maxCell;
    final base = colors.surfaceContainerHighest;
    return Column(
      children: [
        for (var d = 0; d < 7; d++)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: Text(
                    _labels[d],
                    style: ts.s8.withColor(colors.onSurfaceVariant),
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      for (var h = 0; h < 24; h++)
                        Expanded(
                          child: Container(
                            height: 11,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              color: week.heat[d][h] == 0
                                  ? base.withValues(alpha: 0.6)
                                  : Color.lerp(
                                      colors.primary.withValues(alpha: 0.22),
                                      colors.primary,
                                      maxCell == 0
                                          ? 0
                                          : (week.heat[d][h] / maxCell)
                                              .clamp(0.0, 1.0),
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 2),
        Row(
          children: [
            const SizedBox(width: 16),
            Expanded(
              child: Row(
                children: [
                  for (var h = 0; h < 24; h++)
                    Expanded(
                      child: Text(
                        h % 6 == 0 ? '$h' : '',
                        textAlign: TextAlign.left,
                        style: ts.s8.withColor(colors.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
