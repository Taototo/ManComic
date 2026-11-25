import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cloud_storage/models.dart';
import 'package:venera/network/cloud_storage/openlist_bridge.dart';
import 'package:venera/network/cloud_storage/openlist_rpc.dart';
import 'package:venera/network/cloud_storage/remote_file_store.dart';

/// 守卫「内核不回复时不能永久卡住」。
///
/// 之前原生回复丢了 arg1，Dart 侧的 Future 永远不完成，添加账号的界面就一直
/// 停在加载态。超时是最后一道防线，不能被悄悄删掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mancomi/openlist.test');
  const account = StorageAccount(
    id: 'acc-quark',
    backend: StorageBackend.openlist,
    driver: 'Quark',
    name: '夸克',
    authorization: {'cookie': 'a=b'},
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  test('内核不回复时按超时返回错误，而不是永远等待', () async {
    // 永不完成的回调，模拟回复丢失 / 内核进程卡死。
    mock((_) => Completer<String?>().future);
    final rpc = EmbeddedOpenListRpc(
      channel: channel,
      timeout: const Duration(milliseconds: 80),
    );

    final stopwatch = Stopwatch()..start();
    final response = await rpc.invoke('test', const {});
    stopwatch.stop();

    expect(response['error'], isA<Map>());
    expect((response['error'] as Map)['code'], 'timeout');
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));

    // 上层要把它转成可展示的 RemoteStorageException，而不是抛别的类型。
    final store = OpenListFileStore(account, rpc);
    await expectLater(
      store.test(),
      throwsA(
        isA<RemoteStorageException>().having(
          (e) => e.message,
          'message',
          contains('超时'),
        ),
      ),
    );
  });

  test('正常响应解出 data', () async {
    mock((call) async {
      final request = jsonDecode(
        (call.arguments as Map)['request'] as String,
      ) as Map<String, dynamic>;
      expect(request['method'], 'list');
      return jsonEncode({
        'data': {
          'entries': [
            {'name': 'comic.cbz', 'path': '/comic.cbz', 'isDirectory': false},
          ],
        },
      });
    });
    final rpc = EmbeddedOpenListRpc(channel: channel);
    final entries = await OpenListFileStore(account, rpc).list('/');
    expect(entries.single.name, 'comic.cbz');
  });

  test('原生报错原样透出，不被吞掉', () async {
    mock((_) async {
      throw PlatformException(
        code: 'openlist',
        message: '内核进程已崩溃',
      );
    });
    final rpc = EmbeddedOpenListRpc(channel: channel);
    final response = await rpc.invoke('test', const {});
    // 平台异常被包成 unavailable，但原因要保留下来给界面看。
    expect((response['error'] as Map)['message'], contains('内核进程已崩溃'));
  });

  test('内核返回错误时 test() 抛出对应消息', () async {
    mock((_) async => jsonEncode({
      'error': {'code': 'unauthorized', 'message': 'cookie 已失效'},
    }));
    final store = OpenListFileStore(
      account,
      EmbeddedOpenListRpc(channel: channel),
    );
    await expectLater(
      store.test(),
      throwsA(
        isA<RemoteStorageException>()
            .having((e) => e.message, 'message', 'cookie 已失效')
            .having((e) => e.isAuthorizationFailure, 'auth', isTrue),
      ),
    );
  });
}
