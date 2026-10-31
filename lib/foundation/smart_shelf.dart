import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/utils/title_sort.dart';

/// 智能书架：用标签规则自动筛出收藏里的作品，不需要手动整理。
class SmartShelf {
  String name;

  /// 需要同时包含的标签（为空表示不限）
  List<String> tags;

  /// 排序方式：default / name_az / name_za
  String sort;

  SmartShelf({
    required this.name,
    List<String>? tags,
    this.sort = titleSortDefault,
  }) : tags = tags ?? [];

  Map<String, dynamic> toMap() => {
        'name': name,
        'tags': tags,
        'sort': sort,
      };

  factory SmartShelf.fromMap(Map<String, dynamic> map) {
    return SmartShelf(
      name: (map['name'] as String?) ?? '',
      tags: (map['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
      sort: (map['sort'] as String?) ?? titleSortDefault,
    );
  }
}

class SmartShelfManager {
  SmartShelfManager._();

  static const _key = 'smartShelves';

  static List<SmartShelf> list() {
    final raw = appdata.settings[_key];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => SmartShelf.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  static void save(List<SmartShelf> shelves) {
    appdata.settings[_key] = shelves.map((e) => e.toMap()).toList();
    appdata.saveData();
  }

  /// 收藏里出现过的标签，按出现次数排序
  static List<String> allTags({int limit = 80}) {
    final counter = <String, int>{};
    for (final item in LocalFavoritesManager().getAllComics()) {
      for (final tag in item.tags) {
        final value = tag.contains(':') ? tag.split(':')[1] : tag;
        if (value.trim().isEmpty) continue;
        counter.update(value, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    final entries = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) => e.key).toList();
  }

  static bool _matches(FavoriteItem item, List<String> tags) {
    if (tags.isEmpty) return true;
    final owned = item.tags
        .map((e) => e.contains(':') ? e.split(':')[1] : e)
        .map((e) => e.trim())
        .toSet();
    return tags.every(owned.contains);
  }

  static List<FavoriteItem> comicsOf(SmartShelf shelf) {
    final all = LocalFavoritesManager()
        .getAllComics()
        .where((e) => _matches(e, shelf.tags))
        .toList();
    switch (shelf.sort) {
      case titleSortAZ:
        return sortByTitleAZ(all, (e) => e.name);
      case titleSortZA:
        return sortByTitleZA(all, (e) => e.name);
      default:
        return all;
    }
  }
}
