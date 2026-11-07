import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/local.dart';

void main() {
  group('边下边看：本地页与网络页拼接', () {
    test('本地一页都没有时全用网络地址', () {
      expect(
        mergeLocalPages({}, ['r0', 'r1']),
        ['r0', 'r1'],
      );
    });

    test('本地已经下全时不再留网络地址', () {
      expect(
        mergeLocalPages({0: 'f0', 1: 'f1', 2: 'f2'}, ['r0', 'r1', 'r2']),
        ['f0', 'f1', 'f2'],
      );
    });

    test('只落了前几页时后面接网络地址', () {
      expect(
        mergeLocalPages({0: 'f0', 1: 'f1'}, ['r0', 'r1', 'r2', 'r3']),
        ['f0', 'f1', 'r2', 'r3'],
      );
    });

    test('中间失败缺一页时按页码补，不整体错位', () {
      expect(
        mergeLocalPages({0: 'f0', 2: 'f2'}, ['r0', 'r1', 'r2']),
        ['f0', 'r1', 'f2'],
      );
    });

    test('老版本文件从 1 开始编号也能对齐', () {
      expect(
        mergeLocalPages({1: 'f0', 2: 'f1'}, ['r0', 'r1', 'r2']),
        ['f0', 'f1', 'r2'],
      );
    });
  });
}
