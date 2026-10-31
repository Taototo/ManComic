import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/reading_stats.dart';
import 'package:venera/utils/translations.dart';

/// 成就的计量方式。
enum AchievementMetric {
  /// 累计阅读秒数
  seconds,

  /// 最长连续阅读天数
  streak,

  /// 有阅读记录的天数
  activeDays,

  /// 读过的作品数
  comics,

  /// 深夜（0-5 点）累计阅读秒数
  nightSeconds,

  /// 图片收藏张数
  imageFavorites,
}

class Achievement {
  const Achievement(this.id, this.title, this.icon, this.target, this.metric);

  /// 持久化用的稳定 id，不要修改
  final String id;

  /// 翻译键
  final String title;

  final IconData icon;

  final int target;

  final AchievementMetric metric;
}

class AchievementProgress {
  const AchievementProgress(this.achievement, this.value);

  final Achievement achievement;

  final int value;

  bool get unlocked => value >= achievement.target;

  double get ratio =>
      achievement.target <= 0 ? 1 : (value / achievement.target).clamp(0.0, 1.0);
}

/// 成就系统的统计快照。
class AchievementStats {
  const AchievementStats({
    this.totalSeconds = 0,
    this.longestStreak = 0,
    this.activeDays = 0,
    this.comicCount = 0,
    this.nightSeconds = 0,
    this.imageFavoriteCount = 0,
  });

  final int totalSeconds;

  final int longestStreak;

  final int activeDays;

  final int comicCount;

  final int nightSeconds;

  final int imageFavoriteCount;

  factory AchievementStats.compute() {
    var total = 0;
    var night = 0;
    final days = <String>{};
    final titles = <String>{};
    try {
      for (final s in ReadingStats.allSessions()) {
        total += s.seconds;
        days.add(s.day);
        titles.add(s.title);
        final hour = DateTime.fromMillisecondsSinceEpoch(s.start).hour;
        if (hour >= 0 && hour < 5) {
          night += s.seconds;
        }
      }
    } catch (_) {}

    // 最长连续阅读天数
    final sorted = days.toList()..sort();
    var longest = 0;
    var current = 0;
    DateTime? previous;
    for (final day in sorted) {
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

    var imageCount = 0;
    try {
      imageCount = ImageFavoriteManager().length;
    } catch (_) {}

    return AchievementStats(
      totalSeconds: total,
      longestStreak: longest,
      activeDays: days.length,
      comicCount: titles.length,
      nightSeconds: night,
      imageFavoriteCount: imageCount,
    );
  }

  int valueOf(AchievementMetric metric) {
    return switch (metric) {
      AchievementMetric.seconds => totalSeconds,
      AchievementMetric.streak => longestStreak,
      AchievementMetric.activeDays => activeDays,
      AchievementMetric.comics => comicCount,
      AchievementMetric.nightSeconds => nightSeconds,
      AchievementMetric.imageFavorites => imageFavoriteCount,
    };
  }
}

/// 阅读成就：全部基于本地阅读记录与收藏数，不需要联网。
class Achievements {
  static const String _settingKey = 'unlockedAchievements';

  static const List<Achievement> all = [
    Achievement('first_page', 'First Page', Icons.auto_stories_outlined, 60,
        AchievementMetric.seconds),
    Achievement('hour_1', 'One Hour', Icons.schedule, 3600,
        AchievementMetric.seconds),
    Achievement('hour_10', 'Ten Hours', Icons.timer_outlined, 36000,
        AchievementMetric.seconds),
    Achievement('hour_50', 'Fifty Hours', Icons.whatshot_outlined, 180000,
        AchievementMetric.seconds),
    Achievement('hour_100', 'Hundred Hours', Icons.workspace_premium_outlined,
        360000, AchievementMetric.seconds),
    Achievement('streak_3', 'Three Days Streak', Icons.local_fire_department,
        3, AchievementMetric.streak),
    Achievement('streak_7', 'One Week Streak', Icons.local_fire_department,
        7, AchievementMetric.streak),
    Achievement('streak_30', 'One Month Streak', Icons.bolt, 30,
        AchievementMetric.streak),
    Achievement('days_30', 'Thirty Days', Icons.calendar_month_outlined, 30,
        AchievementMetric.activeDays),
    Achievement('days_100', 'Hundred Days', Icons.event_available_outlined,
        100, AchievementMetric.activeDays),
    Achievement('comics_20', 'Twenty Comics', Icons.menu_book_outlined, 20,
        AchievementMetric.comics),
    Achievement('comics_100', 'Hundred Comics', Icons.library_books_outlined,
        100, AchievementMetric.comics),
    Achievement('night_owl', 'Night Owl', Icons.nightlight_round, 36000,
        AchievementMetric.nightSeconds),
    Achievement('image_100', 'Image Collector', Icons.collections_outlined,
        100, AchievementMetric.imageFavorites),
  ];

  static List<String> get unlockedIds {
    final raw = appdata.settings[_settingKey];
    if (raw is List) {
      return raw.map((e) => e.toString()).toList();
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          return list.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }
    return [];
  }

  static void _saveUnlocked(List<String> ids) {
    appdata.settings[_settingKey] = jsonEncode(ids);
    appdata.saveData();
  }

  /// 计算全部成就的进度（不落盘）。
  static List<AchievementProgress> progress([AchievementStats? stats]) {
    final s = stats ?? AchievementStats.compute();
    return all
        .map((a) => AchievementProgress(a, s.valueOf(a.metric)))
        .toList(growable: false);
  }

  /// 检查并持久化新解锁的成就，返回本次新解锁的列表。
  static List<Achievement> check() {
    final unlocked = unlockedIds;
    final stats = AchievementStats.compute();
    final newly = <Achievement>[];
    for (final achievement in all) {
      if (unlocked.contains(achievement.id)) {
        continue;
      }
      if (stats.valueOf(achievement.metric) >= achievement.target) {
        unlocked.add(achievement.id);
        newly.add(achievement);
      }
    }
    if (newly.isNotEmpty) {
      _saveUnlocked(unlocked);
    }
    return newly;
  }

  /// 阅读会话结束后调用，有新成就时给一条轻提示。
  static void checkAndNotify() {
    try {
      final newly = check();
      if (newly.isEmpty) {
        return;
      }
      App.rootContext.showMessage(
        message: newly.length == 1
            ? "Achievement unlocked: @a".tlParams({'a': newly.first.title.tl})
            : "Achievements unlocked: @a".tlParams({
                'a': newly.map((e) => e.title.tl).join('、'),
              }),
      );
    } catch (_) {
      // 成就统计失败不能影响阅读
    }
  }

  /// 进度文案：按计量单位换算成易读的数值。
  static String progressText(AchievementProgress p) {
    final target = p.achievement.target;
    final value = p.value;
    switch (p.achievement.metric) {
      case AchievementMetric.seconds:
      case AchievementMetric.nightSeconds:
        if (target >= 3600) {
          return "@a/@b h".tlParams({
            'a': _trim(value / 3600),
            'b': _trim(target / 3600),
          });
        }
        return "@a/@b min".tlParams({
          'a': (value ~/ 60).toString(),
          'b': (target ~/ 60).toString(),
        });
      case AchievementMetric.streak:
      case AchievementMetric.activeDays:
        return "@a/@b d".tlParams({
          'a': value.toString(),
          'b': target.toString(),
        });
      case AchievementMetric.comics:
      case AchievementMetric.imageFavorites:
        return "@a/@b".tlParams({
          'a': value.toString(),
          'b': target.toString(),
        });
    }
  }

  static String _trim(double v) {
    if (v == v.roundToDouble()) {
      return v.round().toString();
    }
    return v.toStringAsFixed(1);
  }
}
