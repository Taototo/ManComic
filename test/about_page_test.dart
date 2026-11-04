import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/version.dart';

/// 冒烟测试：引用关于页与更新检查入口，确保整个设置页库（含 about.dart
/// 的 part 文件与新增的 utils/version.dart）能被完整编译。
///
/// 不 pump 界面：AboutSettings 依赖 Appdata / AppIcon / 翻译表等全局初始化，
/// 这里只做编译期校验。
void main() {
  test('关于页与更新检查可编译', () {
    expect(appVersionName, isNotEmpty);
    expect(appRepoUrl, contains(appRepoName));
    expect(appReleasesUrl, endsWith("/releases"));
    expect(AboutSettings, isNotNull);
    expect(fetchLatestVersion, isNotNull);
    expect(checkUpdateUi, isNotNull);
    // 用远超当前版本号的形式写死，避免每次升版本都要改这里
    expect(compareVersion("99.0.0", appVersionName), isTrue);
    expect(compareVersion("0.0.1", appVersionName), isFalse);
  });

  test('只有拿到 APK 直链才算可更新', () {
    // 有 APK 资产：允许弹出「立即更新」
    expect(
      const AppUpdateInfo(
        version: "1.4.2",
        url: "https://github.com/a/b/releases/download/v1.4.2/ManComic-1.4.2.apk",
        apkSize: 51701029,
      ).hasApk,
      isTrue,
    );
    // 只有 Release 页（无资产）：不能弹更新，避免跳到空页面
    expect(
      const AppUpdateInfo(version: "1.4.2", url: "https://github.com/a/b/releases")
          .hasApk,
      isFalse,
    );
    // pubspec 回退：同样不带 APK
    expect(
      const AppUpdateInfo(version: "1.4.2", url: appReleasesUrl).hasApk,
      isFalse,
    );
  });
}
