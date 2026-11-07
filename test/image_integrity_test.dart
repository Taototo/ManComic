import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/file_type.dart';

/// 构造一段假的 JPEG：FF D8 开头，FF D9 结尾，中间随便填。
Uint8List _jpeg({required int bodyLength, required bool eoi}) {
  final bytes = <int>[0xFF, 0xD8];
  bytes.addAll(List.filled(bodyLength, 0x11));
  if (eoi) {
    bytes.addAll([0xFF, 0xD9]);
  }
  return Uint8List.fromList(bytes);
}

void main() {
  group('图片完整性判断（断点续传的守门人）', () {
    test('完整 JPEG 通过', () {
      expect(isCompleteImageBytes(_jpeg(bodyLength: 64, eoi: true)), isTrue);
    });

    test('截断的 JPEG 不通过', () {
      // 断线时流干净结束，buffer 里只有半张图——这正是封面坏掉的样本
      expect(isCompleteImageBytes(_jpeg(bodyLength: 4000, eoi: false)), isFalse);
    });

    test('JPEG 结尾带几个填充字节仍然算完整', () {
      final data = _jpeg(bodyLength: 64, eoi: true);
      final padded = Uint8List.fromList([...data, 0, 0, 0]);
      expect(isCompleteImageBytes(padded), isTrue);
    });

    test('0 字节和过短的数据不通过', () {
      expect(isCompleteImageBytes(Uint8List(0)), isFalse);
      expect(isCompleteImageBytes(Uint8List.fromList([0xFF, 0xD8])), isFalse);
    });

    test('PNG 要带 IEND 收尾', () {
      final ok = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        ...List.filled(20, 0x22),
        0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // IEND
      ];
      expect(isCompleteImageBytes(ok), isTrue);

      final truncated = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ...List.filled(20, 0x22),
      ];
      expect(isCompleteImageBytes(truncated), isFalse);
    });

    test('GIF 要带 0x3B 结束符', () {
      final header = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
      final body = List.filled(16, 0x33);
      expect(isCompleteImageBytes([...header, ...body, 0x3B]), isTrue);
      expect(isCompleteImageBytes([...header, ...body]), isFalse);
    });

    test('WebP 的长度字段必须和实际长度一致', () {
      // RIFF + size(小端) + WEBP + body
      final body = List.filled(16, 0x44);
      final total = 4 + 4 + 4 + body.length;
      final ok = <int>[
        0x52, 0x49, 0x46, 0x46, // RIFF
        (total - 8) & 0xFF,
        ((total - 8) >> 8) & 0xFF,
        ((total - 8) >> 16) & 0xFF,
        ((total - 8) >> 24) & 0xFF,
        0x57, 0x45, 0x42, 0x50, // WEBP
        ...body,
      ];
      expect(isCompleteImageBytes(ok), isTrue);

      final truncated = ok.sublist(0, ok.length - 5);
      expect(isCompleteImageBytes(truncated), isFalse);
    });

    test('认不出的格式只要非空就放行', () {
      // avif 之类没有便宜的尾标记，误杀比放过更糟
      expect(isCompleteImageBytes(List.filled(64, 0x01)), isTrue);
    });
  });
}
