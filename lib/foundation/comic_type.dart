import 'package:venera/foundation/comic_source/comic_source.dart';

class ComicType {
  final int value;

  const ComicType(this.value);

  @override
  bool operator ==(Object other) => other is ComicType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  String get sourceKey {
    if (this == local) {
      return "local";
    }
    // 源被卸载后 fromIntKey 返回 null。以前这里 `comicSource!.key` 直接抛
    // 空断言，而封面角标每次 build 都会读 sourceKey——用户卸一个源，
    // 打开本地漫画列表就崩。和 FavoriteItem 用同一个兜底格式。
    return comicSource?.key ?? "Unknown:$value";
  }

  ComicSource? get comicSource {
    if(this == local) {
      return null;
    } else {
      return ComicSource.fromIntKey(value);
    }
  }

  static const local = ComicType(0);

  factory ComicType.fromKey(String key) {
    if(key == "local") {
      return local;
    } else {
      return ComicType(key.hashCode);
    }
  }
}