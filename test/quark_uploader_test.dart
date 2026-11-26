import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cloud_storage/models.dart';
import 'package:venera/network/cloud_storage/quark_uploader.dart';
import 'package:venera/network/cloud_storage/remote_file_store.dart';

void main() {
  group('夸克上传的 MIME 兜底', () {
    test('.cbz 必须有非空 format_type', () {
      expect(QuarkUploader.mimeTypeForName('漫画.cbz'), 'application/zip');
      expect(QuarkUploader.mimeTypeForName('a.CBZ'), 'application/zip');
    });

    test('未知扩展名回退到二进制流而不是空串', () {
      expect(
        QuarkUploader.mimeTypeForName('data.unknown-ext'),
        'application/octet-stream',
      );
      expect(
        QuarkUploader.mimeTypeForName('no-extension'),
        'application/octet-stream',
      );
    });
  });

  group('内核失败识别', () {
    test('认得出夸克的 format_type 报错', () {
      expect(
        QuarkUploader.isMissingFormatType(
          const RemoteStorageException('Bad Parameter：[format_type is null!]'),
        ),
        isTrue,
      );
    });

    test('其他错误不误判', () {
      expect(
        QuarkUploader.isMissingFormatType(
          const RemoteStorageException('Unauthorized'),
        ),
        isFalse,
      );
    });
  });

  group('上传器只对夸克账号启用', () {
    test('没有 Cookie 时返回 null', () {
      const account = StorageAccount(
        id: 'a',
        backend: StorageBackend.openlist,
        driver: 'Quark',
        name: '夸克',
        authorization: {},
      );
      expect(QuarkUploader.forAccount(account), isNull);
    });

    test('其他驱动返回 null', () {
      const account = StorageAccount(
        id: 'a',
        backend: StorageBackend.openlist,
        driver: 'BaiduNetdisk',
        name: '百度',
        authorization: {'cookie': 'a=b'},
      );
      expect(QuarkUploader.forAccount(account), isNull);
    });
  });

  test('完整分片上传会带上 format_type 并走完 pre/auth/complete/finish', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = 'http://127.0.0.1:${server.port}';
    final requests = <String, List<dynamic>>{};
    final preBodies = <Map<String, dynamic>>[];
    final authMetas = <String>[];
    final partBodies = <int>[];
    String? completeBody;

    void record(String key, Object value) =>
        requests.putIfAbsent(key, () => []).add(value);

    final temp = await Directory.systemTemp.createTemp('quark-upload-test-');
    final file = File('${temp.path}/comic.cbz');
    await file.writeAsBytes(List<int>.generate(10, (index) => index));

    server.listen((request) async {
      final path = request.uri.path;
      final body = request.method == 'GET'
          ? ''
          : await utf8.decoder.bind(request).join();
      Map<String, dynamic> reply({Map<String, dynamic>? data}) => {
        'status': 200,
        'code': 0,
        'message': 'ok',
        'data': data ?? {},
        'metadata': <String, dynamic>{},
      };
      Future<void> json(Object value) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(value));
        await request.response.close();
      }

      try {
        if (request.method == 'POST' && path.endsWith('/file/upload/pre')) {
          preBodies.add(jsonDecode(body) as Map<String, dynamic>);
          await json({
            'status': 200,
            'code': 0,
            'data': {
              'task_id': 'task-1',
              'finish': false,
              'upload_id': 'u-1',
              'obj_key': 'obj-1',
              'upload_url': host,
              'bucket': '',
              'auth_info': 'auth-info',
              'callback': {'callbackUrl': host, 'callbackBody': 'body'},
            },
            'metadata': {'part_size': 4},
          });
          return;
        }
        if (request.method == 'POST' && path.endsWith('/file/update/hash')) {
          record('hash', jsonDecode(body));
          await json(reply(data: {'finish': false}));
          return;
        }
        if (request.method == 'POST' && path.endsWith('/file/upload/auth')) {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          authMetas.add('${decoded['auth_meta']}');
          await json(reply(data: {'auth_key': 'key'}));
          return;
        }
        if (request.method == 'POST' && path.endsWith('/file/upload/finish')) {
          record('finish', jsonDecode(body));
          await json(reply());
          return;
        }
        if (request.method == 'GET' && path.endsWith('/file/sort')) {
          final fid = request.uri.queryParameters['pdir_fid'];
          await json({
            'status': 200,
            'code': 0,
            'data': {
              'list': fid == '0'
                  ? [
                      {'fid': 'dir-1', 'file_name': '备份', 'file': false},
                    ]
                  : <Map<String, dynamic>>[],
            },
            'metadata': {'_total': fid == '0' ? 1 : 0},
          });
          return;
        }
        if (request.method == 'PUT') {
          partBodies.add(body.length);
          request.response.headers.set(
            'etag',
            '"etag-${request.uri.queryParameters['partNumber']}"',
          );
          request.response.write('ok');
          await request.response.close();
          return;
        }
        if (request.method == 'POST' && path == '/obj-1') {
          completeBody = body;
          request.response.write('ok');
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        request.response.write('unexpected: ${request.method} $path');
        await request.response.close();
      } catch (error) {
        request.response.statusCode = 500;
        request.response.write('$error');
        await request.response.close();
      }
    });

    try {
      final uploader = QuarkUploader(
        cookie: 'a=b',
        apiBase: '$host/1/clouddrive',
      );
      final progress = <int>[];
      await uploader.upload(
        file.path,
        '/备份/comic.cbz',
        onProgress: (value) => progress.add(value.completed),
      );
      uploader.close();

      expect(preBodies, hasLength(1));
      expect(preBodies.single['file_name'], 'comic.cbz');
      expect(preBodies.single['format_type'], 'application/zip');
      expect(preBodies.single['pdir_fid'], 'dir-1');
      expect(preBodies.single['size'], 10);

      expect(partBodies, [4, 4, 2]);
      expect(authMetas.any((meta) => meta.contains('uploadId=u-1')), isTrue);
      expect(completeBody, contains('<CompleteMultipartUpload>'));
      expect(completeBody, contains('<PartNumber>3</PartNumber>'));
      expect(requests['finish'], hasLength(1));
      expect(progress.last, 10);
    } finally {
      await server.close(force: true);
      await temp.delete(recursive: true);
    }
  });
}
