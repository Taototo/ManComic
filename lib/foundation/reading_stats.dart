import 'dart:io';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';

/// 一次阅读会话（打开读者 → 退出读者的时长）。
class ReadingSession {
  final int start;
  final String day;
  final int seconds;
  final String source;
  final String title;

  /// 漫画 id、封面与副标题。
  ///
  /// 老版本只记了 source + title，所以这三个字段可能是空的：按标题聚合还能
  /// 用，但没法从「最近 30 天」直接跳详情。新记录会填上。
  final String? comicId;
  final String? cover;
  final String? subtitle;

  const ReadingSession({
    required this.start,
    required this.day,
    required this.seconds,
    required this.source,
    required this.title,
    this.comicId,
    this.cover,
    this.subtitle,
  });
}

/// 「最近 N 天读过的作品」里的一行：一本漫画在这个时间段里的总时长。
class RecentComicReading {
  final String id;

  final String sourceKey;

  final String title;

  final String subtitle;

  final String cover;

  final int seconds;

  final DateTime lastReadAt;

  const RecentComicReading({
    required this.id,
    required this.sourceKey,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.seconds,
    required this.lastReadAt,
  });

  /// 老数据没有 id，用标题兜底：点进去至少还能按标题搜索。
  String get identity => id.isEmpty ? "title:$title" : "$sourceKey/$id";
}

/// 30 天列表的排序方式
enum ReadingStatisticsSort {
  lastRead("last_read"),
  durationDesc("duration_desc"),
  durationAsc("duration_asc"),
  nameAsc("name_asc"),
  nameDesc("name_desc");

  const ReadingStatisticsSort(this.value);

  final String value;

  static ReadingStatisticsSort fromValue(Object? value) {
    for (final item in values) {
      if (item.value == value) return item;
    }
    return lastRead;
  }
}

/// 年度阅读总结。
class ReadingSummary {
  final int year;

  /// 总阅读秒数
  final int totalSeconds;

  /// 有阅读行为的天数
  final int activeDays;

  /// 最长连续阅读天数
  final int longestStreak;

  /// 读过的作品数
  final int comicCount;

  /// 源 → 秒数
  final Map<String, int> bySource;

  /// 作品 → 秒数
  final Map<String, int> byComic;

  /// 1-12 月的秒数
  final List<int> byMonth;

  /// 0-23 点的秒数
  final List<int> byHour;

  ReadingSummary({
    required this.year,
    required this.totalSeconds,
    required this.activeDays,
    required this.longestStreak,
    required this.comicCount,
    required this.bySource,
    required this.byComic,
    required this.byMonth,
    required this.byHour,
  });

  bool get isEmpty => totalSeconds <= 0;

  double get hours => totalSeconds / 3600;
}

/// 一周的阅读分布（周一为一周起点）。
class WeeklySummary {
  /// 本周周一 0 点
  final DateTime weekStart;

  /// 周一到周日的秒数
  final List<int> byDay;

  /// 7 x 24 的阅读秒数矩阵
  final List<List<int>> heat;

  final int totalSeconds;

  /// 上周同一时段的秒数，用于环比
  final int previousSeconds;

  final int activeDays;

  WeeklySummary({
    required this.weekStart,
    required this.byDay,
    required this.heat,
    required this.totalSeconds,
    required this.previousSeconds,
    required this.activeDays,
  });

  bool get isEmpty => totalSeconds <= 0;

  double get hours => totalSeconds / 3600;

  /// 与上周相比的变化比例；上周为 0 时返回 null
  double? get changeRatio {
    if (previousSeconds <= 0) return null;
    return (totalSeconds - previousSeconds) / previousSeconds;
  }

  int get maxCell {
    var max = 0;
    for (final row in heat) {
      for (final v in row) {
        if (v > max) max = v;
      }
    }
    return max;
  }
}

/// 本地阅读统计：只为「年度报告」服务，数据全部留在设备上。
class ReadingStats {
  static Database? _db;

  /// 少于这个时长不计入统计，避免误触打开也记一条。
  static const int minSessionSeconds = 10;

  static Database get _database {
    var db = _db;
    if (db != null) {
      return db;
    }
    final path = "${App.dataPath}/reading_stats.db";
    final dir = Directory(App.dataPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    db = sqlite3.open(path);
    db.execute("""
      create table if not exists reading_session (
        id integer primary key autoincrement,
        start integer not null,
        day text not null,
        seconds integer not null,
        source text not null,
        title text not null,
        comic_id text,
        cover text,
        subtitle text
      );
    """);
    // 老库补列。ALTER TABLE 加列在已有数据上是原地操作，不用重建表；重复
    // 执行只会抛「duplicate column」，吞掉即可。
    for (final column in ["comic_id", "cover", "subtitle"]) {
      try {
        db.execute("alter table reading_session add column $column text;");
      } catch (_) {
        // 列已存在
      }
    }
    db.execute("""
      create index if not exists idx_reading_session_start
      on reading_session(start);
    """);
    _db = db;
    return db;
  }

  static String _dayKey(DateTime time) {
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    return "${time.year}-$m-$d";
  }

  /// 记录一次阅读会话。
  ///
  /// [comicId] / [cover] / [subtitle] 用来让「最近 30 天」那一页能直接跳到详情
  /// 并显示封面；不传也能记，只是那一行会退化成「按标题聚合」。
  static void record({
    required Duration duration,
    required String sourceKey,
    required String title,
    String? comicId,
    String? cover,
    String? subtitle,
  }) {
    if (duration.inSeconds < minSessionSeconds) {
      return;
    }
    // 单次上限 6 小时，防止应用一直挂在后台导致异常数据。
    final seconds =
        duration.inSeconds > 6 * 3600 ? 6 * 3600 : duration.inSeconds;
    final end = DateTime.now();
    final start = end.subtract(Duration(seconds: seconds));
    try {
      _database.execute(
        "insert into reading_session "
        "(start, day, seconds, source, title, comic_id, cover, subtitle) "
        "values (?, ?, ?, ?, ?, ?, ?, ?);",
        [
          start.millisecondsSinceEpoch,
          // day 必须和 start 同一天。以前用 end：跨午夜的会话（23:50–00:10）
          // 会落成「今天」，而按日汇总用的是 `start >= 今天0点` 过滤，那 10
          // 分钟就两边都不算；年度报告里 activeDays 用 day、byMonth/byHour
          // 用 start，同一条记录会落在不同的月份。
          _dayKey(start),
          seconds,
          sourceKey,
          title,
          comicId,
          cover,
          subtitle,
        ],
      );
    } catch (_) {
      // 统计失败不能影响阅读
    }
  }

  static ReadingSession _sessionFromRow(Row row) => ReadingSession(
        start: row["start"] as int,
        day: row["day"] as String,
        seconds: row["seconds"] as int,
        source: row["source"] as String,
        title: row["title"] as String,
        comicId: row["comic_id"] as String?,
        cover: row["cover"] as String?,
        subtitle: row["subtitle"] as String?,
      );

  static const _sessionColumns =
      "start, day, seconds, source, title, comic_id, cover, subtitle";

  /// 全部时间的累计秒数（跨年，和年度报告的 [summary] 不同）。
  static int totalSeconds() {
    try {
      final rows = _database.select(
        "select sum(seconds) as s from reading_session;",
      );
      final value = rows.first["s"];
      return value is num ? value.toInt() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// 最近 [days] 天（含今天）每天的总秒数，从最早的一天排到今天。
  static List<({DateTime day, int seconds})> dailySeconds({
    int days = 7,
    DateTime? reference,
  }) {
    final now = reference ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(Duration(days: days - 1));
    final values = <String, int>{};
    try {
      final rows = _database.select(
        "select day, sum(seconds) as s from reading_session "
        "where start >= ? group by day;",
        [from.millisecondsSinceEpoch],
      );
      for (final row in rows) {
        values[row["day"] as String] = (row["s"] as num).toInt();
      }
    } catch (_) {
      // 查询失败按全零处理：统计页空着也比崩掉好
    }
    return [
      for (var i = 0; i < days; i++)
        (
          day: DateTime(from.year, from.month, from.day + i),
          seconds: values[_dayKey(
                DateTime(from.year, from.month, from.day + i),
              )] ??
              0,
        ),
    ];
  }

  /// 统计最近 [days] 天读过的作品，按本聚合。
  ///
  /// 老数据没有 comic_id，同一个 id 位置会是 null——这时用标题当聚合键，
  /// 至少不会把同一本书拆成两行。
  static List<RecentComicReading> recentComics({
    int days = 30,
    DateTime? reference,
  }) {
    final now = reference ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(Duration(days: days - 1));
    List<ReadingSession> sessions;
    try {
      final rows = _database.select(
        "select $_sessionColumns from reading_session "
        "where start >= ? order by start asc;",
        [from.millisecondsSinceEpoch],
      );
      sessions = rows.map(_sessionFromRow).toList();
    } catch (_) {
      return [];
    }

    final grouped = <String, RecentComicReading>{};
    for (final session in sessions) {
      final key = session.comicId == null || session.comicId!.isEmpty
          ? "${session.source}/title:${session.title}"
          : "${session.source}/${session.comicId}";
      final end = DateTime.fromMillisecondsSinceEpoch(
        session.start,
      ).add(Duration(seconds: session.seconds));
      final existing = grouped[key];
      if (existing == null) {
        grouped[key] = RecentComicReading(
          id: session.comicId ?? "",
          sourceKey: session.source,
          title: session.title,
          subtitle: session.subtitle ?? "",
          cover: session.cover ?? "",
          seconds: session.seconds,
          lastReadAt: end,
        );
      } else {
        grouped[key] = RecentComicReading(
          // 后到的记录可能补上了封面（老记录没有），以非空为准
          id: existing.id.isEmpty ? (session.comicId ?? "") : existing.id,
          sourceKey: existing.sourceKey,
          title: existing.title,
          subtitle: existing.subtitle.isEmpty
              ? (session.subtitle ?? "")
              : existing.subtitle,
          cover: existing.cover.isEmpty
              ? (session.cover ?? "")
              : existing.cover,
          seconds: existing.seconds + session.seconds,
          lastReadAt: end.isAfter(existing.lastReadAt)
              ? end
              : existing.lastReadAt,
        );
      }
    }
    return grouped.values.toList();
  }

  /// 删掉某本漫画的全部统计。
  static void removeComic(String sourceKey, String title, {String? comicId}) {
    try {
      if (comicId != null && comicId.isNotEmpty) {
        // 有 id 就只按 id 删。以前删完 id 还会再按标题删一遍，同一源下
        // 两本同名作品会一起消失。
        _database.execute(
          "delete from reading_session where source = ? and comic_id = ?;",
          [sourceKey, comicId],
        );
      } else {
        // 老数据没有 comic_id，只能退回标题（尽量少删，仅此一条）。
        _database.execute(
          "delete from reading_session where source = ? and title = ?;",
          [sourceKey, title],
        );
      }
    } catch (_) {
      // 删除失败不影响使用
    }
  }

  static List<ReadingSession> sessionsOfYear(int year) {
    final start = DateTime(year, 1, 1).millisecondsSinceEpoch;
    final end = DateTime(year + 1, 1, 1).millisecondsSinceEpoch;
    try {
      final rows = _database.select(
        "select $_sessionColumns from reading_session "
        "where start >= ? and start < ? order by start asc;",
        [start, end],
      );
      return rows.map(_sessionFromRow).toList();
    } catch (_) {
      return [];
    }
  }

  /// 全部阅读会话（用于成就等跨年统计）。
  static List<ReadingSession> allSessions() {
    try {
      final rows = _database.select(
        "select $_sessionColumns from reading_session order by start asc;",
      );
      return rows.map(_sessionFromRow).toList();
    } catch (_) {
      return [];
    }
  }

  /// 有记录的最早年份，用于报告页选择年份。
  static int? earliestYear() {
    try {
      final rows = _database.select(
        "select min(start) as m from reading_session;",
      );
      final m = rows.first["m"];
      if (m is! int || m <= 0) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(m).year;
    } catch (_) {
      return null;
    }
  }

  /// 统计最近一周（含今天）的阅读分布，并给出与上周的环比。
  static WeeklySummary week([DateTime? reference]) {
    final ref = reference ?? DateTime.now();
    final today = DateTime(ref.year, ref.month, ref.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final prevStart = weekStart.subtract(const Duration(days: 7));
    final endMs = weekStart.add(const Duration(days: 7)).millisecondsSinceEpoch;
    final startMs = prevStart.millisecondsSinceEpoch;

    final byDay = List<int>.filled(7, 0);
    final heat = List<List<int>>.generate(7, (_) => List<int>.filled(24, 0));
    var total = 0;
    var previous = 0;

    List<ReadingSession> sessions;
    try {
      final rows = _database.select(
        "select $_sessionColumns from reading_session "
        "where start >= ? and start < ? order by start asc;",
        [startMs, endMs],
      );
      sessions = rows.map(_sessionFromRow).toList();
    } catch (_) {
      sessions = [];
    }

    for (final s in sessions) {
      var cursor = s.start;
      var remain = s.seconds * 1000;
      while (remain > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(cursor);
        final hourStart = DateTime(dt.year, dt.month, dt.day, dt.hour);
        final nextHour =
            hourStart.add(const Duration(hours: 1)).millisecondsSinceEpoch;
        final take = math.min(remain, nextHour - cursor);
        final dayIndex =
            DateTime(dt.year, dt.month, dt.day).difference(weekStart).inDays;
        final secs = take ~/ 1000;
        if (dayIndex >= 0 && dayIndex < 7) {
          heat[dayIndex][dt.hour] += secs;
          byDay[dayIndex] += secs;
          total += secs;
        } else if (dayIndex < 0) {
          previous += secs;
        }
        cursor = nextHour;
        remain -= take;
      }
    }

    return WeeklySummary(
      weekStart: weekStart,
      byDay: byDay,
      heat: heat,
      totalSeconds: total,
      previousSeconds: previous,
      activeDays: byDay.where((e) => e > 0).length,
    );
  }

  static ReadingSummary summary(int year) {
    final sessions = sessionsOfYear(year);
    var total = 0;
    final bySource = <String, int>{};
    final byComic = <String, int>{};
    final byMonth = List<int>.filled(12, 0);
    final byHour = List<int>.filled(24, 0);
    final days = <String>{};

    for (final s in sessions) {
      total += s.seconds;
      days.add(s.day);
      bySource.update(s.source, (v) => v + s.seconds, ifAbsent: () => s.seconds);
      byComic.update(s.title, (v) => v + s.seconds, ifAbsent: () => s.seconds);
      final t = DateTime.fromMillisecondsSinceEpoch(s.start);
      byMonth[t.month - 1] += s.seconds;
      byHour[t.hour] += s.seconds;
    }

    // 最长连续阅读天数
    final sortedDays = days.toList()..sort();
    var longest = 0;
    var current = 0;
    DateTime? previous;
    for (final day in sortedDays) {
      final date = DateTime.tryParse(day);
      if (date == null) {
        continue;
      }
      if (previous != null && date.difference(previous).inDays == 1) {
        current++;
      } else {
        current = 1;
      }
      if (current > longest) {
        longest = current;
      }
      previous = date;
    }

    return ReadingSummary(
      year: year,
      totalSeconds: total,
      activeDays: days.length,
      longestStreak: longest,
      comicCount: byComic.length,
      bySource: bySource,
      byComic: byComic,
      byMonth: byMonth,
      byHour: byHour,
    );
  }
}
