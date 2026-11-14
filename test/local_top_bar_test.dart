import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

/// 本地漫画页的顶栏要和收藏页是同一条玻璃。
///
/// 原来它是一条 `SliverAppbar`：pinned、自带底色，压在内容**上面**的那一
/// 层是实心的，所以收藏页那种「列表从玻璃后面滑过去」的观感在这里没有。
void main() {
  String read(String path) => File(path).readAsStringSync();

  testWidgets('独立页面里的玻璃顶栏能单独渲染', (tester) async {
    // 顶栏在独立页面里没有上层的 `AdaptiveLiquidGlassLayer`，premium 档会
    // 自己开一层。这条走位以前踩过坑（采不到背景 → 整块玻璃消失），所以
    // 至少要保证它不抛。
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        ),
        home: Scaffold(
          body: Stack(
            children: [
              const GlassPageBackdrop(),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: const LiquidGlassBar(child: SizedBox(height: 96)),
              ),
              ListView.builder(
                itemCount: 20,
                itemBuilder: (context, index) =>
                    SizedBox(height: 120, child: Text('item $index')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  test('顶栏是叠在内容上的玻璃，不是 SliverAppbar', () {
    final src = read('lib/pages/local_comics_page.dart');
    expect(
      src.contains('LiquidGlassBar('),
      isTrue,
      reason: '要用收藏页那一条（LiquidGlassBar），不是自带的 SliverAppbar',
    );
    expect(
      src.contains('LiquidGlassEngine.barTintAlpha'),
      isTrue,
      reason: '底色必须和顶栏/底栏同一档，否则两块玻璃会是两种观感',
    );
    expect(
      src.contains('SliverAppbar('),
      isFalse,
      reason: 'pinned 的实心标题栏会把内容挡在外面，穿不到玻璃底下',
    );
    // 留白要付在滚动容器内部：付在外面等于把整块内容往下推，内容永远
    // 滚不到玻璃后面。
    expect(
      src.contains('SizedBox(height: context.padding.top + _kTopBarHeight)'),
      isTrue,
    );
  });
}
