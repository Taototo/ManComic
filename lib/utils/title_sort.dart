/// 漫画名称 A-Z 排序工具。
///
/// 拉丁字母直接取首字母；汉字通过 GBK 编码落入 GB2312 一级字库的拼音区段来
/// 推导首字母（GB2312 一级汉字本身就是按拼音排序的），因此同一首字母内再按
/// GBK 字节序比较即可得到接近拼音的先后顺序。
library;

import 'package:enough_convert/gbk.dart';

/// GB2312 一级汉字按拼音首字母划分的字节区间。
/// 每项为 (起始高字节, 起始低字节, 结束高字节, 结束低字节, 首字母)。
const List<(int, int, int, int, String)> _initialRanges = [
  (0xB0, 0xA1, 0xB0, 0xC4, 'A'),
  (0xB0, 0xC5, 0xB2, 0xC0, 'B'),
  (0xB2, 0xC1, 0xB4, 0xED, 'C'),
  (0xB4, 0xEE, 0xB6, 0xE9, 'D'),
  (0xB6, 0xEA, 0xB7, 0xA1, 'E'),
  (0xB7, 0xA2, 0xB8, 0xC0, 'F'),
  (0xB8, 0xC1, 0xB9, 0xFD, 'G'),
  (0xB9, 0xFE, 0xBB, 0xF6, 'H'),
  (0xBB, 0xF7, 0xBF, 0xA5, 'J'),
  (0xBF, 0xA6, 0xC0, 0xAB, 'K'),
  (0xC0, 0xAC, 0xC2, 0xE7, 'L'),
  (0xC2, 0xE8, 0xC4, 0xC2, 'M'),
  (0xC4, 0xC3, 0xC5, 0xB5, 'N'),
  (0xC5, 0xB6, 0xC5, 0xBD, 'O'),
  (0xC5, 0xBE, 0xC6, 0xD9, 'P'),
  (0xC6, 0xDA, 0xC8, 0xBA, 'Q'),
  (0xC8, 0xBB, 0xC8, 0xF5, 'R'),
  (0xC8, 0xF6, 0xCB, 0xF9, 'S'),
  (0xCB, 0xFA, 0xCD, 0xD9, 'T'),
  (0xCD, 0xDA, 0xCE, 0xF3, 'W'),
  (0xCE, 0xF4, 0xD1, 0xB8, 'X'),
  (0xD1, 0xB9, 0xD4, 0xD0, 'Y'),
  (0xD4, 0xD1, 0xD7, 0xF9, 'Z'),
];

const _openers = '[(（【〔［<＜《「『';
const _closers = '])）】〕］>＞》」』';

/// 去掉标题开头的括注（如 【汉化组】、[作者]），取第一个有效字符。
String _firstMeaningfulChar(String title) {
  var t = title.trim();
  var changed = true;
  while (changed && t.isNotEmpty) {
    changed = false;
    if (_openers.contains(t[0])) {
      var close = -1;
      for (var i = 1; i < t.length && i <= 30; i++) {
        if (_closers.contains(t[i])) {
          close = i;
          break;
        }
      }
      if (close > 0) {
        t = t.substring(close + 1).trimLeft();
        changed = true;
      }
    }
  }

  for (final rune in t.runes) {
    final isDigit = rune >= 0x30 && rune <= 0x39;
    final isUpper = rune >= 0x41 && rune <= 0x5A;
    final isLower = rune >= 0x61 && rune <= 0x7A;
    final isHan =
        (rune >= 0x4E00 && rune <= 0x9FFF) || (rune >= 0x3400 && rune <= 0x4DBF);
    if (isDigit || isUpper || isLower || isHan) {
      return String.fromCharCode(rune);
    }
  }
  return '';
}

bool _isAsciiLetter(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
}

bool _isDigit(String ch) {
  final c = ch.codeUnitAt(0);
  return c >= 0x30 && c <= 0x39;
}

/// 汉字 -> 拼音首字母，无法判断时返回 '#'
String _hanInitial(String ch) {
  List<int> bytes;
  try {
    bytes = gbk.encode(ch);
  } catch (_) {
    return '#';
  }
  if (bytes.length < 2) return '#';
  final hi = bytes[0];
  final lo = bytes[1];
  if (hi < 0xB0 || hi > 0xD7) return '#';
  for (final r in _initialRanges) {
    final (sh, sl, eh, el, letter) = r;
    final afterStart = hi > sh || (hi == sh && lo >= sl);
    final beforeEnd = hi < eh || (hi == eh && lo <= el);
    if (afterStart && beforeEnd) {
      return letter;
    }
  }
  return '#';
}

/// GBK 字节序字符串，用于同一首字母内部的先后比较（近似拼音序）。
String _gbkOrderKey(String text) {
  try {
    return String.fromCharCodes(gbk.encode(text));
  } catch (_) {
    return text.toLowerCase();
  }
}

/// 生成稳定的排序键：分组位 + 首字母 + 拼音序。
/// 数字优先，其次字母（含汉字首字母），其它符号（#）排最后。
String comicTitleSortKey(String title) {
  final ch = _firstMeaningfulChar(title);
  String rank;
  String letter;
  if (ch.isEmpty) {
    rank = '3';
    letter = '#';
  } else if (_isDigit(ch)) {
    rank = '0';
    letter = ch;
  } else if (_isAsciiLetter(ch)) {
    rank = '1';
    letter = ch.toUpperCase();
  } else {
    final initial = _hanInitial(ch);
    if (initial == '#') {
      rank = '3';
      letter = '#';
    } else {
      rank = '2';
      letter = initial;
    }
  }
  return '$rank$letter\u0001${_gbkOrderKey(title.trim())}';
}

/// 按漫画名称首字母 A-Z 排序，返回新列表。
List<T> sortByTitleAZ<T>(List<T> list, String Function(T) titleOf) {
  final keyed = list
      .map((e) => (e, comicTitleSortKey(titleOf(e))))
      .toList(growable: false);
  keyed.sort((a, b) => a.$2.compareTo(b.$2));
  return keyed.map((e) => e.$1).toList();
}

/// 按漫画名称首字母 Z-A 排序，返回新列表。
List<T> sortByTitleZA<T>(List<T> list, String Function(T) titleOf) {
  return sortByTitleAZ(list, titleOf).reversed.toList();
}

/// 排序方式取值：默认（手动/收藏顺序）
const titleSortDefault = 'default';

/// 排序方式取值：名称 A-Z
const titleSortAZ = 'name_az';

/// 排序方式取值：名称 Z-A
const titleSortZA = 'name_za';
