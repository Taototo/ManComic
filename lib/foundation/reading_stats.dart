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

  const ReadingSession({
    required this.start,
    required this.day,
    required this.seconds,
    required this.source,
    required this.title,
  });
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
        title text not null
      );
    """);
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
  static void record({
    required Duration duration,
    required String sourceKey,
    required String title,
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
        "insert into reading_session (start, day, seconds, source, title) "
        "values (?, ?, ?, ?, ?);",
        [
          start.millisecondsSinceEpoch,
          _dayKey(end),
          seconds,
          sourceKey,
          title,
        ],
      );
    } catch (_) {
      // 统计失败不能影响阅读
    }
  }

  static List<ReadingSession> sessionsOfYear(int year) {
    final start = DateTime(year, 1, 1).millisecondsSinceEpoch;
    final end = DateTime(year + 1, 1, 1).millisecondsSinceEpoch;
    try {
      final rows = _database.select(
        "select start, day, seconds, source, title from reading_session "
        "where start >= ? and start < ? order by start asc;",
        [start, end],
      );
      return rows
          .map((e) => ReadingSession(
                start: e["start"] as int,
                day: e["day"] as String,
                seconds: e["seconds"] as int,
                source: e["source"] as String,
                title: e["title"] as String,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 全部阅读会话（用于成就等跨年统计）。
  static List<ReadingSession> allSessions() {
    try {
      final rows = _database.select(
        "select start, day, seconds, source, title from reading_session "
        "order by start asc;",
      );
      return rows
          .map((e) => ReadingSession(
                start: e["start"] as int,
                day: e["day"] as String,
                seconds: e["seconds"] as int,
                source: e["source"] as String,
                title: e["title"] as String,
              ))
          .toList();
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
        "select start, day, seconds, source, title from reading_session "
        "where start >= ? and start < ? order by start asc;",
        [startMs, endMs],
      );
      sessions = rows
          .map((e) => ReadingSession(
                start: e["start"] as int,
                day: e["day"] as String,
                seconds: e["seconds"] as int,
                source: e["source"] as String,
                title: e["title"] as String,
              ))
          .toList();
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
