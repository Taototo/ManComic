import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/storage_usage.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('storage_usage_test');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  group('directorySize', () {
    test('目录不存在返回 0', () async {
      final missing = Directory('${temp.path}/nope');
      expect(await directorySize(missing), 0);
    });

    test('空目录返回 0', () async {
      final empty = Directory('${temp.path}/empty');
      await empty.create();
      expect(await directorySize(empty), 0);
    });

    test('递归累加子目录里的文件', () async {
      File('${temp.path}/a.bin').writeAsBytesSync(List.filled(100, 0));
      final sub = Directory('${temp.path}/sub/deep');
      sub.createSync(recursive: true);
      File('${sub.path}/b.bin').writeAsBytesSync(List.filled(250, 0));
      expect(await directorySize(temp), 350);
    });

    test('只统计文件，不把目录本身算进去', () async {
      Directory('${temp.path}/a/b/c').createSync(recursive: true);
      expect(await directorySize(temp), 0);
    });
  });

  group('fileSize', () {
    test('文件不存在返回 0', () async {
      expect(await fileSize(File('${temp.path}/none.txt')), 0);
    });

    test('返回真实字节数', () async {
      final file = File('${temp.path}/log.txt');
      file.writeAsStringSync('abcde');
      expect(await fileSize(file), 5);
    });
  });
}
