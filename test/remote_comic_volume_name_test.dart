import 'package:flutter_test/flutter_test.dart';
import 'package:venera/features/cloud_library/remote_comic_work.dart';

void main() {
  group('网盘漫画卷名解析（按夸克分享里的真实命名）', () {
    test('识别 # / +# 形式的期号', () {
      final spaced = RemoteComicVolumeName.parse('蜘蛛侠 #001.pdf');
      expect(spaced.numbered, isTrue);
      expect(spaced.series, '蜘蛛侠');
      expect(spaced.first, 1);
      expect(spaced.last, 1);

      final plus = RemoteComicVolumeName.parse('蜘蛛侠+#002.pdf');
      expect(plus.numbered, isTrue);
      expect(plus.series, '蜘蛛侠');
      expect(plus.first, 2);

      final issue = RemoteComicVolumeName.parse('蜘蛛侠2099#1.pdf');
      expect(issue.numbered, isTrue);
      expect(issue.series, '蜘蛛侠2099');
      expect(issue.first, 1);
    });

    test('识别紧贴正文的期号，但不误判年份/型号', () {
      final first = RemoteComicVolumeName.parse('终极蜘蛛侠1.pdf');
      expect(first.numbered, isTrue);
      expect(first.series, '终极蜘蛛侠');
      expect(first.first, 1);

      final last = RemoteComicVolumeName.parse('终极蜘蛛侠24.pdf');
      expect(last.numbered, isTrue);
      expect(last.series, '终极蜘蛛侠');
      expect(last.first, 24);

      final year = RemoteComicVolumeName.parse('蜘蛛侠1602.pdf');
      expect(year.numbered, isFalse);
    });

    test('识别第N卷并保留书名前缀', () {
      final volume = RemoteComicVolumeName.parse(
        '66蝙蝠侠遭遇舅男_第01卷.pdf',
      );
      expect(volume.numbered, isTrue);
      expect(volume.series, '66蝙蝠侠遭遇舅男');
      expect(volume.unit, '卷');
      expect(volume.first, 1);
      expect(volume.last, 1);
    });

    test('非期号文件保持独立漫画', () {
      expect(RemoteComicVolumeName.parse('蜘蛛侠 蓝.pdf').numbered, isFalse);
      expect(
        RemoteComicVolumeName.parse('1963神奇蜘蛛侠81未（PDF）.pdf').numbered,
        isFalse,
      );
      expect(RemoteComicVolumeName.parse('001.pdf').numbered, isFalse);
    });

    test('区间期号仍按 unit + first + last 去重', () {
      final range = RemoteComicVolumeName.parse('漫画名 第01–03卷.pdf');
      expect(range.numbered, isTrue);
      expect(range.series, '漫画名');
      expect(range.unit, '卷');
      expect(range.first, 1);
      expect(range.last, 3);
      expect(range.identity, '卷:1:3');
    });
  });
}
