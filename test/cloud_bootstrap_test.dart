import 'dart:io';

import 'package:venera/network/cloud_storage/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('网盘账号与同步边界', () {
    test('网盘令牌字段不参与 WebDAV 同步', () {
      // 守卫 _disableSync：把凭据字段移出这个列表会让同步把令牌带去别的设备。
      final source = File('lib/foundation/appdata.dart').readAsStringSync();
      final start = source.indexOf('static const _disableSync');
      final end = source.indexOf('];', start);
      final block = source.substring(start, end);
      expect(block, contains('"remoteStorageAccounts"'));
      expect(block, contains('"remoteLibraries"'));
    });

    test('StorageAccount 序列化保留授权信息', () {
      final account = StorageAccount(
        id: 'acc-1',
        backend: StorageBackend.openlist,
        driver: 'Quark',
        name: '夸克',
        authorization: const {'refreshToken': 'abc'},
      );
      expect(
        account.toJson()['authorization'],
        containsPair('refreshToken', 'abc'),
      );
      expect(account.isConfigured, isTrue);
    });
  });
}
