import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/version.dart';

/// 更新检查依赖版本比较的正确性：
/// 比错了会「永远提示有新版本」或「永远提示已是最新」。
void main() {
  group('compareVersion', () {
    test('只在远端更高时返回 true', () {
      expect(compareVersion("1.4.0", "1.3.9"), isTrue);
      expect(compareVersion("1.3.10", "1.3.9"), isTrue);
      expect(compareVersion("2.0.0", "1.99.99"), isTrue);
    });

    test('同版本或更低版本返回 false', () {
      expect(compareVersion("1.3.9", "1.3.9"), isFalse);
      expect(compareVersion("1.3.8", "1.3.9"), isFalse);
      expect(compareVersion("1.3", "1.3.0"), isFalse);
    });

    test('缺段视为 0', () {
      expect(compareVersion("1.4", "1.3.9"), isTrue);
      expect(compareVersion("1.3.9.1", "1.3.9"), isFalse);
    });

    test('非数字段不抛异常', () {
      expect(compareVersion("1.4.0-beta", "1.3.9"), isTrue);
      expect(compareVersion("abc", "1.3.9"), isFalse);
      expect(compareVersion("1.3.9-hotfix", "1.3.9"), isFalse);
    });
  });

  group('normalizeVersion', () {
    test('去掉 v 前缀与 build 后缀', () {
      expect(normalizeVersion("v1.4.0"), "1.4.0");
      expect(normalizeVersion("1.4.0+272"), "1.4.0");
      expect(normalizeVersion("  V1.4.0+272  "), "1.4.0");
    });

    test('空串返回 null', () {
      expect(normalizeVersion(""), isNull);
      expect(normalizeVersion("v"), isNull);
    });
  });
}
