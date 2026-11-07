import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/webdav_url.dart';

void main() {
  group('normalizeWebdavUrl', () {
    test('去掉末尾单个斜杠', () {
      expect(
        normalizeWebdavUrl('https://dav.jianguoyun.com/dav/'),
        'https://dav.jianguoyun.com/dav',
      );
    });

    test('去掉末尾连续多个斜杠', () {
      expect(
        normalizeWebdavUrl('https://example.com/dav///'),
        'https://example.com/dav',
      );
    });

    test('没有末尾斜杠时保持不变', () {
      expect(
        normalizeWebdavUrl('https://example.com/dav'),
        'https://example.com/dav',
      );
    });

    test('去掉首尾空白', () {
      expect(
        normalizeWebdavUrl('  https://example.com/dav/  '),
        'https://example.com/dav',
      );
    });

    test('保留路径中间与开头的结构', () {
      expect(
        normalizeWebdavUrl('https://example.com/dav/ManComic/'),
        'https://example.com/dav/ManComic',
      );
    });

    test('只有域名时也能处理', () {
      expect(normalizeWebdavUrl('https://example.com/'), 'https://example.com');
    });
  });
}
