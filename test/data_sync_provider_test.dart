import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data_sync_storage.dart';

void main() {
  group('数据同步目的地', () {
    test('显式选择夸克时不再回退到 WebDAV', () {
      expect(
        syncProviderFromConfig(
          stored: syncProviderQuark,
          webdavConfigured: true,
        ),
        syncProviderQuark,
      );
    });

    test('选择关闭后即使填过 WebDAV 也不启用', () {
      expect(
        syncProviderFromConfig(stored: syncProviderOff, webdavConfigured: true),
        isNull,
      );
    });

    test('老配置没有显式选择时沿用 WebDAV', () {
      expect(
        syncProviderFromConfig(stored: null, webdavConfigured: true),
        syncProviderWebdav,
      );
      expect(
        syncProviderFromConfig(stored: '', webdavConfigured: true),
        syncProviderWebdav,
      );
    });

    test('两边都没配置时视为未启用', () {
      expect(
        syncProviderFromConfig(stored: null, webdavConfigured: false),
        isNull,
      );
    });
  });
}
