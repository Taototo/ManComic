/// 版本号工具，用于「关于」页面的更新检查。
///
/// 只处理形如 `1.2.3` / `1.2.3+build` / `v1.2.3` / `1.2.3-beta` 的版本串，
/// 遇到非数字段按 0 处理，避免远端写了非法版本号时崩溃。
library;

/// 归一化版本号：去掉 `v`/`V` 前缀与 `+build` 后缀。
///
/// 返回 null 表示归一化后为空串。
String? normalizeVersion(String raw) {
  var version = raw.trim();
  if (version.startsWith("v") || version.startsWith("V")) {
    version = version.substring(1);
  }
  version = version.split("+").first.trim();
  return version.isEmpty ? null : version;
}

/// 版本号比较，返回 true 表示 [version1] 高于 [version2]。
///
/// 只比较前 3 段数字，多余的段（如 `1.4.0.1`）与预发布后缀忽略。
bool compareVersion(String version1, String version2) {
  List<int> parse(String v) {
    var res = <int>[];
    for (var part in v.split(".")) {
      var digits = RegExp(r'^\d+').stringMatch(part);
      res.add(int.tryParse(digits ?? "") ?? 0);
    }
    while (res.length < 3) {
      res.add(0);
    }
    return res;
  }

  var v1 = parse(version1);
  var v2 = parse(version2);
  for (var i = 0; i < 3; i++) {
    if (v1[i] > v2[i]) {
      return true;
    }
    if (v1[i] < v2[i]) {
      return false;
    }
  }
  return false;
}

/// 从 GitHub releases 的 Atom 订阅源里取出最新版本的 tag。
///
/// 源里按时间倒序排列，第一处 `/releases/tag/<tag>` 就是最新版本。
/// 返回 null 表示没解析出来（源格式变了、或被代理返回了错误页）。
String? latestTagFromReleasesFeed(String xml) {
  var match = RegExp(r'/releases/tag/([^"<\s]+)').firstMatch(xml);
  return match?.group(1);
}
