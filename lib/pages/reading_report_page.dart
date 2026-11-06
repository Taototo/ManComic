import 'package:flutter/material.dart';
import 'package:venera/components/achievement_badge.dart';
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

  /// 本月目标的档位：读到一点就点亮青铜，50% 白银，达成黄金，超额 150% 钻石。
  ///
  /// 门槛设在 0 / 50 / 100 / 150 而不是 25 / 50 / 75 / 100，是因为「才读了
  /// 一成」也值得给个青铜——目标卡的第一眼应该是「已经开始了」，而不是
  /// 一上来就顶着一枚灰徽章。
  AchievementTier _goalTier(int goal, int read) {
    if (goal <= 0 || read <= 0) {
      return AchievementTier.locked;
    }
    final ratio = read / goal;
    if (ratio >= 1.5) {
      return AchievementTier.diamond;
    }
    if (ratio >= 1) {
      return AchievementTier.gold;
    }
    if (ratio >= 0.5) {
      return AchievementTier.silver;
    }
    return AchievementTier.bronze;
  }

  Future<void> _editGoal() async {
    const presets = [60, 180, 300, 600, 1200];
    final current = _goalMinutes;
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Monthly Goal'.tl),
        children: [
          for (final minutes in presets)
            ListTile(
              title: Text(
                Achievements.valueText(AchievementMetric.seconds, minutes * 60),
              ),
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

  /// 本月阅读目标：一枚随完成度换材质的徽章 + 带刻度的进度条。
  ///
  /// 原来是一个圆环套百分比，和下面「本周」「年度总时长」三块长得差不多，
  /// 看不出哪一块是「你给自己定的目标」。现在目标单独用徽章语言表达：
  /// 徽章的材质就是完成度，外圈是到下一档的距离。
  Widget _buildGoal(ColorScheme colors) {
    final goal = _goalMinutes;
    final read = _monthReadMinutes;
    final ratio = goal <= 0 ? 0.0 : (read / goal).clamp(0.0, 1.0);
    final reached = goal > 0 && read >= goal;
    final tier = _goalTier(goal, read);
    final accent = tier.isUnlocked ? tier.deep : colors.onSurfaceVariant;
    final subtitle = goal <= 0
        ? 'Set a goal'.tl
        : reached
            ? (read > goal
                ? '@a over the goal'.tlParams({
                    'a': Achievements.valueText(
                      AchievementMetric.seconds,
                      (read - goal) * 60,
                    ),
                  })
                : 'Goal reached'.tl)
            : '@a left this month'.tlParams({
                'a': Achievements.valueText(
                  AchievementMetric.seconds,
                  (goal - read) * 60,
                ),
              });

    return AppSurface(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      clip: true,
      onTap: _editGoal,
      child: Row(
        children: [
          AchievementBadge(
            icon: Icons.flag_rounded,
            tier: tier,
            size: 76,
            ratio: goal <= 0 ? null : ratio,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      'Monthly Goal'.tl,
                      style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    if (reached)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AchievementTier.gold.base.withValues(
                            alpha: 0.2,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Goal reached'.tl,
                          style: ts.s10.withColor(
                            AchievementTier.gold.deep,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                if (goal > 0)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$read',
                          style: ts.s24.copyWith(
                            fontWeight: FontWeight.bold,
                            color: accent,
                          ),
                        ),
                        TextSpan(
                          text: ' / $goal ${'min'.tl}',
                          style: ts.s10.withColor(colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                else
                  Text(
                    'Set a goal'.tl,
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                  ),
                const SizedBox(height: 2),
                if (goal > 0)
                  Text(
                    subtitle,
                    style: ts.s10.withColor(colors.onSurfaceVariant),
                  ),
                const SizedBox(height: 10),
                _GoalBar(ratio: ratio, color: tier.base, base: colors),
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
    );
  }

  Widget _buildWeek(ColorScheme colors) {
    final week = _week;
    final change = week.changeRatio;
    return AppSurface(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderRadius: const BorderRadius.all(Radius.circular(20)),
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
            week.isEmpty
                ? "No reading this week".tl
                : _durationText(week.totalSeconds),
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

  /// 成就墙。
  ///
  /// 每个家族一枚徽章，四档共用一套画法，点亮得越多徽章越亮、星标越多。
  /// 点开看得到四档门槛和到下一档还差多少——「升级」这件事要能被看见，
  /// 否则徽章只是装饰。
  Widget _buildAchievements(ColorScheme colors) {
    final progress = Achievements.progress();
    final summary = Achievements.summary(progress);
    return AppSurface(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(
                  "Achievements".tl,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  "@a/@b".tlParams({
                    'a': summary.unlocked.toString(),
                    'b': summary.total.toString(),
                  }),
                  style: ts.s10.withColor(colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 3),
            child: Text(
              "Four tiers each: Bronze, Silver, Gold and Diamond".tl,
              style: ts.s10.withColor(
                colors.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 4.0;
              final itemWidth = (constraints.maxWidth - gap * 3) / 4;
              return Wrap(
                spacing: gap,
                runSpacing: 10,
                children: [
                  for (final p in progress)
                    SizedBox(
                      width: itemWidth,
                      child: _buildBadgeTile(p, colors),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBadgeTile(AchievementProgress p, ColorScheme colors) {
    final tier = p.tier;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _showAchievementDetails(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          children: [
            AchievementBadge(
              icon: p.family.icon,
              tier: tier,
              size: 54,
              ratio: p.unlocked ? p.ratioToNext : null,
              glow: false,
            ),
            const SizedBox(height: 7),
            Text(
              p.family.title.tl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: ts.s10.withColor(
                tier.isUnlocked
                    ? colors.onSurface
                    : colors.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 1),
            Text(
              tier.label.tl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: ts.s10.withColor(
                tier.isUnlocked
                    ? tier.deep
                    : colors.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAchievementDetails(AchievementProgress p) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      // 液态主题下底部弹层用不透明 surface：它下面只有一层纯色遮罩，模糊
      // 过去还是同一个纯色，真透明反而会让字压在漫画封面的杂色上。可读性
      // 优先，和对话框同一个策略。
      backgroundColor: LiquidTheme.isOn(context)
          ? context.colorScheme.surface
          : context.colorScheme.surfaceContainerLow,
      builder: (context) => _AchievementSheet(progress: p),
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
      (
        Icons.local_fire_department,
        "${_summary.longestStreak}",
        "Longest streak"
      ),
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
                                ? colors.primary
                                    .withValues(alpha: 0.35 + 0.55 * ratio)
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
                        child: Text(name,
                            style: ts.s12,
                            maxLines: 1,
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
                      backgroundColor:
                          colors.outlineVariant.withValues(alpha: 0.3),
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

/// 本月目标的进度条：底轨 + 填充 + 25/50/75 三道刻度。
///
/// 刻度用卡片底色「挖」出来，看起来像轨道被分成四段——比一条纯色条更能
/// 传达「还差几段」，也顺便和上面的徽章档位对上。
class _GoalBar extends StatelessWidget {
  const _GoalBar({
    required this.ratio,
    required this.color,
    required this.base,
  });

  final double ratio;

  final Color color;

  final ColorScheme base;

  @override
  Widget build(BuildContext context) {
    const height = 7.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: height,
          child: Stack(
            children: [
              Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: base.outlineVariant.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              Container(
                width: (width * ratio.clamp(0.0, 1.0)).clamp(height, width),
                height: height,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              for (final tick in const [0.25, 0.5, 0.75])
                Positioned(
                  left: width * tick,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 1.4,
                    color: base.surfaceContainerLow,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 成就详情：一枚大徽章 + 四档阶梯。
///
/// 阶梯里每一行都画真实档位的徽章（未达到的降透明度），既能看清下一档
/// 长什么样，也能一眼看出自己走到第几级。
class _AchievementSheet extends StatelessWidget {
  const _AchievementSheet({required this.progress});

  final AchievementProgress progress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final p = progress;
    final next = p.nextTarget;
    return SafeArea(
      top: false,
      // 小屏幕上八条成就 + 四档阶梯可能撑满一屏，允许滚动，不要溢出。
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AchievementBadge(
                    icon: p.family.icon,
                    tier: p.tier,
                    size: 72,
                    ratio: p.unlocked ? p.ratioToNext : null,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.family.title.tl, style: ts.s18.bold),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: p.tier.base.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                p.tier.label.tl,
                                style: ts.s10.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: p.tier.isUnlocked
                                      ? p.tier.deep
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              Achievements.valueText(
                                p.family.metric,
                                p.value,
                              ),
                              style: ts.s10.withColor(colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                p.family.description.tl,
                style: ts.s12.withColor(colors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              if (next != null) ...[
                Row(
                  children: [
                    Text(
                      "Next tier".tl,
                      style: ts.s10.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Text(
                      "@a to go".tlParams({
                        'a': Achievements.valueText(
                          p.family.metric,
                          p.remainingToNext,
                        ),
                      }),
                      style: ts.s10.withColor(colors.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: p.ratioToNext,
                    minHeight: 6,
                    backgroundColor:
                        colors.outlineVariant.withValues(alpha: 0.35),
                    valueColor: AlwaysStoppedAnimation(
                      AchievementTier.values[p.tierIndex + 1].base,
                    ),
                  ),
                ),
              ] else
                Row(
                  children: [
                    Icon(
                      Icons.workspace_premium_rounded,
                      size: 15,
                      color: AchievementTier.diamond.deep,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "Max tier reached".tl,
                      style: ts.s10.withColor(AchievementTier.diamond.deep),
                    ),
                  ],
                ),
              const SizedBox(height: 18),
              for (var i = 0; i < AchievementTier.tierCount; i++)
                _ladderRow(context, i),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ladderRow(BuildContext context, int index) {
    final colors = context.colorScheme;
    final tier = AchievementTier.values[index + 1];
    final target = progress.family.tiers[index];
    final reached = progress.tierIndex >= index + 1;
    final isNext = progress.tierIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Opacity(
            opacity: reached ? 1 : 0.42,
            child: AchievementBadge(
              icon: progress.family.icon,
              tier: tier,
              size: 32,
              glow: false,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            tier.label.tl,
            style: ts.s12.copyWith(
              fontWeight: reached ? FontWeight.w600 : FontWeight.w400,
              color: reached ? colors.onSurface : colors.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            Achievements.valueText(progress.family.metric, target),
            style: ts.s12.withColor(colors.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 18,
            child: reached
                ? Icon(
                    Icons.check_circle_rounded,
                    size: 16,
                    color: tier.base,
                  )
                : isNext
                    ? Icon(
                        Icons.radio_button_unchecked,
                        size: 14,
                        color: colors.primary,
                      )
                    : null,
          ),
        ],
      ),
    );
  }
}
