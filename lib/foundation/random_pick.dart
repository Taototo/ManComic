import 'dart:math';

import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';

/// 「抽一本」的筛选口径：按读没读过、读没读完来缩小候选。
///
/// 收藏夹里几百本，全混在一起的随机其实不好用——想找点没看过的、想把读到
/// 一半的收个尾、或者干脆抽一本已经读完的重温，是三种完全不同的需求。
enum RandomPickScope { all, notStarted, inProgress, completed }

RandomPickScope randomPickScopeFromName(Object? name) =>
    RandomPickScope.values.firstWhere(
      (scope) => scope.name == name,
      orElse: () => RandomPickScope.all,
    );

/// 一本书在读进度上的状态。完成 = 末页读到过，和 [History.maxPage] 对比。
bool randomPickMatchesScope(RandomPickScope scope, History? history) {
  final completed = history != null &&
      history.maxPage != null &&
      history.maxPage! > 0 &&
      history.page >= history.maxPage!;
  return switch (scope) {
    RandomPickScope.all => true,
    RandomPickScope.notStarted => history == null,
    RandomPickScope.inProgress => history != null && !completed,
    RandomPickScope.completed => completed,
  };
}

/// 一本书的稳定标识，用来实现「本轮不重复」。
String randomPickIdentity(FavoriteItem comic) =>
    "${comic.type.sourceKey}/${comic.id}";

/// 等概率抽一本，跳过 [excluded] 里的。
///
/// 用普通的 `Random` 而不是固定种子：同一个用户点两次，结果应该随机，
/// 而不是每次都从同一个位置开始。
FavoriteItem? pickRandomComic(
  List<FavoriteItem> candidates, {
  Set<String> excluded = const {},
  Random? random,
}) {
  if (candidates.isEmpty) {
    return null;
  }
  final pool = <FavoriteItem>[
    for (final comic in candidates)
      if (!excluded.contains(randomPickIdentity(comic))) comic,
  ];
  if (pool.isEmpty) {
    return null;
  }
  return pool[(random ?? _random).nextInt(pool.length)];
}

/// 复用一个 Random 实例：每次 new 一个会连着取到同一颗种子。
final _random = Random();
