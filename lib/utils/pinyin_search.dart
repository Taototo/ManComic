/// 标题搜索匹配：中文子串 + 拼音全拼 + 首字母缩写。
///
/// 例：《妖怪人》 可以被 "妖怪""yaoguairen""ygr" 命中。
/// 只有纯字母查询才会走拼音匹配，避免中文关键词被误判。
library;

import 'package:lpinyin/lpinyin.dart';

final _fullCache = <String, String>{};

final _shortCache = <String, String>{};

const _cacheLimit = 600;

String _cached(Map<String, String> cache, String key, String Function() build) {
  final hit = cache[key];
  if (hit != null) {
    return hit;
  }
  final value = build();
  if (cache.length > _cacheLimit) {
    cache.clear();
  }
  cache[key] = value;
  return value;
}

/// 标题全拼（无声调，连写）
String titleFullPinyin(String title) {
  return _cached(_fullCache, title, () {
    try {
      return PinyinHelper.getPinyinE(
        title,
        separator: '',
        defPinyin: '#',
        format: PinyinFormat.WITHOUT_TONE,
      ).toLowerCase();
    } catch (_) {
      return '';
    }
  });
}

/// 标题拼音首字母缩写
String titleShortPinyin(String title) {
  return _cached(_shortCache, title, () {
    try {
      return PinyinHelper.getShortPinyin(title).toLowerCase();
    } catch (_) {
      return '';
    }
  });
}

final _asciiWord = RegExp(r'^[a-z0-9]+$');

/// 判断标题是否命中查询词。
///
/// [query] 已经是小写时传 [normalized] 为 true 可以少做一次转换。
bool titleMatchesQuery(String title, String query, {bool normalized = false}) {
  final q = normalized ? query : query.toLowerCase();
  if (q.isEmpty) return true;
  final t = title.toLowerCase();
  if (t.contains(q)) return true;
  if (!_asciiWord.hasMatch(q)) return false;
  // 纯数字查询没必要走拼音
  if (RegExp(r'^[0-9]+$').hasMatch(q)) return false;
  return titleFullPinyin(title).contains(q) ||
      titleShortPinyin(title).contains(q);
}
