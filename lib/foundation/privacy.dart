import 'package:venera/foundation/appdata.dart';

/// 应用内隐私保护。
class Privacy {
  Privacy._();

  static bool _favoritesUnlocked = false;

  /// 收藏页当前是否处于锁定状态。
  ///
  /// 开启设置后，每次启动应用首次进入收藏页都会被遮罩挡住，
  /// 手动解锁后保持解锁，直到下一次启动应用。
  static bool get isFavoritesLocked =>
      appdata.settings['privacyFavorites'] == true && !_favoritesUnlocked;

  /// 解锁收藏页，效果持续到本次运行结束。
  static void unlockFavorites() {
    _favoritesUnlocked = true;
  }
}
