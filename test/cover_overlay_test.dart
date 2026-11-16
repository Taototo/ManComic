import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/local_comics_page.dart';

/// 封面上的角标（页码、右上角菜单点）压在漫画封面上。
///
/// 封面可以是任何颜色，所以角标不能跟主题取色。以前底色用 `scrim`
/// （两套主题都是黑，没问题）配 `colorScheme.surface` 当字色：亮色主题下
/// surface 是白的，看着挺正常；暗色主题下它也是近黑的，字和底糊在一起，
/// 深色封面上页码直接消失。这里把「深底白字」钉住。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// 取一个方法/组件的源码块，用来做「不许出现某某」这类守卫。
String block(String source, String head) {
  final start = source.indexOf(head);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $head');
  final end = source.indexOf('\n  }\n', start);
  final end2 = source.indexOf('\n}\n', start);
  final stop = (end >= 0 && (end2 < 0 || end < end2)) ? end : end2;
  expect(stop, greaterThan(start), reason: '$head 的结尾没找到');
  return source.substring(start, stop);
}

void main() {
  group('封面角标的颜色', () {
    test('字是纯白，底是半透明黑', () {
      expect(kCoverOverlayInk, Colors.white);
      expect(kCoverOverlayScrim.r, 0);
      expect(kCoverOverlayScrim.g, 0);
      expect(kCoverOverlayScrim.b, 0);
      // 太淡就压不住浅色封面，太白又会盖住图
      expect(kCoverOverlayScrim.a, greaterThan(0.5));
      expect(kCoverOverlayScrim.a, lessThan(0.75));
    });

    test('字和底的亮度差够大，深色封面上也读得出来', () {
      expect(
        kCoverOverlayInk.computeLuminance() - kCoverOverlayScrim.computeLuminance(),
        greaterThan(0.7),
      );
    });
  });

  group('守卫', () {
    final src = read('lib/pages/local_comics_page.dart');

    test('页码和菜单点都不用主题字色', () {
      for (final head in [
        'Widget _buildProgressPill(',
        'Widget _buildMenuButton(',
      ]) {
        final body = block(src, head);
        expect(
          body.contains('colors.surface'),
          isFalse,
          reason: '暗色主题的 surface 是近黑色，压在深色封面上等于隐形',
        );
        expect(body.contains('kCoverOverlayInk'), isTrue);
        expect(body.contains('kCoverOverlayScrim'), isTrue);
      }
    });
  });
}
