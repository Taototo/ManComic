import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/explore_page.dart';

void main() {
  group('推荐 / 分类 分组状态', () {
    test('切换分组会通知页面', () {
      final controller = ExploreGroupController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.select(1);
      expect(controller.group, 1);
      expect(notified, 1);
      controller.dispose();
    });

    test('点当前页签不重建，只请求回到顶部', () {
      final controller = ExploreGroupController(group: 1);
      var notified = 0;
      var reselect = 0;
      controller.addListener(() => notified++);
      controller.onReselect = () => reselect++;

      controller.select(1);

      // 这里如果发出通知，页面会白重建一次，滚动位置也会被顺手重置，
      // 用户看到的就是「点一下页签，列表跳回顶部」的双份动作。
      expect(notified, 0);
      expect(reselect, 1);
      controller.dispose();
    });

    test('顶栏和页面共用同一个分组值', () {
      final controller = ExploreGroupController();
      controller.select(1);
      // 页面在自己的 initState 里读这个值，不能还是初始的 0
      expect(controller.group, 1);
      controller.dispose();
    });
  });
}
