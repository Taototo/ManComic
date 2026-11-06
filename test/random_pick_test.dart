import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/random_pick.dart';

class _FakeComic implements HistoryMixin {
  _FakeComic(this.id);

  @override
  final String id;

  @override
  String get title => "Comic $id";

  @override
  String? get subTitle => null;

  @override
  String get cover => "";

  @override
  HistoryType get historyType => const HistoryType(1);

  @override
  int? get maxPage => null;
}

History _history(String id, {required int page, int? maxPage}) {
  final history = History.fromModel(model: _FakeComic(id), ep: 1, page: page);
  history.maxPage = maxPage;
  return history;
}

FavoriteItem _favorite(String id) => FavoriteItem(
      id: id,
      name: "Comic $id",
      coverPath: "",
      author: "",
      // 用 local 类型：不需要源表就能算出 sourceKey
      type: ComicType.local,
      tags: const [],
    );

void main() {
  group('阅读进度筛选', () {
    test('没读过时只有「全部」和「未开始」命中', () {
      for (final scope in RandomPickScope.values) {
        expect(
          randomPickMatchesScope(scope, null),
          scope == RandomPickScope.all || scope == RandomPickScope.notStarted,
          reason: '$scope',
        );
      }
    });

    test('读到一半算在读，不算读完', () {
      final history = _history('a', page: 5, maxPage: 20);
      expect(randomPickMatchesScope(RandomPickScope.inProgress, history), true);
      expect(randomPickMatchesScope(RandomPickScope.notStarted, history), false);
      expect(randomPickMatchesScope(RandomPickScope.completed, history), false);
    });

    test('读到末页才算读完', () {
      final history = _history('a', page: 20, maxPage: 20);
      expect(randomPickMatchesScope(RandomPickScope.completed, history), true);
      expect(randomPickMatchesScope(RandomPickScope.inProgress, history), false);
    });

    test('没有总页数时永远不会被判成读完', () {
      final history = _history('a', page: 999, maxPage: null);
      expect(randomPickMatchesScope(RandomPickScope.completed, history), false);
      expect(randomPickMatchesScope(RandomPickScope.inProgress, history), true);
    });
  });

  group('抽取', () {
    test('空候选返回 null', () {
      expect(pickRandomComic(const []), isNull);
    });

    test('跳过本轮已经抽到的', () {
      final comics = [_favorite('a'), _favorite('b')];
      final picked = pickRandomComic(
        comics,
        excluded: {randomPickIdentity(comics[0])},
      );
      expect(picked, isNotNull);
      expect(picked!.id, 'b');
    });

    test('全被排除时返回 null，由调用方决定是否重开一轮', () {
      final comics = [_favorite('a'), _favorite('b')];
      final picked = pickRandomComic(
        comics,
        excluded: comics.map(randomPickIdentity).toSet(),
      );
      expect(picked, isNull);
    });

    test('单本时直接返回它', () {
      final comics = [_favorite('only')];
      expect(pickRandomComic(comics)!.id, 'only');
    });

    test('候选都会抽到，不会总是同一本', () {
      final comics = [for (var i = 0; i < 5; i++) _favorite('$i')];
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(pickRandomComic(comics)!.id);
      }
      expect(seen.length, greaterThan(1));
    });
  });
}
