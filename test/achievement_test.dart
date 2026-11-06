import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/achievements.dart';
import 'package:venera/utils/translations.dart';

/// 成就分档的规则测试。
///
/// 分档是纯计算（门槛 → 档位 → 到下一档的进度），不涉及界面，所以可以直接
/// 造一份统计快照来喂。档位算错的表现很隐蔽：徽章照样显示，只是永远停在
/// 青铜，用户根本看不出哪里不对。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  AchievementFamily family({
    List<int> tiers = const [10, 20, 30, 40],
    AchievementMetric metric = AchievementMetric.comics,
  }) {
    return AchievementFamily(
      id: 'test',
      title: 'Test',
      description: 'Test',
      icon: Icons.star,
      metric: metric,
      tiers: tiers,
    );
  }

  test('门槛依次点亮四档', () {
    final f = family();
    expect(AchievementProgress(f, 0).tier, AchievementTier.locked);
    expect(AchievementProgress(f, 9).tier, AchievementTier.locked);
    expect(AchievementProgress(f, 10).tier, AchievementTier.bronze);
    expect(AchievementProgress(f, 19).tier, AchievementTier.bronze);
    expect(AchievementProgress(f, 20).tier, AchievementTier.silver);
    expect(AchievementProgress(f, 30).tier, AchievementTier.gold);
    expect(AchievementProgress(f, 40).tier, AchievementTier.diamond);
    // 超过最高档不再升级，也不会越界
    expect(AchievementProgress(f, 999).tier, AchievementTier.diamond);
  });

  test('到下一档的进度按当前档内插值', () {
    final f = family();
    // 青铜档内：10 → 20，值 15 正好一半
    expect(AchievementProgress(f, 15).ratioToNext, closeTo(0.5, 1e-9));
    // 还没点亮时从 0 算起
    expect(AchievementProgress(f, 5).ratioToNext, closeTo(0.5, 1e-9));
    // 满档恒为 1
    expect(AchievementProgress(f, 100).ratioToNext, 1);
  });

  test('还差多少只算到下一档', () {
    final f = family();
    expect(AchievementProgress(f, 0).remainingToNext, 10);
    expect(AchievementProgress(f, 15).remainingToNext, 5);
    expect(AchievementProgress(f, 40).remainingToNext, 0);
  });

  test('汇总统计点亮档数', () {
    final list = [
      AchievementProgress(family(tiers: const [10, 20, 30, 40]), 25),
      AchievementProgress(family(tiers: const [10, 20, 30, 40]), 0),
    ];
    final summary = Achievements.summary(list);
    expect(summary.unlocked, 2);
    expect(summary.total, 8);
  });

  test('内建成就家族结构完整', () {
    final ids = <String>{};
    for (final f in Achievements.all) {
      expect(ids.add(f.id), isTrue, reason: '${f.id} 重复');
      expect(f.tiers.length, AchievementTier.tierCount);
      for (var i = 1; i < f.tiers.length; i++) {
        expect(
          f.tiers[i],
          greaterThan(f.tiers[i - 1]),
          reason: '${f.id} 的门槛必须递增',
        );
      }
    }
    expect(Achievements.all.length, 8);
  });

  test('时长按分钟/小时显示', () {
    expect(Achievements.valueText(AchievementMetric.seconds, 30), '30 s');
    expect(Achievements.valueText(AchievementMetric.seconds, 600), '10 min');
    expect(Achievements.valueText(AchievementMetric.seconds, 5400), '1.5 h');
    expect(Achievements.valueText(AchievementMetric.streak, 7), '7 d');
  });
}
