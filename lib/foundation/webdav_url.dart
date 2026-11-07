/// 把 WebDAV 地址末尾的斜杠去掉。
///
/// `webdav_client` 是拿 path 直接拼在 baseUrl 后面的，地址留个 `/` 就变成
/// `.../dav//`，坚果云这类严格的实现不分青红皂白回 404，报错还只说
/// 「Not found」，从输入框完全看不出问题。所有进客户端的地方都要先过一遍。
String normalizeWebdavUrl(String url) {
  var normalized = url.trim();
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}
