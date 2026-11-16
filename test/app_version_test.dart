import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/version.dart';

/// 校验发布版本号只有一处「事实来源」之外没有漂移。
///
/// `appVersionName` 会显示在「关于」页面并参与更新检查，
/// 一旦与 pubspec.yaml / build.gradle 不一致，就会出现
/// 「关于页版本号与安装包版本不符」或「永远提示没有新版本」的问题。
///
/// 与 pubspec 的关系只能是「前缀相等」而不是「完全相等」：pub 的语义化
/// 版本规定只有三段，`1.5.2.001` 这种四段补丁号写进 `pubspec.yaml` 会
/// 直接报 Invalid version，所以补丁段只能出现在 gradle 和 consts 里。
void main() {
  test('appVersionName 与 build.gradle 完全一致', () {
    var gradle = File('android/app/build.gradle').readAsStringSync();
    var gradleVersion = RegExp(r'appVersionName\s*=\s*"([0-9.]+)"')
        .firstMatch(gradle)
        ?.group(1);

    expect(gradleVersion, isNotNull, reason: 'build.gradle 中找不到 appVersionName');
    expect(appVersionName, gradleVersion);
  });

  test('pubspec 的版本是 appVersionName 的前缀', () {
    var pubspec = File('pubspec.yaml').readAsStringSync();
    var pubspecVersion = RegExp(r'^version:\s*([0-9.]+)', multiLine: true)
        .firstMatch(pubspec)
        ?.group(1);

    expect(pubspecVersion, isNotNull, reason: 'pubspec.yaml 中找不到 version');
    // 三段是 pub 的硬要求，多一段 `flutter pub get` 就过不去。
    expect(pubspecVersion!.split('.').length, 3);
    expect(
      appVersionName == pubspecVersion ||
          appVersionName.startsWith("$pubspecVersion."),
      isTrue,
      reason: '$appVersionName 的主版本与 pubspec 的 $pubspecVersion 对不上',
    );
  });

  test('补丁段的版本号能被更新检查正确比较', () {
    // 停在 1.5.2 的用户必须能收到 1.5.2.001 的提示，
    // 否则这个补丁对他们等于不存在。
    expect(compareVersion("1.5.2.001", "1.5.2"), isTrue);
    expect(compareVersion("1.5.2.001", "1.5.2.001"), isFalse);
    expect(compareVersion("1.5.2", "1.5.2.001"), isFalse);
  });
}
