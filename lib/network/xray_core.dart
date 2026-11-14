import 'dart:convert';

import 'package:flutter/services.dart';

/// libXray（Xray-core 的 gomobile 封装）的原生桥。
///
/// 原生侧只有 `invoke(String requestJSON)` 一个入口，请求长这样：
/// ```json
/// {"apiVersion":3,"method":"runXray","payload":{"xrayJson":"..."}}
/// ```
/// 响应统一是 `{"success":bool,"data":...,"error":"..."}`。这里把 int 常量和
/// 字符串拼装全部收口，调用点只写 `XrayCore.runXray(config)`。
class XrayCore {
  XrayCore._();

  static const _channel = MethodChannel('mancomi/xray');

  static Future<bool>? _available;

  /// 核心能不能加载。
  ///
  /// 加载失败（这台机器的 ABI 没有对应 .so、或者有第二个 Go runtime 抢加载）
  /// 就返回 false，「内置代理」整个功能该藏起来，而不是让用户点了一路报错。
  static Future<bool> available() {
    return _available ??= _channel
        .invokeMethod<bool>('available')
        .then((v) => v ?? false, onError: (_, __) => false);
  }

  static Future<Map<String, dynamic>> _invoke(
    String method, [
    Map<String, dynamic> payload = const {},
  ]) async {
    final raw = await _channel.invokeMethod<String>('invoke', {
      'method': method,
      'payload': jsonEncode(payload),
    });
    if (raw == null || raw.isEmpty) {
      throw XrayException('$method: 没有返回');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw XrayException('$method: 返回格式不对');
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map['success'] != true) {
      throw XrayException(
        (map['error'] as String?)?.trim().isNotEmpty == true
            ? map['error'] as String
            : '$method 失败',
      );
    }
    final data = map['data'];
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  static Future<String> version() async {
    final data = await _invoke('xrayVersion');
    return (data['version'] ?? '').toString();
  }

  /// 订阅文本 → 明文。base64 / age 包装都由核心处理，Dart 侧不用自己猜。
  static Future<String> decodeSubscription(String text) async {
    final data = await _invoke('decodeSubscriptionText', {'text': text});
    return (data['text'] ?? '').toString();
  }

  /// 分享链接（每行一条）→ outbounds 列表。
  ///
  /// 核心只认 VMessAEAD / VLESS / Hysteria2 / SS / SOCKS / Trojan，老式
  /// `vmess://base64` 会被丢掉，那部分由 Dart 侧补（见 subscription.dart）。
  /// 返回的 data 到底是 `{outbounds:[...]}` 还是 `{xrayJson:"..."}` 两种形态都
  /// 兼容，免得跟着上游小版本变一次就全挂。
  static Future<List<Map<String, dynamic>>> convertLinks(String text) async {
    final data = await _invoke('convertShareLinksToXrayJson', {'text': text});
    return outboundsFromData(data);
  }

  static List<Map<String, dynamic>> outboundsFromData(
    Map<String, dynamic> data,
  ) {
    final direct = data['outbounds'];
    if (direct is List) {
      return [
        for (final e in direct)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    final raw = data['xrayJson'] ?? data['json'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map && json['outbounds'] is List) {
          return [
            for (final e in json['outbounds'] as List)
              if (e is Map) Map<String, dynamic>.from(e),
          ];
        }
      } catch (_) {}
    }
    return [];
  }

  static Future<List<int>> freePorts(int count) async {
    final data = await _invoke('getFreePorts', {'count': count});
    final ports = data['ports'];
    if (ports is! List) {
      return [];
    }
    return [
      for (final p in ports)
        if (p is num) p.toInt(),
    ];
  }

  static Future<void> runXray(String configJson) async {
    await _invoke('runXray', {'xrayJson': configJson});
  }

  static Future<void> stopXray() async {
    await _invoke('stopXray');
  }

  static Future<bool> isRunning() async {
    final data = await _invoke('getXrayState');
    return data['running'] == true;
  }
}

class XrayException implements Exception {
  XrayException(this.message);

  final String message;

  @override
  String toString() => message;
}
