import 'dart:convert';

/// 按 key 复用同一个昂贵对象。
///
/// 存在的理由见 `RHttpAdapter` 那段注释：rhttp 每次请求都新建 client，就等于
/// 每次重新做 TCP + TLS 握手，一本几百页的漫画会握手几百次，被 CDN 按 IP
/// 限流直接掐断（`tls handshake eof`）。
///
/// 这里收口两件事：
/// 1. key 不变就返回同一个实例；
/// 2. 并发进来的请求共用**同一次**创建。少了这一条，开局的 N 个并发还是
///    会建出 N 个实例，等于又回到每次握手。
///
/// 单独成类是为了能测：rhttp 的 Rust 库在 `flutter test` 里加载不了，
/// 没办法真的建一个 client，但复用逻辑本身跟 rhttp 无关。
class ReusableClient<T extends Object> {
  T? _value;

  String? _key;

  Future<T>? _pending;

  String? _pendingKey;

  /// 当前缓存的实例（可能还没有）。
  T? get value => _value;

  /// 当前缓存实例对应的 key。
  String? get key => _key;

  /// 取 [key] 对应的实例；没有、或 key 变了就调用 [create] 新建一个。
  ///
  /// 创建失败不会把失败结果留下，下一次调用会重新尝试。
  Future<T> acquire(String key, Future<T> Function() create) async {
    var value = _value;
    if (value != null && _key == key) {
      return value;
    }

    var pending = _pending;
    if (pending != null && _pendingKey == key) {
      return pending;
    }

    var future = create();
    _pending = future;
    _pendingKey = key;
    try {
      var created = await future;
      _value = created;
      _key = key;
      return created;
    } finally {
      // 只清自己这一次。创建期间又有人换了 key，那边会自己接管。
      if (identical(_pending, future)) {
        _pending = null;
        _pendingKey = null;
      }
    }
  }

  /// 丢掉缓存。已经拿到旧实例的调用方不受影响，只是下一个请求会新建。
  void clear() {
    _value = null;
    _key = null;
  }
}

/// 影响 Rust 侧 client 的配置指纹。
///
/// 只有会改变连接池 / TLS 行为的配置进来：代理、SNI、证书校验、DNS 覆盖。
/// 请求级的 UA、header、cookie 不能进——否则每换一个站点就重建一次 client，
/// 连接池白攒。
///
/// 集合类先排序再编码：Map 的插入顺序不该让「配置变没变」判断抖动，抖一次
/// 就要重建 client、重新握手一轮。
String rhttpSettingsKey({
  required String? proxy,
  required bool sni,
  required bool verifyCertificates,
  required Map<String, List<String>> dnsOverrides,
}) {
  var hosts = dnsOverrides.keys.toList()..sort();
  return jsonEncode({
    'proxy': proxy,
    'sni': sni,
    'verify': verifyCertificates,
    'dns': {
      for (var host in hosts)
        host: (dnsOverrides[host]!.toList()..sort()),
    },
  });
}
