import 'dart:convert';

import 'package:venera/foundation/webdav_url.dart' show normalizeWebdavUrl;
import 'package:venera/network/app_dio.dart' show RHttpAdapter;
import 'package:webdav_client/webdav_client.dart' hide File;

export 'package:venera/foundation/webdav_url.dart' show normalizeWebdavUrl;

/// ManComi 版 WebDAV 端点。
///
/// Venera-Plus 的 `network/webdav.dart` 没有移植过来，这里补齐移植代码用到
/// 的那部分 API：建客户端（走 ManComi 的 RHttpAdapter，继承内置代理/DNS/
/// SNI 设置）、拼直链、以及远端库用的路径工具。
class WebDavEndpoint {
  const WebDavEndpoint({
    required this.url,
    required this.user,
    required this.password,
  });

  final String url;
  final String user;
  final String password;

  bool get isValid {
    final uri = Uri.tryParse(normalizeWebdavUrl(url));
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// 用 ManComi 的网络栈建客户端。
  ///
  /// `WdDio` 没有挂 `MyLogInterceptor`（凭据不会进日志），所以不需要额外的
  /// `extra['redactLog']`；`RHttpAdapter` 自己读内置代理设置。
  Client createClient({bool reuseConnections = false}) => newClient(
    normalizeWebdavUrl(url),
    user: user,
    password: password,
    adapter: RHttpAdapter(),
  );

  /// 供图片/压缩包直链请求用的 Basic 头。未设用户名时不带鉴权头。
  Map<String, String> get authHeaders {
    if (user.isEmpty && password.isEmpty) return const {};
    return {
      'authorization':
          'Basic ${base64Encode(utf8.encode('$user:$password'))}',
    };
  }

  /// 把远端路径拼成可直连的绝对 URL（保留目录结构，逐段转义）。
  String fileUrl(String remotePath) {
    final base = normalizeWebdavUrl(url);
    final encoded = _normalizeFilePath(remotePath)
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return '$base$encoded';
  }
}

/// 文件路径不带末尾的 `/`（和目录 helper 区分开，否则直链会 404）。
String _normalizeFilePath(String path) {
  var value = path.trim().replaceAll('\\', '/');
  if (!value.startsWith('/')) value = '/$value';
  final segments = <String>[];
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

/// 目录路径统一成「首尾都带 /」的形式。
String normalizeWebDavDirectoryPath(String path, {String fallback = '/'}) {
  var value = path.trim().replaceAll('\\', '/');
  if (value.isEmpty) value = fallback;
  if (!value.startsWith('/')) value = '/$value';
  if (!value.endsWith('/')) value = '$value/';
  final segments = <String>[];
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.isEmpty ? '/' : '/${segments.join('/')}/';
}

/// 目录 + 文件名 → 远端文件路径。
String joinWebDavFilePath(String parent, String name) =>
    _normalizeFilePath('$parent/$name');

/// 目录 + 子目录名 → 远端目录路径。
String joinWebDavDirectoryPath(String parent, String name) =>
    normalizeWebDavDirectoryPath('$parent/$name');
