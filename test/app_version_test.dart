import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/consts.dart';

/// 校验发布版本号只有一处「事实来源」之外没有漂移。
///
/// `appVersionName` 会显示在「关于」页面并参与更新检查，
/// 一旦与 pubspec.yaml / build.gradle 不一致，就会出现
/// 「关于页版本号与安装包版本不符」或「永远提示没有新版本」的问题。
void main() {
  test('appVersionName 与 pubspec.yaml、build.gradle 保持一致', () {
    var pubspec = File('pubspec.yaml').readAsStringSync();
    var pubspecVersion = RegExp(r'^version:\s*([0-9.]+)', multiLine: true)
        .firstMatch(pubspec)
        ?.group(1);

    expect(pubspecVersion, isNotNull, reason: 'pubspec.yaml 中找不到 version');

    var gradle = File('android/app/build.gradle').readAsStringSync();
    var gradleVersion = RegExp(r'appVersionName\s*=\s*"([0-9.]+)"')
        .firstMatch(gradle)
        ?.group(1);

    expect(gradleVersion, isNotNull, reason: 'build.gradle 中找不到 appVersionName');

    expect(appVersionName, pubspecVersion);
    expect(appVersionName, gradleVersion);
  });
}
