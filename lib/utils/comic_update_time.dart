import 'dart:async';
import 'dart:convert';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// 标签里可能承载更新时间的命名空间
const _updateTagKeys = [
  '更新',
  '最後更新',
  '最后更新',
  '更新时间',
  'update',
  'updated',
  'last update',
  'lastupdate',
  'last_update',
];

final _absoluteDate = RegExp(
  r'(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})',
);

final _shortDate = RegExp(r'^(\d{1,2})\s*[-/月]\s*(\d{1,2})$');

final _relative = RegExp(r'(\d+)\s*(分钟|小时|天|日|周|个?月|年)\s*前');

/// 从一段文本里尽力解析出日期（只取到「天」）。
DateTime? parseComicDate(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // 纯数字：毫秒或秒级时间戳
  final numeric = int.tryParse(text);
  if (numeric != null && text.length >= 10) {
    final ms = text.length >= 13 ? numeric : numeric * 1000;
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    if (time.year >= 2000 && time.year <= 3000) {
      return DateTime(time.year, time.month, time.day);
    }
    return null;
  }

  // 相对时间：3天前 / 5小时前 / 2个月前
  final rel = _relative.firstMatch(text);
  if (rel != null) {
    final value = int.tryParse(rel.group(1)!) ?? 0;
    final unit = rel.group(2)!;
    final now = DateTime.now();
    final Duration offset;
    if (unit.contains('分')) {
      offset = Duration(minutes: value);
    } else if (unit.contains('小时')) {
      offset = Duration(hours: value);
    } else if (unit.contains('周')) {
      offset = Duration(days: value * 7);
    } else if (unit.contains('月')) {
      offset = Duration(days: value * 30);
    } else if (unit.contains('年')) {
      offset = Duration(days: value * 365);
    } else {
      offset = Duration(days: value);
    }
    final time = now.subtract(offset);
    return DateTime(time.year, time.month, time.day);
  }

  // 2026-10-30 / 2026年10月30日
  final abs = _absoluteDate.firstMatch(text);
  if (abs != null) {
    final year = int.tryParse(abs.group(1)!);
    final month = int.tryParse(abs.group(2)!);
    final day = int.tryParse(abs.group(3)!);
    if (year != null &&
        month != null &&
        day != null &&
        month >= 1 &&
        month <= 12 &&
        day >= 1 &&
        day <= 31) {
      return DateTime(year, month, day);
    }
  }

  // 只有 10-30 这种短日期时，补上今年
  final short = _shortDate.firstMatch(text);
  if (short != null) {
    final month = int.tryParse(short.group(1)!);
    final day = int.tryParse(short.group(2)!);
    if (month != null && day != null && month >= 1 && month <= 12) {
      final now = DateTime.now();
      return DateTime(now.year, month, day);
    }
  }

  return null;
}

/// 漫画更新时间的本地缓存。
///
/// 很多源的列表接口不返回更新时间，角标就显示不出来；但详情页有。
/// 进入过详情页的漫画在这里记录一次，之后列表里就有角标了，
/// 用得越久覆盖越全。缓存存独立文件，不混进会云同步的 settings。
class ComicUpdateTimeCache {
  ComicUpdateTimeCache._();

  static final ComicUpdateTimeCache instance = ComicUpdateTimeCache._();

  final Map<String, String> _map = {};

  File? _file;

  Timer? _saveTimer;

  File get file =>
      _file ??= File(FilePath.join(App.dataPath, 'update_time_cache.json'));

  bool _loaded = false;

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      if (file.existsSync()) {
        var data = jsonDecode(file.readAsStringSync());
        if (data is Map) {
          data.forEach((key, value) {
            if (key is String && value is String) {
              _map[key] = value;
            }
          });
        }
      }
    } catch (e) {
      // 缓存损坏不致命，忽略即可
    }
  }

  DateTime? get(String sourceKey, String id) {
    _ensureLoaded();
    final raw = _map["$sourceKey/$id"];
    if (raw == null) return null;
    return parseComicDate(raw);
  }

  void put(String sourceKey, String id, String rawTime) {
    final time = parseComicDate(rawTime);
    if (time == null) return;
    _ensureLoaded();
    final value =
        "${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}";
    final key = "$sourceKey/$id";
    if (_map[key] == value) return;
    _map[key] = value;
    // 防抖落盘：连续浏览详情页时不会每页写一次文件
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () {
      try {
        file.writeAsStringSync(jsonEncode(_map));
      } catch (e) {
        Log.error("UpdateTimeCache", "Failed to save: $e");
      }
    });
  }
}

/// 从列表页的数据里尽力找出这条漫画的最近更新时间。
///
/// 优先级：追更记录里的更新时间 → 详情页缓存的更新时间 → 标签里的
/// 「更新」命名空间 → 副标题/简介。源没有提供时间时返回 null，
/// 调用方据此不显示角标。
DateTime? findComicUpdateTime(Comic comic) {
  if (comic is FavoriteItemWithUpdateInfo) {
    final time = parseComicDate(comic.updateTime ?? '');
    if (time != null) return time;
  }

  final cached = ComicUpdateTimeCache.instance.get(comic.sourceKey, comic.id);
  if (cached != null) return cached;

  for (final tag in comic.tags ?? const <String>[]) {
    final index = tag.indexOf(':');
    if (index <= 0) continue;
    final key = tag.substring(0, index).trim().toLowerCase();
    if (_updateTagKeys.contains(key)) {
      final time = parseComicDate(tag.substring(index + 1));
      if (time != null) return time;
    }
  }

  final subtitle = comic.subtitle?.replaceAll('\n', '').trim();
  if (subtitle != null && subtitle.isNotEmpty && subtitle.length <= 40) {
    final time = parseComicDate(subtitle);
    if (time != null) return time;
  }

  final description = comic.description.replaceAll('\n', ' ').trim();
  if (description.isNotEmpty && description.length <= 60) {
    final time = _absoluteDate.firstMatch(description);
    if (time != null) {
      return parseComicDate(time.group(0)!);
    }
  }

  return null;
}

/// 缩略图角标文案：今天 / 昨天 / N天前 / MM-dd
String? formatComicUpdateBadge(DateTime? time) {
  if (time == null) return null;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(time.year, time.month, time.day);
  final days = today.difference(target).inDays;
  if (days <= 0) return "Today".tl;
  if (days == 1) return "Yesterday".tl;
  if (days < 7) return "@a d ago".tlParams({'a': days.toString()});
  final month = target.month.toString().padLeft(2, '0');
  final day = target.day.toString().padLeft(2, '0');
  if (target.year == now.year) return "$month-$day";
  return "${target.year}-$month-$day";
}
