import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'remote_file_store.dart';

/// 夸克网盘的原生上传实现（纯 Dart）。
///
/// 为什么需要它：内核（OpenList）上传时把 MIME 当作 `format_type` 传给
/// `/file/upload/pre`。移动端桥接构造的文件流没有 MIME，而 `.cbz` 这类
/// 扩展名也不在 Go 的 MIME 表里，于是 `format_type` 为空，夸克直接返回
/// `Bad Parameter：[format_type is null!]`。内核是预编译的 so，改不了，
/// 所以在应用侧按夸克的分片协议补一条上传通道。
///
/// 流程与 OpenList 的 quark_uc 驱动保持一致：
/// `upload/pre` → `update/hash`（秒传）→ 分片 PUT → OSS complete → `upload/finish`。
class QuarkUploader {
  QuarkUploader({
    required this.cookie,
    String? userAgent,
    HttpClient? client,
    this.apiBase = 'https://drive.quark.cn/1/clouddrive',
    this.timeout = const Duration(seconds: 40),
  }) : userAgent = userAgent ?? desktopUserAgent,
       _client = client ?? HttpClient()..connectionTimeout = const Duration(seconds: 20),
       _ownsClient = client == null;

  static const desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/133.0.0.0 Safari/537.36';

  static const _referer = 'https://pan.quark.cn/';
  static const _ossUserAgent =
      'aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit';

  final String cookie;
  final String userAgent;
  final String apiBase;
  final Duration timeout;
  final HttpClient _client;
  final bool _ownsClient;

  /// 只为夸克账号创建上传器；其他网盘或缺少 Cookie 时返回 null。
  static QuarkUploader? forAccount(StorageAccount account) {
    if (account.backend != StorageBackend.openlist) return null;
    if (account.driver != 'Quark' && account.driver != 'QuarkOpen') {
      return null;
    }
    final cookie = account.authorization['cookie'];
    if (cookie is! String || cookie.trim().isEmpty) return null;
    return QuarkUploader(cookie: cookie);
  }

  /// 内核是否因为拿不到 MIME 而被夸克拒绝——这类失败才值得改道重传。
  static bool isMissingFormatType(Object error) {
    final message = error is RemoteStorageException
        ? error.message
        : error.toString();
    return message.contains('format_type');
  }

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  /// 上传本地文件到 [remotePath]（形如 `/备份目录/xxx.cbz`）。
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) async {
    final file = File(localPath);
    if (!await file.exists()) {
      throw const RemoteStorageException('本地文件不存在，无法上传');
    }
    final size = await file.length();
    final remote = _splitRemotePath(remotePath);
    final parentId = await _resolveDirectoryId(remote.directory);
    final mimeType = mimeTypeForName(remote.name);
    final total = size;

    void report(int completed) => onProgress?.call(
      RemoteTransferProgress(
        taskId: 'quark-upload',
        completed: completed,
        total: total,
      ),
    );
    report(0);

    final pre = await _post('/file/upload/pre', {
      'ccp_hash_update': true,
      'dir_name': '',
      'file_name': remote.name,
      // 关键字段：绝不能为空，否则夸克报 format_type is null!
      'format_type': mimeType,
      'l_created_at': DateTime.now().millisecondsSinceEpoch,
      'l_updated_at': DateTime.now().millisecondsSinceEpoch,
      'pdir_fid': parentId,
      'size': size,
    });
    final data = _mapOf(pre['data']);
    final metadata = _mapOf(pre['metadata']);
    final taskId = _stringOf(data['task_id']);
    if (taskId.isEmpty) {
      throw const RemoteStorageException('夸克没有返回上传任务，请稍后重试');
    }

    // 秒传：服务端按 md5/sha1 命中已有文件时直接完成。
    final md5Digest = await md5.bind(file.openRead()).first;
    final sha1Digest = await sha1.bind(file.openRead()).first;
    final hashResult = await _post('/file/update/hash', {
      'md5': md5Digest.toString(),
      'sha1': sha1Digest.toString(),
      'task_id': taskId,
    });
    if (_mapOf(hashResult['data'])['finish'] == true) {
      report(total);
      return;
    }

    final partSize = (metadata['part_size'] as num?)?.toInt();
    final chunk = partSize != null && partSize > 0
        ? partSize
        : 4 * 1024 * 1024;
    final bucket = _stringOf(data['bucket']);
    final objKey = _stringOf(data['obj_key']);
    final uploadUrl = _stringOf(data['upload_url']);
    final uploadId = _stringOf(data['upload_id']);
    final authInfo = _stringOf(data['auth_info']);
    if (objKey.isEmpty || uploadUrl.isEmpty) {
      throw const RemoteStorageException('夸克返回的上传地址不完整，请稍后重试');
    }

    final partCount = size == 0 ? 0 : (size + chunk - 1) ~/ chunk;
    final etags = <String>[];
    for (var index = 0; index < partCount; index++) {
      final offset = index * chunk;
      final length = (size - offset) > chunk ? chunk : (size - offset);
      final bytes = await _readChunk(file, offset, length);
      final etag = await _uploadPart(
        data: data,
        mimeType: mimeType,
        partNumber: index + 1,
        bytes: bytes,
      );
      etags.add(etag);
      report(offset + length);
    }

    await _complete(
      data: data,
      etags: etags,
      bucket: bucket,
      objKey: objKey,
      uploadUrl: uploadUrl,
      uploadId: uploadId,
      authInfo: authInfo,
      taskId: taskId,
    );
    await _post('/file/upload/finish', {
      'obj_key': objKey,
      'task_id': taskId,
    });
    // 夸克落库有短暂延迟，稍等一下让随后的列表能刷到。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    report(total);
  }

  /// 按夸克 pre 的约定推断 MIME；未知扩展名回退到二进制流，绝不能为空。
  static String mimeTypeForName(String name) {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return _mimeTypes[extension] ?? 'application/octet-stream';
  }

  Future<List<int>> _readChunk(File file, int offset, int length) async {
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }

  Future<String> _uploadPart({
    required Map<String, dynamic> data,
    required String mimeType,
    required int partNumber,
    required List<int> bytes,
  }) async {
    final bucket = _stringOf(data['bucket']);
    final objKey = _stringOf(data['obj_key']);
    final uploadId = _stringOf(data['upload_id']);
    final time = _httpDate(DateTime.now().toUtc());
    final authMeta =
        'PUT\n\n$mimeType\n$time\n'
        'x-oss-date:$time\n'
        'x-oss-user-agent:$_ossUserAgent\n'
        '/$bucket/$objKey?partNumber=$partNumber&uploadId=$uploadId';
    final authKey = await _authorize(
      authInfo: _stringOf(data['auth_info']),
      authMeta: authMeta,
      taskId: _stringOf(data['task_id']),
    );
    final url =
        '${_objectBase(_stringOf(data['upload_url']), bucket)}/$objKey'
        '?partNumber=$partNumber&uploadId=$uploadId';
    final response = await _sendRaw(
      'PUT',
      Uri.parse(url),
      headers: {
        'Authorization': authKey,
        'Content-Type': mimeType,
        'Referer': _referer,
        'x-oss-date': time,
        'x-oss-user-agent': _ossUserAgent,
      },
      body: bytes,
    );
    if (response.statusCode != 200) {
      throw RemoteStorageException(
        '分片 $partNumber 上传失败（HTTP ${response.statusCode}）：${_brief(response.body)}',
      );
    }
    return response.headers['etag'] ?? '';
  }

  Future<void> _complete({
    required Map<String, dynamic> data,
    required List<String> etags,
    required String bucket,
    required String objKey,
    required String uploadUrl,
    required String uploadId,
    required String authInfo,
    required String taskId,
  }) async {
    final buffer = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<CompleteMultipartUpload>\n');
    for (var index = 0; index < etags.length; index++) {
      buffer.write(
        '<Part>\n<PartNumber>${index + 1}</PartNumber>\n'
        '<ETag>${etags[index]}</ETag>\n</Part>\n',
      );
    }
    buffer.write('</CompleteMultipartUpload>');
    final xml = buffer.toString();
    final contentMd5 = base64Encode(md5.convert(utf8.encode(xml)).bytes);

    final callback = _mapOf(data['callback']);
    final callbackBase64 = base64Encode(
      utf8.encode(
        jsonEncode({
          'callbackUrl': _stringOf(callback['callbackUrl']),
          'callbackBody': _stringOf(callback['callbackBody']),
        }),
      ),
    );
    final time = _httpDate(DateTime.now().toUtc());
    final authMeta =
        'POST\n$contentMd5\napplication/xml\n$time\n'
        'x-oss-callback:$callbackBase64\n'
        'x-oss-date:$time\n'
        'x-oss-user-agent:$_ossUserAgent\n'
        '/$bucket/$objKey?uploadId=$uploadId';
    final authKey = await _authorize(
      authInfo: authInfo,
      authMeta: authMeta,
      taskId: taskId,
    );
    final url =
        '${_objectBase(uploadUrl, bucket)}/$objKey?uploadId=$uploadId';
    final response = await _sendRaw(
      'POST',
      Uri.parse(url),
      headers: {
        'Authorization': authKey,
        'Content-MD5': contentMd5,
        'Content-Type': 'application/xml',
        'Referer': _referer,
        'x-oss-callback': callbackBase64,
        'x-oss-date': time,
        'x-oss-user-agent': _ossUserAgent,
      },
      body: utf8.encode(xml),
    );
    if (response.statusCode != 200) {
      throw RemoteStorageException(
        '合并分片失败（HTTP ${response.statusCode}）：${_brief(response.body)}',
      );
    }
  }

  Future<String> _authorize({
    required String authInfo,
    required String authMeta,
    required String taskId,
  }) async {
    final response = await _post('/file/upload/auth', {
      'auth_info': authInfo,
      'auth_meta': authMeta,
      'task_id': taskId,
    });
    final key = _stringOf(_mapOf(response['data'])['auth_key']);
    if (key.isEmpty) {
      throw const RemoteStorageException('夸克拒绝了上传授权，请重新授权账号');
    }
    return key;
  }

  /// 逐级解析目录名到夸克的 fid（根目录为 "0"）。
  Future<String> _resolveDirectoryId(String directory) async {
    var fid = '0';
    for (final segment in directory.split('/')) {
      if (segment.isEmpty) continue;
      final child = await _findChildId(fid, segment);
      if (child == null) {
        throw RemoteStorageException('网盘目录不存在：$segment');
      }
      fid = child;
    }
    return fid;
  }

  Future<String?> _findChildId(String parentId, String name) async {
    var page = 1;
    while (true) {
      final response = await _get('/file/sort', {
        'pr': 'ucpro',
        'fr': 'pc',
        'pdir_fid': parentId,
        '_page': '$page',
        '_size': '100',
        '_fetch_total': '1',
        'fetch_all_file': '1',
      });
      final list = _mapOf(response['data'])['list'];
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          final fileName = htmlUnescape(_stringOf(item['file_name']));
          if (fileName == name && item['file'] != true) {
            final id = _stringOf(item['fid']);
            if (id.isNotEmpty) return id;
          }
        }
      }
      final total = (_mapOf(response['metadata'])['_total'] as num?)?.toInt();
      if (total == null || page * 100 >= total) return null;
      page++;
    }
  }

  Future<Map<String, dynamic>> _get(
    String pathname,
    Map<String, String> query,
  ) async {
    final uri = Uri.parse('$apiBase$pathname').replace(queryParameters: query);
    final response = await _send('GET', uri);
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String pathname,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse(
      '$apiBase$pathname',
    ).replace(queryParameters: {'pr': 'ucpro', 'fr': 'pc'});
    final response = await _send(
      'POST',
      uri,
      headers: {'Content-Type': 'application/json'},
      body: utf8.encode(jsonEncode(body)),
    );
    return _decode(response);
  }

  Future<_RawResponse> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    // Cookie 与鉴权头只走夸克域名，避免泄漏给 OSS。
    final merged = {
      'Accept': 'application/json, text/plain, */*',
      'Referer': _referer,
      'User-Agent': userAgent,
      'Cookie': cookie,
      ...headers,
    };
    return _sendRaw(method, uri, headers: merged, body: body);
  }

  Future<_RawResponse> _sendRaw(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    List<int>? body,
  }) async {
    try {
      final request = await _client.openUrl(method, uri).timeout(timeout);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      final headerMap = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) headerMap[name.toLowerCase()] = values.first;
      });
      return _RawResponse(response.statusCode, headerMap, text);
    } on TimeoutException {
      throw const RemoteStorageException('夸克响应超时，请检查网络后重试');
    } on SocketException catch (error) {
      throw RemoteStorageException('无法连接夸克：${error.message}');
    } on HandshakeException catch (error) {
      throw RemoteStorageException('与夸克建立安全连接失败：${error.message}');
    }
  }

  Map<String, dynamic> _decode(_RawResponse response) {
    if (response.body.isEmpty) {
      throw RemoteStorageException('夸克返回空响应（HTTP ${response.statusCode}）');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw RemoteStorageException(
        '夸克返回了无法识别的响应（HTTP ${response.statusCode}）：${_brief(response.body)}',
      );
    }
    if (decoded is! Map) {
      throw const RemoteStorageException('夸克返回了无法识别的响应');
    }
    final json = decoded.map((key, value) => MapEntry('$key', value));
    final status = json['status'];
    final code = json['code'];
    final failed =
        (status is num && status >= 400) || (code is num && code != 0);
    if (failed) {
      final message = _stringOf(json['message']);
      throw RemoteStorageException(
        message.isEmpty ? '夸克操作失败（code $code）' : message,
        code: code?.toString(),
      );
    }
    return json;
  }

  @override
  String toString() => 'QuarkUploader';
}

class _RawResponse {
  const _RawResponse(this.statusCode, this.headers, this.body);
  final int statusCode;
  final Map<String, String> headers;
  final String body;
}

class _RemotePath {
  const _RemotePath(this.directory, this.name);
  final String directory;
  final String name;
}

_RemotePath _splitRemotePath(String path) {
  final segments = path
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .where((item) => item.isNotEmpty && item != '.')
      .toList();
  if (segments.any((item) => item == '..')) {
    throw const RemoteStorageException('无效的远端路径');
  }
  if (segments.isEmpty) {
    throw const RemoteStorageException('缺少远端文件名');
  }
  final name = segments.removeLast();
  final directory = segments.isEmpty ? '/' : '/${segments.join('/')}/';
  return _RemotePath(directory, name);
}

/// 对象存储地址：`{scheme}://{bucket}.{host}`，bucket 为空时直接用 host
/// （本地测试会用到）。
String _objectBase(String uploadUrl, String bucket) {
  final base = uploadUrl.endsWith('/')
      ? uploadUrl.substring(0, uploadUrl.length - 1)
      : uploadUrl;
  final scheme = base.startsWith('http://') ? 'http' : 'https';
  final host = base.replaceFirst(RegExp(r'^https?://'), '');
  return bucket.isEmpty ? '$scheme://$host' : '$scheme://$bucket.$host';
}

String _httpDate(DateTime utc) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int value) => value.toString().padLeft(2, '0');
  return '${weekdays[utc.weekday - 1]}, ${two(utc.day)} '
      '${months[utc.month - 1]} ${utc.year} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
}

String _brief(String value) {
  final trimmed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  return trimmed.length <= 200 ? trimmed : '${trimmed.substring(0, 200)}…';
}

String _stringOf(Object? value) =>
    value == null ? '' : (value is String ? value : '$value');

Map<String, dynamic> _mapOf(Object? value) => value is Map
    ? value.map((key, item) => MapEntry('$key', item))
    : <String, dynamic>{};

/// 夸克列表接口返回的 file_name 是 HTML 转义过的（例如 `&amp;`）。
String htmlUnescape(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

const _mimeTypes = <String, String>{
  'cbz': 'application/zip',
  'cbr': 'application/vnd.comicbook-rar',
  'cb7': 'application/x-7z-compressed',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'json': 'application/json',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'mp4': 'video/mp4',
  'mp3': 'audio/mpeg',
  'epub': 'application/epub+zip',
};
