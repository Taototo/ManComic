import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';

/// 重启后进度能不能回来，只能在真机上验；这里把「磁盘上有文件 +
/// 从 JSON 恢复任务」这两步搬进单测，把恢复链路整条跑一遍。
///
/// 背景：1.4.49 还有用户反馈「退出重进进度又回到 0」，排查下来是几条
/// 兜不住的路：地址表没落盘时算不出分母、目录没挂上时扫描得到 0 页、
/// 目录记录丢了就新建一个「标题(1)」让旧目录变孤儿。每条都钉一个用例。
void main() {
  late Directory root;

  setUpAll(() {
    ComicSourceManager().add(ComicSource.builtin("test", "test-src"));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync("restore");
    App.dataPath = root.path;
    LocalManager().path = root.path;
    LocalManager().downloadingTasks = [];
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 在 `<root>/<chapter>/<page>.<ext>` 写下 [pages] 张图
  void writePages(String chapter, int pages, {int size = 100}) {
    var dir = Directory("${root.path}/$chapter")..createSync(recursive: true);
    for (var i = 0; i < pages; i++) {
      File("${dir.path}/$i.jpg").writeAsBytesSync(List.filled(size, 1));
    }
  }

  Map<String, dynamic> taskJson({
    Map<String, List<String>>? images,
    String? path,
    Map<String, dynamic>? chapters,
    bool userPaused = true,
  }) {
    return {
      "type": "ImagesDownloadTask",
      "source": "test-src",
      "comicId": "1",
      "comic": {
        "title": "T",
        "subtitle": "s",
        "cover": "cover",
        "description": "d",
        "tags": <String, dynamic>{},
        "chapters": chapters ?? {"ch1": "第1话"},
        "sourceKey": "test-src",
        "comicId": "1",
      },
      "path": path ?? root.path,
      "images": images,
      "downloadedCount": 0,
      "downloadedBytes": 0,
      "totalCount": 0,
      "index": 0,
      "chapter": 0,
      "userPaused": userPaused,
    };
  }

  String progressKey() => "${ComicType("test-src".hashCode).value}:1";

  void writeFiles(
    Map<String, dynamic> task, {
    Map<String, dynamic>? progress,
  }) {
    File("${root.path}/downloading_tasks.json").writeAsStringSync(
      jsonEncode([task]),
    );
    File("${root.path}/downloading_progress.json").writeAsStringSync(
      jsonEncode({progressKey(): progress ?? <String, dynamic>{}}),
    );
  }

  ImagesDownloadTask restoreTask(Map<String, dynamic> json) {
    var task = ImagesDownloadTask.fromJson(json);
    expect(task, isNotNull);
    LocalManager().downloadingTasks = [task!];
    return task;
  }

  test("磁盘上已有的页会算进进度", () async {
    writePages("ch1", 3);
    var task = restoreTask(
      taskJson(images: {
        "ch1": ["a", "b", "c", "d", "e", "f"],
      }),
    );
    await task.reconcileProgress();
    expect(task.progress, closeTo(0.5, 0.0001));
    expect(task.downloadedBytes, 300);
  });

  test("多章：后面的章已经下完也算数", () async {
    writePages("ch1", 3);
    writePages("ch2", 2);
    var task = restoreTask(
      taskJson(
        images: {
          "ch1": ["a", "b", "c"],
          "ch2": ["d", "e", "f"],
        },
        chapters: {"ch1": "第1话", "ch2": "第2话"},
      ),
    );
    await task.reconcileProgress();
    // 磁盘上 5 页（ch1 全 3 页 + ch2 前 2 页），共 6 页
    expect(task.progress, closeTo(5 / 6, 0.0001));
  });

  test("整条恢复链路：写盘的任务 + 进度文件 + 磁盘文件", () async {
    writePages("ch1", 4, size: 50);
    // 进度文件是「上次落盘那一刻」的，故意写成 0（模拟进程被强杀）
    writeFiles(
      taskJson(images: {
        "ch1": ["a", "b", "c", "d", "e", "f", "g", "h"],
      }),
      progress: {
        "chapter": 0,
        "index": 0,
        "downloadedCount": 0,
        "downloadedBytes": 0,
        "totalCount": 8,
        "userPaused": true,
      },
    );

    LocalManager().restoreDownloadingTasks();
    expect(LocalManager().downloadingTasks, hasLength(1));
    await Future.delayed(const Duration(milliseconds: 200));

    var task = LocalManager().downloadingTasks.first;
    expect(task.progress, closeTo(4 / 8, 0.0001));
    expect(task.userPaused, isTrue);
  });

  test("地址表没落盘时，按进度文件里的每章页数算分母", () async {
    writePages("ch1", 2);
    writeFiles(
      taskJson(images: null),
      progress: {
        "downloadedCount": 0,
        "chapterPages": {"ch1": 4},
        "userPaused": true,
      },
    );

    LocalManager().restoreDownloadingTasks();
    await Future.delayed(const Duration(milliseconds: 200));
    // 只靠「每章几页」也要能算出 2/4，而不是 0
    expect(LocalManager().downloadingTasks.first.progress, closeTo(0.5, 0.0001));
  });

  test("空地址表不会被当成「已经下完」", () async {
    writePages("ch1", 2);
    writeFiles(
      taskJson(images: {}),
      progress: {
        "downloadedCount": 0,
        "chapterPages": {"ch1": 4},
        "userPaused": true,
      },
    );

    LocalManager().restoreDownloadingTasks();
    await Future.delayed(const Duration(milliseconds: 200));
    // 任务还在（没被 completeTask 收走），进度也要在
    expect(LocalManager().downloadingTasks, hasLength(1));
    expect(LocalManager().downloadingTasks.first.progress, closeTo(0.5, 0.0001));
  });

  test("目录还没就绪时不把进度抹成 0", () async {
    var missing = "${root.path}/not_mounted";
    var task = restoreTask(
      taskJson(
        images: {
          "ch1": ["a", "b", "c", "d"],
        },
        path: missing,
      )..addAll({"downloadedCount": 2, "totalCount": 4}),
    );
    await task.reconcileProgress();
    // 目录不存在 → 保持原样，绝不写成 0
    expect(task.progress, closeTo(0.5, 0.0001));
  });

  test("目录记录丢了会找回旧目录，而不是新建一个", () async {
    // 旧目录叫「T(1)」，说明是第二轮下载时建出来的
    writePages("T(1)/ch1", 2);
    File("${root.path}/T(1)/details.json").writeAsStringSync(
      jsonEncode({"title": "T", "comicId": "1", "sourceKey": "test-src"}),
    );
    var found = LocalManager().findReusableDirectory(
      "T",
      comicId: "1",
      sourceKey: "test-src",
    );
    expect(found, isNotNull);
    expect(found!.path.endsWith("T(1)"), isTrue);
  });

  test("同名但不是同一本的目录不会被认领", () async {
    writePages("T(1)/ch1", 2);
    File("${root.path}/T(1)/details.json").writeAsStringSync(
      jsonEncode({"title": "T", "comicId": "999", "sourceKey": "other-src"}),
    );
    expect(
      LocalManager().findReusableDirectory(
        "T",
        comicId: "1",
        sourceKey: "test-src",
      ),
      isNull,
    );
  });

  test("进度快照会带上每章页数，够下次算分母", () {
    var task = restoreTask(
      taskJson(images: {
        "ch1": ["a", "b", "c"],
        "ch2": ["d"],
      }),
    );
    var json = task.toProgressJson();
    expect(json["chapterPages"], {"ch1": 3, "ch2": 1});
    expect(json["path"], root.path);
  });
}
