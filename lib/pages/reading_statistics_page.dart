import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/reading_stats.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

const _sortSettingKey = 'readingStatisticsSort';

/// 阅读统计：今天 / 最近 7 天 / 全部，加上最近 30 天读过的作品。
///
/// 和「年度报告」是两件事：年度报告讲一年里发生了什么，这一页回答的是
/// 「我最近在读什么、花了多少时间」——所以它只有近期数据，不做成就，也不
/// 做分享长图。
class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({super.key});

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  ReadingStatisticsSort _sort = ReadingStatisticsSort.lastRead;

  List<({DateTime day, int seconds})> _daily = const [];

  List<RecentComicReading> _comics = const [];

  int _totalSeconds = 0;

  @override
  void initState() {
    super.initState();
    _sort = ReadingStatisticsSort.fromValue(appdata.settings[_sortSettingKey]);
    _load();
  }

  void _load() {
    final comics = ReadingStats.recentComics(days: 30);
    setState(() {
      _daily = ReadingStats.dailySeconds(days: 7);
      _totalSeconds = ReadingStats.totalSeconds();
      _comics = _sorted(comics);
    });
  }

  List<RecentComicReading> _sorted(List<RecentComicReading> input) {
    final list = input.toList();
    int byLastRead(RecentComicReading a, RecentComicReading b) =>
        b.lastReadAt.compareTo(a.lastReadAt);
    list.sort((a, b) {
      final primary = switch (_sort) {
        ReadingStatisticsSort.lastRead => byLastRead(a, b),
        ReadingStatisticsSort.durationDesc => b.seconds.compareTo(a.seconds),
        ReadingStatisticsSort.durationAsc => a.seconds.compareTo(b.seconds),
        ReadingStatisticsSort.nameAsc => a.title.compareTo(b.title),
        ReadingStatisticsSort.nameDesc => b.title.compareTo(a.title),
      };
      // 时长或标题相同时按「最近读的」兜底，排序结果才稳定
      return primary != 0 ? primary : byLastRead(a, b);
    });
    return list;
  }

  void _applySort(ReadingStatisticsSort value) {
    if (value == _sort) return;
    setState(() {
      _sort = value;
      _comics = _sorted(_comics);
    });
    appdata.settings[_sortSettingKey] = value.value;
    appdata.saveData();
  }

  String _sortLabel(ReadingStatisticsSort value) => switch (value) {
        ReadingStatisticsSort.lastRead => "Last read".tl,
        ReadingStatisticsSort.durationDesc => "Reading time (long to short)".tl,
        ReadingStatisticsSort.durationAsc => "Reading time (short to long)".tl,
        ReadingStatisticsSort.nameAsc => "Title A-Z".tl,
        ReadingStatisticsSort.nameDesc => "Title Z-A".tl,
      };

  void _showSortDialog() {
    var selected = _sort;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<ReadingStatisticsSort>(
                groupValue: selected,
                onChanged: (v) {
                  if (v == null) return;
                  setDialogState(() => selected = v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in ReadingStatisticsSort.values)
                      RadioListTile<ReadingStatisticsSort>(
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        title: Text(_sortLabel(option), style: ts.s14),
                        value: option,
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => dialogContext.pop(),
                  child: Text("Cancel".tl),
                ),
                FilledButton(
                  onPressed: () {
                    dialogContext.pop();
                    _applySort(selected);
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final today = _daily.isEmpty ? 0 : _daily.last.seconds;
    final week = _daily.fold<int>(0, (sum, item) => sum + item.seconds);
    final hasData = _totalSeconds > 0;
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text("Reading Statistics".tl),
            actions: [
              if (_comics.isNotEmpty)
                IconButton(
                  tooltip: "Sort".tl,
                  icon: const Icon(Icons.sort_rounded),
                  onPressed: _showSortDialog,
                ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _buildSummaryBand(context, today, week),
            ),
          ),
          // 一条记录都没有时不要画空图表：一根柱子都没有的坐标轴只会让人
          // 以为自己看错了地方。
          if (hasData)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: _buildTrendCard(context, colors),
              ),
            ),
          if (hasData) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.menu_book_outlined,
                      size: 17,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        "Comics in Last 30 Days".tl,
                        style: ts.s14.merge(
                          const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    if (_comics.isNotEmpty)
                      Text(
                        "${_comics.length}",
                        style: ts.s12.withColor(colors.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ),
            if (_comics.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Text(
                    "No comics read in the last 30 days".tl,
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                  ),
                ),
              )
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: _buildComicList(context),
                ),
              ),
          ] else
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.auto_stories_outlined,
                      size: 40,
                      color: colors.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "No reading statistics yet".tl,
                      textAlign: TextAlign.center,
                      style: ts.s14.withColor(colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.only(bottom: context.padding.bottom + 24),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBand(BuildContext context, int today, int week) {
    final colors = context.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant, width: 0.6),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            _SummaryCell(
              icon: Icons.today_outlined,
              label: "Today".tl,
              value: today > 0 ? formatReadingDuration(today) : "—",
              color: colors.primary,
            ),
            _VerticalDivider(color: colors.outlineVariant),
            _SummaryCell(
              icon: Icons.date_range_outlined,
              label: "Last 7 Days".tl,
              value: week > 0 ? formatReadingDuration(week) : "—",
              color: colors.secondary,
            ),
            _VerticalDivider(color: colors.outlineVariant),
            _SummaryCell(
              icon: Icons.auto_stories_outlined,
              label: "All Time".tl,
              value: _totalSeconds > 0
                  ? formatReadingDuration(_totalSeconds)
                  : "—",
              color: colors.tertiary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendCard(BuildContext context, ColorScheme colors) {
    final maxSeconds = _daily.fold<int>(0, (m, e) => math.max(m, e.seconds));
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              "Last 7 Days".tl,
              style: ts.s12.withColor(colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 108,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _daily.length; i++)
                  Expanded(
                    child: _TrendBar(
                      seconds: _daily[i].seconds,
                      day: _daily[i].day,
                      maxSeconds: maxSeconds,
                      isToday: i == _daily.length - 1,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComicList(BuildContext context) {
    final colors = context.colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant, width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var i = 0; i < _comics.length; i++)
              _ComicStatRow(
                comic: _comics[i],
                showDivider: i != _comics.length - 1,
                onTap: () => _open(_comics[i]),
                onDelete: () => _delete(_comics[i]),
              ),
          ],
        ),
      ),
    );
  }

  void _open(RecentComicReading comic) {
    // 老数据没有 id：只能按标题搜索，直接跳到搜索页没意义，所以给个提示
    if (comic.id.isEmpty) {
      context.showMessage(message: "No detail available for old records".tl);
      return;
    }
    context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
      ),
    );
  }

  void _delete(RecentComicReading comic) {
    ReadingStats.removeComic(
      comic.sourceKey,
      comic.title,
      comicId: comic.id,
    );
    _load();
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;

  final String label;

  final String value;

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 7),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts.s14.merge(const TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts.s10.withColor(context.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  const _VerticalDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.7,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: color.withValues(alpha: 0.5),
    );
  }
}

class _TrendBar extends StatelessWidget {
  const _TrendBar({
    required this.seconds,
    required this.day,
    required this.maxSeconds,
    required this.isToday,
  });

  final int seconds;

  final DateTime day;

  final int maxSeconds;

  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final factor = maxSeconds <= 0 ? 0.0 : seconds / maxSeconds;
    final label = "${day.month}/${day.day}";
    return Tooltip(
      message: "$label  ${formatReadingDuration(seconds)}",
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: factor.clamp(0.0, 1.0),
                  widthFactor: 0.62,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: isToday ? colors.tertiary : colors.primary,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              style: ts.s8.withColor(
                isToday ? colors.tertiary : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComicStatRow extends StatelessWidget {
  const _ComicStatRow({
    required this.comic,
    required this.showDivider,
    required this.onTap,
    required this.onDelete,
  });

  final RecentComicReading comic;

  final bool showDivider;

  final VoidCallback onTap;

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final cover = comic.cover;
    return InkWell(
      onTap: onTap,
      onLongPress: onDelete,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 58,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: cover.isEmpty
                      ? Icon(
                          Icons.menu_book_outlined,
                          size: 18,
                          color: colors.outline,
                        )
                      : AnimatedImage(
                          image: CachedImageProvider(
                            cover,
                            sourceKey: comic.sourceKey,
                            cid: comic.id,
                            fallbackToLocalCover: true,
                          ),
                          fit: BoxFit.cover,
                          cacheWidth: 200,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        comic.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s14.merge(
                          const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (comic.subtitle.trim().isNotEmpty)
                            comic.subtitle.trim(),
                          _relativeTime(comic.lastReadAt),
                        ].join(" · "),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s10.withColor(colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  formatReadingDuration(comic.seconds),
                  style: ts.s12.withColor(colors.primary),
                ),
              ],
            ),
          ),
          if (showDivider)
            Container(
              height: 0.7,
              margin: const EdgeInsets.only(left: 66),
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
  }

  static String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return "Just now".tl;
    if (diff.inMinutes < 60) return "@a min ago".tlParams({"a": diff.inMinutes});
    if (diff.inHours < 24) return "@a h ago".tlParams({"a": diff.inHours});
    return "@a d ago".tlParams({"a": diff.inDays});
  }
}

/// 把秒数写成人话：超过一小时给「1 小时 20 分」，不到一分钟明确说不满一分钟。
String formatReadingDuration(int seconds) {
  if (seconds <= 0) return "0 min";
  if (seconds < 60) return "Less than a minute".tl;
  final minutes = seconds ~/ 60;
  if (minutes < 60) return "@m min".tlParams({"m": minutes});
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (rest == 0) return "@h h".tlParams({"h": hours});
  return "@h h @m min".tlParams({"h": hours, "m": rest});
}
