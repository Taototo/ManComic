import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/version.dart';

/// 更新包的「下载完成后要不要提示安装」以及下载任务的状态机。
///
/// 这两处一旦写错，用户要么被反复打扰，要么明明下好了却没有入口，
/// 而且界面上看不出任何异常，所以单独把判断逻辑钉住。
void main() {
  group('待安装包是否该提示', () {
    test('没有记录就不提示', () {
      expect(
        shouldOfferPendingUpdate(
          version: null,
          currentVersion: "1.4.15",
          fileUsable: true,
        ),
        isFalse,
      );
      expect(
        shouldOfferPendingUpdate(
          version: "",
          currentVersion: "1.4.15",
          fileUsable: true,
        ),
        isFalse,
      );
    });

    test('安装包不在或大小不对，不提示', () {
      expect(
        shouldOfferPendingUpdate(
          version: "1.4.16",
          currentVersion: "1.4.15",
          fileUsable: false,
        ),
        isFalse,
      );
    });

    test('比当前版本新才提示', () {
      expect(
        shouldOfferPendingUpdate(
          version: "1.4.16",
          currentVersion: "1.4.15",
          fileUsable: true,
        ),
        isTrue,
      );
    });

    test('版本已经追平说明装过了，不再提示', () {
      // 覆盖安装后重新启动就是这种情况：记录还在，但应用已经是新版本
      expect(
        shouldOfferPendingUpdate(
          version: "1.4.16",
          currentVersion: "1.4.16",
          fileUsable: true,
        ),
        isFalse,
      );
      // 装的是更新的版本（比如从别处升级），旧包同样作废
      expect(
        shouldOfferPendingUpdate(
          version: "1.4.16",
          currentVersion: "1.4.17",
          fileUsable: true,
        ),
        isFalse,
      );
    });

    test('用真实的应用版本号走一遍', () {
      expect(
        shouldOfferPendingUpdate(
          version: "99.0.0",
          currentVersion: appVersionName,
          fileUsable: true,
        ),
        isTrue,
        reason: "远高于当前版本的包应该提示安装",
      );
      expect(
        shouldOfferPendingUpdate(
          version: appVersionName,
          currentVersion: appVersionName,
          fileUsable: true,
        ),
        isFalse,
      );
      expect(compareVersion("99.0.0", appVersionName), isTrue);
    });
  });

  group('下载任务状态', () {
    test('初始状态是空闲，没有进度也没有待安装包', () {
      var task = UpdateDownloadController();
      addTearDown(task.dispose);
      expect(task.phase, UpdateDownloadPhase.idle);
      expect(task.isDownloading, isFalse);
      expect(task.pending, isNull);
      expect(task.minimized, isFalse);
      expect(task.progress, 0);
    });

    test('进度按 0..1 归一，总大小未知时给 0', () {
      var task = UpdateDownloadController();
      addTearDown(task.dispose);
      task.received = 25;
      task.total = 100;
      expect(task.progress, 0.25);
      // 服务端给出的总大小偶尔会比实际字节少，不能让进度条冲出 100%
      task.received = 130;
      expect(task.progress, 1.0);
      task.total = 0;
      expect(task.progress, 0);
    });

    test('下载与校验都算「进行中」，完成或失败都不算', () {
      var task = UpdateDownloadController();
      addTearDown(task.dispose);
      for (var phase in [
        UpdateDownloadPhase.downloading,
        UpdateDownloadPhase.verifying,
      ]) {
        task.phase = phase;
        expect(task.isDownloading, isTrue, reason: "$phase");
      }
      for (var phase in [
        UpdateDownloadPhase.idle,
        UpdateDownloadPhase.ready,
        UpdateDownloadPhase.failed,
      ]) {
        task.phase = phase;
        expect(task.isDownloading, isFalse, reason: "$phase");
      }
    });

    test('没有下载时可安全地收起/展开/取消', () {
      var task = UpdateDownloadController();
      addTearDown(task.dispose);
      // 这些方法会被悬浮条和关于页在任意时机调用，不能因为当前没任务就抛异常
      task.minimize();
      task.expand();
      task.cancel();
      expect(task.minimized, isFalse);
      expect(task.phase, UpdateDownloadPhase.idle);
    });
  });

  test('下载卡片、完成提示与悬浮条都可编译', () {
    expect(UpdateDownloadDialog, isNotNull);
    expect(UpdateReadyDialog, isNotNull);
    expect(UpdateDownloadBanner, isNotNull);
    expect(showUpdateReadyDialog, isNotNull);
    expect(updateDownload, isA<UpdateDownloadController>());
  });

  group('待安装记录跨启动', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp("mancomic_update_test");
      App.dataPath = dir.path;
      appdata.implicitData.remove("pendingUpdateVersion");
      appdata.implicitData.remove("pendingUpdateSize");
    });

    tearDown(() async {
      appdata.implicitData.remove("pendingUpdateVersion");
      appdata.implicitData.remove("pendingUpdateSize");
      // writeImplicitData 是 fire-and-forget，等它落盘再删临时目录，
      // 否则偶发「写文件时目录已消失」会污染下一条测试。
      await Future.delayed(const Duration(milliseconds: 100));
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    /// 按真实下载结果的布局放一个安装包：`<dataPath>/updates/ManComic-<ver>.apk`
    File writeApk(String version, int bytes) {
      var updates = Directory(FilePath.join(dir.path, "updates"))
        ..createSync(recursive: true);
      var file = File(FilePath.join(updates.path, "ManComic-$version.apk"));
      file.writeAsBytesSync(List.filled(bytes, 0));
      return file;
    }

    test('安装包在、版本更新：启动后仍能提示安装', () async {
      var apk = writeApk("99.0.0", 2048);
      appdata.implicitData["pendingUpdateVersion"] = "99.0.0";
      appdata.implicitData["pendingUpdateSize"] = apk.lengthSync();
      var task = UpdateDownloadController();
      addTearDown(task.dispose);

      var resolved = await task.resolvePendingUpdate();
      expect(resolved?.version, "99.0.0");
      expect(resolved?.path, apk.path);
      expect(task.pending?.version, "99.0.0");
    });

    test('已经装上了：记录和安装包一起清掉', () async {
      // 覆盖安装后重启就是这种情况：pending 版本已经等于当前版本
      var apk = writeApk(appVersionName, 2048);
      appdata.implicitData["pendingUpdateVersion"] = appVersionName;
      appdata.implicitData["pendingUpdateSize"] = apk.lengthSync();
      var task = UpdateDownloadController();
      addTearDown(task.dispose);

      expect(await task.resolvePendingUpdate(), isNull);
      expect(appdata.implicitData["pendingUpdateVersion"], isNull);
      expect(task.pending, isNull);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(apk.existsSync(), isFalse, reason: "装完之后旧安装包不该继续占空间");
    });

    test('安装包被删了：不提示，也不留死记录', () async {
      appdata.implicitData["pendingUpdateVersion"] = "99.0.0";
      appdata.implicitData["pendingUpdateSize"] = 2048;
      var task = UpdateDownloadController();
      addTearDown(task.dispose);

      expect(await task.resolvePendingUpdate(), isNull);
      expect(appdata.implicitData["pendingUpdateVersion"], isNull);
    });

    test('记录里的大小和文件对不上：当作没下好', () async {
      var apk = writeApk("99.0.0", 2048);
      appdata.implicitData["pendingUpdateVersion"] = "99.0.0";
      appdata.implicitData["pendingUpdateSize"] = apk.lengthSync() + 1;
      var task = UpdateDownloadController();
      addTearDown(task.dispose);

      expect(await task.resolvePendingUpdate(), isNull);
    });
  });
}
