import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/pages/favorites/favorites_page.dart';

/// 收藏页把标题和操作按钮交给玻璃顶栏之后，顶栏内容就变成了「谁在树上听谁的」。
///
/// 这里面最容易写错的两点都没有界面反馈（顶栏只是少了个图标或闪一下）：
/// 1. 同一份内容被重复写入不该引起顶栏重画——页面每帧都会重建一次
///    [FavoritesTopBarScope]，通知一次就够把顶栏玻璃整块重置一遍；
/// 2. 切文件夹时新页面先写、旧页面后清，旧页面的清理**不能**把新页面刚写
///    进去的内容抹掉，否则切一次文件夹顶栏就空一下。
void main() {
  PaneActionEntry entry(IconData icon, {String label = 'x'}) {
    return PaneActionEntry(icon: icon, label: label, onTap: () {});
  }

  test('重复写入同一份内容不通知', () {
    final c = FavoritesTopBarController();
    var notified = 0;
    c.addListener(() => notified++);

    final owner = Object();
    final actions = [entry(Icons.sort_rounded)];
    c.update(owner, title: '连载中', actions: actions);
    expect(notified, 1);

    // 回调闭包每次 build 都是新的，但看得见的部分没变。
    c.update(owner, title: '连载中', actions: [entry(Icons.sort_rounded)]);
    expect(notified, 1);
    expect(c.title, '连载中');
    // 闭包本身仍然被换成了新的：否则按钮会一直指向旧状态。
    expect(identical(c.actions.first.onTap, actions.first.onTap), isFalse);
  });

  test('换了图标 / 标题 / 颜色才通知', () {
    final c = FavoritesTopBarController();
    var notified = 0;
    c.addListener(() => notified++);
    final owner = Object();

    c.update(owner, title: 'A', actions: [entry(Icons.sort_rounded)]);
    c.update(owner, title: 'B', actions: [entry(Icons.sort_rounded)]);
    expect(notified, 2);

    c.update(owner, title: 'B', actions: [entry(Icons.more_horiz)]);
    expect(notified, 3);

    c.update(
      owner,
      title: 'B',
      actions: [
        PaneActionEntry(
          icon: Icons.more_horiz,
          label: 'x',
          color: Colors.red,
          onTap: () {},
        ),
      ],
    );
    expect(notified, 4);
  });

  test('旧页面的清理不会抹掉新页面写的内容', () {
    final c = FavoritesTopBarController();
    var notified = 0;
    c.addListener(() => notified++);

    final oldPage = Object();
    final newPage = Object();

    c.update(oldPage, title: '旧文件夹', actions: [entry(Icons.sort_rounded)]);
    // 切文件夹：新页面先写入，旧页面随后 dispose。
    c.update(newPage, title: '新文件夹', actions: [entry(Icons.search)]);
    c.clear(oldPage);

    expect(c.title, '新文件夹');
    expect(c.actions.single.icon, Icons.search);
    expect(notified, 2);
  });

  test('当前页面的清理会清空顶栏', () {
    final c = FavoritesTopBarController();
    final owner = Object();
    c.update(owner, title: '连载中', actions: [entry(Icons.search)]);

    c.clear(owner);
    expect(c.title, isNull);
    expect(c.actions, isEmpty);

    // 已经空了就别再通知一次。
    var notified = 0;
    c.addListener(() => notified++);
    c.clear(owner);
    expect(notified, 0);
  });
}
