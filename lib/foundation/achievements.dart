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

  /// 单次阅读的最长时长（秒）
  sessionSeconds,

  /// 读过的不同漫画源数量
  sources,
}

/// 成就档位。
///
/// 参考 GitHub Achievements 那套「Default → Bronze → Silver → Gold」的分档思路：
/// 成就不是一次性点亮的图章，而是同一件事能做到多深。这里用四档
/// （青铜 / 白银 / 黄金 / 钻石），每档有自己的一套金属色与徽章外形细节，
/// 所以「升级」本身就能被一眼看出来，不需要额外的等级数字。
enum AchievementTier {
  /// 尚未点亮任何一档
  locked,

  bronze,

  silver,

  gold,

  diamond;

  /// 四档的总数，用来算「点亮了几档」。
  static const int tierCount = 4;

  bool get isUnlocked => this != AchievementTier.locked;

  /// 中文/英文档位名，也是翻译键。
  String get label => switch (this) {
        AchievementTier.locked => "Locked",
        AchievementTier.bronze => "Bronze",
        AchievementTier.silver => "Silver",
        AchievementTier.gold => "Gold",
        AchievementTier.diamond => "Diamond",
      };

  /// 徽章主色（渐变中段）。锁定时用不到，返回中性灰。
  Color get base => switch (this) {
        AchievementTier.locked => const Color(0xFF9AA3AD),
        AchievementTier.bronze => const Color(0xFFC07A4A),
        AchievementTier.silver => const Color(0xFFB9C3CE),
        AchievementTier.gold => const Color(0xFFE0AE3E),
        AchievementTier.diamond => const Color(0xFF63C3E8),
      };

  /// 高光色（渐变左上）。
  Color get light => switch (this) {
        AchievementTier.locked => const Color(0xFFC9CFD6),
        AchievementTier.bronze => const Color(0xFFE7B48B),
        AchievementTier.silver => const Color(0xFFF3F6F9),
        AchievementTier.gold => const Color(0xFFFFE7A0),
        AchievementTier.diamond => const Color(0xFFD6F4FF),
      };

  /// 暗部色（渐变右下）。
  Color get deep => switch (this) {
        AchievementTier.locked => const Color(0xFF6B7480),
        AchievementTier.bronze => const Color(0xFF8A4E24),
        AchievementTier.silver => const Color(0xFF78838F),
        AchievementTier.gold => const Color(0xFF9A6A0C),
        AchievementTier.diamond => const Color(0xFF2A7392),
      };

  /// 徽章上的图标颜色。金属底都比较亮，用深色描边感更清楚。
  Color get onBadge => switch (this) {
        AchievementTier.locked => const Color(0xFF8A939E),
        AchievementTier.bronze => const Color(0xFF3E2411),
        AchievementTier.silver => const Color(0xFF2C333B),
        AchievementTier.gold => const Color(0xFF4A3100),
        AchievementTier.diamond => const Color(0xFF0E3B4C),
      };

  /// 外发光颜色，越高的档越亮。
  Color get glow => switch (this) {
        AchievementTier.locked => Colors.transparent,
        AchievementTier.bronze => const Color(0xFFC07A4A),
        AchievementTier.silver => const Color(0xFFB9C3CE),
        AchievementTier.gold => const Color(0xFFE8B84B),
        AchievementTier.diamond => const Color(0xFF7FD3F0),
      };
}

/// 一个成就家族：同一件事的四个档位。
class AchievementFamily {
  const AchievementFamily({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.metric,
    required this.tiers,
  });

  /// 持久化用的稳定 id，不要修改
  final String id;

  /// 翻译键
  final String title;

  /// 翻译键，说明怎么涨进度
  final String description;

  final IconData icon;

  final AchievementMetric metric;

  /// 四档的门槛，从小到大
  final List<int> tiers;

  int get maxTarget => tiers.last;
}

/// 某个家族的当前进度。
class AchievementProgress {
  const AchievementProgress(this.family, this.value);

  final AchievementFamily family;

  final int value;

  /// 已点亮的档数，0 表示还没点亮。
  int get tierIndex {
    var count = 0;
    for (final target in family.tiers) {
      if (value >= target) {
        count++;
      } else {
        break;
      }
    }
    return count;
  }

  AchievementTier get tier => AchievementTier.values[tierIndex];

  bool get unlocked => tierIndex > 0;

  /// 下一档的门槛，已经满档时是 null。
  int? get nextTarget =>
      tierIndex >= AchievementTier.tierCount ? null : family.tiers[tierIndex];

  /// 当前档的门槛（未点亮时按 0 算），用来算档内进度。
  int get currentFloor => tierIndex == 0 ? 0 : family.tiers[tierIndex - 1];

  /// 距离下一档还有多远（0-1）。满档时恒为 1。
  double get ratioToNext {
    final next = nextTarget;
    if (next == null) {
      return 1;
    }
    final span = next - currentFloor;
    if (span <= 0) {
      return 1;
    }
    return ((value - currentFloor) / span).clamp(0.0, 1.0);
  }

  /// 距离下一档还差多少（按计量单位）。
  int get remainingToNext {
    final next = nextTarget;
    if (next == null) {
      return 0;
    }
    final left = next - value;
    return left < 0 ? 0 : left;
  }
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
    this.longestSessionSeconds = 0,
    this.sourceCount = 0,
  });

  final int totalSeconds;

  final int longestStreak;

  final int activeDays;

  final int comicCount;

  final int nightSeconds;

  final int imageFavoriteCount;

  final int longestSessionSeconds;

  final int sourceCount;

  factory AchievementStats.compute() {
    var total = 0;
    var night = 0;
    var longestSession = 0;
    final days = <String>{};
    final titles = <String>{};
    final sources = <String>{};
    try {
      for (final s in ReadingStats.allSessions()) {
        total += s.seconds;
        days.add(s.day);
        titles.add(s.title);
        if (s.source.isNotEmpty) {
          sources.add(s.source);
        }
        if (s.seconds > longestSession) {
          longestSession = s.seconds;
        }
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
      longestSessionSeconds: longestSession,
      sourceCount: sources.length,
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
      AchievementMetric.sessionSeconds => longestSessionSeconds,
      AchievementMetric.sources => sourceCount,
    };
  }
}

/// 一次升级：某个家族某一次跨到了新的一档。
class AchievementUpgrade {
  const AchievementUpgrade(this.family, this.tier);

  final AchievementFamily family;

  final AchievementTier tier;
}

/// 阅读成就：全部基于本地阅读记录与收藏数，不需要联网。
class Achievements {
  /// 家族 id → 已点亮档数。存 JSON，方便以后加档。
  static const String _settingKey = 'achievementTiers';

  /// 旧版本用过的一次性成就记录，升级后已经没有意义，顺手清掉。
  static const String _legacySettingKey = 'unlockedAchievements';

  static const List<AchievementFamily> all = [
    AchievementFamily(
      id: 'reading_time',
      title: 'Reading Time',
      description: 'Total time spent reading, across all sources.',
      icon: Icons.auto_stories_rounded,
      metric: AchievementMetric.seconds,
      // 1 小时 / 10 小时 / 50 小时 / 166 小时
      tiers: [3600, 36000, 180000, 600000],
    ),
    AchievementFamily(
      id: 'streak',
      title: 'Reading Streak',
      description: 'Longest run of consecutive days with reading.',
      icon: Icons.local_fire_department_rounded,
      metric: AchievementMetric.streak,
      tiers: [3, 7, 30, 100],
    ),
    AchievementFamily(
      id: 'active_days',
      title: 'Reading days',
      description: 'Days with a reading session, counted once per day.',
      icon: Icons.calendar_month_rounded,
      metric: AchievementMetric.activeDays,
      tiers: [7, 30, 100, 365],
    ),
    AchievementFamily(
      id: 'comics',
      title: 'Comics read',
      description: 'Different comics you have opened.',
      icon: Icons.menu_book_rounded,
      metric: AchievementMetric.comics,
      tiers: [5, 20, 50, 150],
    ),
    AchievementFamily(
      id: 'marathon',
      title: 'Marathon',
      description: 'Longest single reading session.',
      icon: Icons.hourglass_bottom_rounded,
      metric: AchievementMetric.sessionSeconds,
      // 30 分钟 / 1 小时 / 2 小时 / 4 小时
      tiers: [1800, 3600, 7200, 14400],
    ),
    AchievementFamily(
      id: 'night_owl',
      title: 'Night Owl',
      description: 'Reading between midnight and 5 AM.',
      icon: Icons.nightlight_round,
      metric: AchievementMetric.nightSeconds,
      // 5 小时 / 20 小时 / 50 小时 / 120 小时
      tiers: [18000, 72000, 180000, 432000],
    ),
    AchievementFamily(
      id: 'images',
      title: 'Image Collector',
      description: 'Images saved to your image favorites.',
      icon: Icons.collections_rounded,
      metric: AchievementMetric.imageFavorites,
      tiers: [50, 200, 500, 2000],
    ),
    AchievementFamily(
      id: 'sources',
      title: 'Source Explorer',
      description: 'Different comic sources you have read from.',
      icon: Icons.explore_rounded,
      metric: AchievementMetric.sources,
      tiers: [2, 5, 10, 20],
    ),
  ];

  /// 家族 id → 上次记录到的档数。
  static Map<String, int> get storedTiers {
    final raw = appdata.settings[_settingKey];
    Object? decoded = raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = null;
      }
    }
    if (decoded is Map) {
      return {
        for (final e in decoded.entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      };
    }
    return {};
  }

  static void _saveTiers(Map<String, int> tiers) {
    appdata.settings[_settingKey] = jsonEncode(tiers);
    // 旧版本的一次性成就记录置空：留着也不会再被读，但不该继续写进导出数据。
    appdata.settings[_legacySettingKey] = null;
    appdata.saveData();
  }

  /// 计算全部成就的进度（不落盘）。
  static List<AchievementProgress> progress([AchievementStats? stats]) {
    final s = stats ?? AchievementStats.compute();
    return all
        .map((f) => AchievementProgress(f, s.valueOf(f.metric)))
        .toList(growable: false);
  }

  /// 检查并持久化新跨过的档位，返回本次升级列表。
  static List<AchievementUpgrade> check() {
    final stored = storedTiers;
    final stats = AchievementStats.compute();
    final upgraded = <AchievementUpgrade>[];
    var changed = false;
    for (final family in all) {
      final reached = AchievementProgress(
        family,
        stats.valueOf(family.metric),
      ).tierIndex;
      final recorded = stored[family.id] ?? 0;
      if (reached <= recorded) {
        continue;
      }
      stored[family.id] = reached;
      changed = true;
      upgraded.add(AchievementUpgrade(family, AchievementTier.values[reached]));
    }
    if (changed) {
      _saveTiers(stored);
    }
    return upgraded;
  }

  /// 阅读会话结束后调用，有新成就时给一条轻提示。
  static void checkAndNotify() {
    try {
      final upgraded = check();
      if (upgraded.isEmpty) {
        return;
      }
      // 老版本的一次性成就换成四档后，历史数据会一次性跨好几档（甚至全部）。
      // 全列出来会是一条几百字的气泡，所以最多说三条。
      final text = [
        ...upgraded
            .take(3)
            .map((e) => "${e.family.title.tl} · ${e.tier.label.tl}"),
        if (upgraded.length > 3) "…",
      ].join("、");
      App.rootContext.showMessage(
        message: upgraded.length == 1
            ? "Achievement upgraded: @a".tlParams({'a': text})
            : "Achievements upgraded: @a".tlParams({'a': text}),
      );
    } catch (_) {
      // 成就统计失败不能影响阅读
    }
  }

  /// 已点亮的档数 / 总档数，用于顶部汇总。
  static ({int unlocked, int total}) summary(List<AchievementProgress> list) {
    var unlocked = 0;
    for (final p in list) {
      unlocked += p.tierIndex;
    }
    return (unlocked: unlocked, total: list.length * AchievementTier.tierCount);
  }

  /// 把秒数/天数/个数写成易读的数值，带上单位。
  static String valueText(AchievementMetric metric, int value) {
    switch (metric) {
      case AchievementMetric.seconds:
      case AchievementMetric.nightSeconds:
      case AchievementMetric.sessionSeconds:
        if (value < 60) {
          return "@a s".tlParams({'a': '$value'});
        }
        if (value < 3600) {
          return "@a min".tlParams({'a': '${value ~/ 60}'});
        }
        final hours = value / 3600;
        return "@a h".tlParams({'a': _trim(hours)});
      case AchievementMetric.streak:
      case AchievementMetric.activeDays:
        return "@a d".tlParams({'a': '$value'});
      case AchievementMetric.comics:
      case AchievementMetric.imageFavorites:
      case AchievementMetric.sources:
        return "@a".tlParams({'a': '$value'});
    }
  }

  /// 进度文案，例如 `12.4 / 50 h`。
  static String progressText(AchievementProgress p) {
    return "${valueText(p.family.metric, p.value)} / "
        "${valueText(p.family.metric, p.family.maxTarget)}";
  }

  static String _trim(double v) {
    if (v == v.roundToDouble()) {
      return v.round().toString();
    }
    return v.toStringAsFixed(1);
  }
}
