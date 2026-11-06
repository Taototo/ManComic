/// 章节列表的搜索。
///
/// 单独抽出来是为了能测：搜索规则（尤其是「输入 380 直接跳到第 380 话」）
/// 一旦跟 UI 缠在一起就只能靠手点验证，而这种边界情况恰恰最容易错。
library;

/// 「第」「话」「章」「回」「卷」这类章号装饰词，以及 ch./ep. 前缀。
///
/// 匹配时不区分大小写，`\b` 不加：`ch380`、`Ch.380` 都要能认。
final RegExp _chapterAffix = RegExp(
  r'第|话|話|章|回|卷|級|级|chapters?|ch|episodes?|ep',
  caseSensitive: false,
);

/// 把「第380话」「Ch.380」「380」「第10卷 第380话」解析成章号。
///
/// 只认「纯章号」输入：去掉数字和装饰词之后还有别的字符（比如
/// 「番外篇 2」里的「番外篇」），就当它不是章号，交给标题匹配去处理，
/// 免得用户搜「2020」时因为章号 20 恰好存在而跳错地方。
///
/// 有多个数字时取**最后**一个：「第10卷 第380话」要的是 380，不是 10。
int? parseChapterNumber(String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final numbers = RegExp(r'\d+').allMatches(trimmed).toList();
  if (numbers.isEmpty) {
    return null;
  }
  final leftover = trimmed
      .replaceAll(RegExp(r'\d+'), '')
      .replaceAll(_chapterAffix, '')
      .replaceAll(RegExp(r'[\s#.、,，-]'), '');
  if (leftover.isNotEmpty) {
    return null;
  }
  return int.tryParse(numbers.last.group(0)!);
}

/// 返回命中的章节下标（0 起，与 `toChapter(index + 1)` 对齐）。
///
/// 顺序是「章号命中的排最前，然后是按标题匹配的」——用户输入 `380` 时
/// 想要的就是第 380 话，不该让它淹没在一堆标题里含「380」的条目中间。
///
/// 空查询返回全部下标，方便调用方直接复用同一套渲染逻辑。
List<int> searchChapters(List<String> titles, String query) {
  final q = query.trim();
  if (q.isEmpty) {
    return List<int>.generate(titles.length, (i) => i);
  }
  final result = <int>[];
  final seen = <int>{};

  final number = parseChapterNumber(q);
  if (number != null && number >= 1 && number <= titles.length) {
    result.add(number - 1);
    seen.add(number - 1);
  }

  final lowered = q.toLowerCase();
  for (var i = 0; i < titles.length; i++) {
    if (seen.contains(i)) {
      continue;
    }
    if (titles[i].toLowerCase().contains(lowered)) {
      result.add(i);
    }
  }
  return result;
}
