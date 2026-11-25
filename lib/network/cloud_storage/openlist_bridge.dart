import 'dart:convert';

import 'package:flutter/services.dart';

import 'openlist_rpc.dart';

/// 嵌入式网盘内核的 Dart 桥。
///
/// Android 走 MethodChannel `mancomi/openlist`：原生侧再把请求转发到
/// `:openlist` 独立进程（那里加载 Go 内核，和主进程的 Xray 物理隔离）。
/// 桌面 / iOS 目前没有内核二进制，调用会返回 unavailable，功能自动隐藏。
class EmbeddedOpenListRpc implements OpenListRpcClient {
  static const _channelName = 'mancomi/openlist';

  EmbeddedOpenListRpc({MethodChannel? channel, Duration? timeout})
    : _channel = channel ?? const MethodChannel(_channelName),
      _timeout = timeout;

  final MethodChannel _channel;

  /// 仅供测试注入；正式运行时按方法取默认值。
  final Duration? _timeout;

  Duration _timeoutFor(String method) =>
      _timeout ??
      (method == 'initialize'
          ? const Duration(seconds: 75)
          : const Duration(seconds: 40));

  static Future<bool>? _available;

  /// 内核在当前平台是否可用（决定网盘功能入口是否显示）。
  static Future<bool> available() {
    return _available ??= const MethodChannel(_channelName)
        .invokeMethod<bool>('available')
        .then((v) => v ?? false, onError: (_, __) => false);
  }

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    final message = jsonEncode({'method': method, 'arguments': request});
    try {
      // 原生侧自己也有超时；这里只是兜底——通道异常、进程被杀等情况下
      // 不能让 Future 永远不完成，否则界面会一直转圈。
      final response = await _channel
          .invokeMethod<String>('invoke', {'request': message})
          .timeout(_timeoutFor(method), onTimeout: () => null);
      if (response == null) {
        return {
          'error': {'code': 'timeout', 'message': '网盘内核无响应（超时）'},
        };
      }
      return _decode(response);
    } catch (error) {
      return {
        'error': {'code': 'unavailable', 'message': '$error'},
      };
    }
  }

  static Map<String, dynamic> _decode(String? response) {
    if (response == null || response.isEmpty) {
      return const {
        'error': {'code': 'invalid_response', 'message': '内核返回为空'},
      };
    }
    try {
      final value = jsonDecode(response);
      if (value is Map) {
        return value.map((key, item) => MapEntry('$key', item));
      }
    } catch (_) {}
    return const {
      'error': {'code': 'invalid_response', 'message': '内核返回格式错误'},
    };
  }
}
