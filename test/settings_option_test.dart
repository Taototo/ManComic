import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/settings/settings_page.dart';

/// 设置页里几个「一项抵两项」的选项，底层仍然是原来的多个键。
/// 这层映射写反了，用户在设置里选的和阅读器实际行为就对不上，
/// 而且从界面上完全看不出来，所以单独测。
void main() {
  group('长按动作', () {
    test('读取：只有动作是缩放且开关打开才显示为缩放', () {
      expect(longPressOptionOf("zoom", true, "press"), "zoomPress");
      expect(longPressOptionOf("zoom", true, "center"), "zoomCenter");
      // 旧配置：动作选了缩放但开关是关的 —— 长按其实没反应，按快捷面板显示
      expect(longPressOptionOf("zoom", false, "center"), "hud");
      expect(longPressOptionOf("hud", true, "center"), "hud");
      // 键缺失
      expect(longPressOptionOf(null, null, null), "hud");
    });

    test('写入：选缩放要同时打开开关并写下位置', () {
      final press = longPressKeysOf("zoomPress");
      expect(press.action, "zoom");
      expect(press.zoomEnabled, isTrue);
      expect(press.position, "press");

      final center = longPressKeysOf("zoomCenter");
      expect(center.position, "center");
    });

    test('写入：切到快捷面板不覆盖放大位置', () {
      final hud = longPressKeysOf("hud");
      expect(hud.action, "hud");
      // 位置保持 null 表示「不要写」，否则用户切回来时位置被重置了
      expect(hud.position, isNull);
      expect(hud.zoomEnabled, isNull);
    });

    test('往返：同一份配置读写后仍是原值', () {
      for (final action in ["hud", "zoom"]) {
        for (final pos in ["press", "center"]) {
          for (final enabled in [true, false]) {
            final option = longPressOptionOf(action, enabled, pos);
            final keys = longPressKeysOf(option);
            // 重新读一次，结果必须稳定（不能出现 A→B→A 的抖动）
            final again = longPressOptionOf(
              keys.action,
              keys.zoomEnabled ?? enabled,
              keys.position ?? pos,
            );
            expect(again, option, reason: "action=$action pos=$pos enabled=$enabled");
          }
        }
      }
    });
  });

  group('点击翻页', () {
    test('关闭时忽略反向标记', () {
      expect(tapTurnOptionOf(false, false), "off");
      expect(tapTurnOptionOf(false, true), "off");
      expect(tapTurnOptionOf(null, null), "off");
    });

    test('开启时区分正向与反向', () {
      expect(tapTurnOptionOf(true, false), "normal");
      expect(tapTurnOptionOf(true, true), "reversed");
    });
  });

  group('阅读器顶部信息', () {
    test('系统状态栏优先于自绘时钟', () {
      // 两个都开时以前会出现两套时间，合并后只按系统状态栏算
      expect(readerTopBarOptionOf(true, true), "statusBar");
      expect(readerTopBarOptionOf(false, true), "statusBar");
      expect(readerTopBarOptionOf(true, false), "clock");
      expect(readerTopBarOptionOf(false, false), "off");
      expect(readerTopBarOptionOf(null, null), "off");
    });
  });
}
