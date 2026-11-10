import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';

/// 删除 / 取消下载的四种状态，以及「取消后重下又读到上次进度」的回归。
///
/// 这几条以前全靠真机复现，结果就是：取消之后再点下载，它记得上次下到哪，
/// 只把后面的章节补完，前面的章节在章节选择里还是灰的、点不动。根因有两处，
/// 这里各钉一组用例：
///
/// 1. 进度文件按「类型:id」索引，取消后重新建的任务会撞上同一个键，把上一轮
///    的 `downloadedCount` / `path` 套到自己身上（[DownloadTask.acceptsProgress]）；
/// 2. 取消时删文件那一步根本没执行（在飞的页被取消后 `wait()` 永远不返回），
///    半截目录留在盘上，下次扫描就当它已下过（残留清理负责兜底）。
void main() {
  late Directory root;
  late Directory dataDir;

  setUpAll(() {
    ComicSourceManager().add(ComicSource.builtin("test", "test-src"));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync("cancel_state");
    dataDir = Directory.systemTemp.createTempSync("cancel_state_data");
    App.dataPath = dataDir.path;
    LocalManager().path = root.path;
    LocalManager().downloadingTasks = [];
  });

  tearDown(() {
    for (var dir in [root, dataDir]) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  String progressKey() => "${ComicType("test-src".hashCode).value}:1";

  Map<String, dynamic> taskJson({
    String? uid,
    String? path,
    Map<String, List<String>>? images,
    bool userPaused = true,
  }) {
    return {
      "type": "ImagesDownloadTask",
      "uid": uid,
      "source": "test-src",
      "comicId": "1",
      "comic": {
        "title": "T",
        "subtitle": "s",
        "cover": "cover",
        "description": "d",
        "tags": <String, dynamic>{},
        "chapters": {"ch1": "第1话"},
        "sourceKey": "test-src",
        "comicId": "1",
      },
      "path": path,
      "images": images,
      "downloadedCount": 0,
      "downloadedBytes": 0,
      "totalCount": 0,
      "index": 0,
      "chapter": 0,
      "userPaused": userPaused,
    };
  }

  void writeProgress(Map<String, dynamic>? progress) {
    File("${dataDir.path}/downloading_progress.json").writeAsStringSync(
      jsonEncode({progressKey(): progress}),
    );
  }

  void writeTasks(Map<String, dynamic> task) {
    File("${dataDir.path}/downloading_tasks.json").writeAsStringSync(
      jsonEncode([task]),
    );
  }

  group('取消之后重新下载', () {
    test('新任务不会继承上一轮任务的进度和目录', () async {
      // 上一轮：下到 500 页、目录在 old 里；用户取消，任务记录清掉了，
      // 但进度文件那条还没轮到重写（进程被划掉就是这个结果）。
      writeProgress({
        "uid": "old-task",
        "downloadedCount": 500,
        "totalCount": 600,
        "chapterPages": {"ch1": 600},
        "path": "${root.path}/old",
      });
      // 这一轮是全新任务：path 还是 null，一页都没下。
      writeTasks(taskJson(uid: "new-task"));

      LocalManager().restoreDownloadingTasks();
      await Future.delayed(const Duration(milliseconds: 100));

      var task = LocalManager().downloadingTasks.single;
      expect(task.path, isNull, reason: '不能认回上一轮的目录，否则只补后面的页');
      expect(task.toProgressJson()['downloadedCount'], 0);
    });

    test('同一个任务重启后仍然认领自己的进度', () async {
      writeProgress({
        "uid": "same-task",
        "downloadedCount": 40,
        "totalCount": 100,
        "chapterPages": {"ch1": 100},
        "path": "${root.path}/kept",
      });
      writeTasks(taskJson(uid: "same-task"));

      LocalManager().restoreDownloadingTasks();
      await Future.delayed(const Duration(milliseconds: 100));

      var task = LocalManager().downloadingTasks.single;
      expect(task.uid, "same-task");
      expect(task.toProgressJson()['downloadedCount'], 40);
      expect(task.path, "${root.path}/kept");
    });

    test('老版本留下的进度（没有 uid）仍然认领', () async {
      // 升级上来的用户：任务文件和进度文件都是旧格式，不能因为加了 uid
      // 就把正在下的任务打回 0。
      writeProgress({
        "downloadedCount": 40,
        "totalCount": 100,
        "chapterPages": {"ch1": 100},
        "path": "${root.path}/kept",
      });
      writeTasks(taskJson());

      LocalManager().restoreDownloadingTasks();
      await Future.delayed(const Duration(milliseconds: 100));

      var task = LocalManager().downloadingTasks.single;
      expect(task.toProgressJson()['downloadedCount'], 40);
    });

    test('任务 uid 会跟着任务一起落盘', () {
      var task = LocalManager().downloadingTasks;
      expect(task, isEmpty);
      var a = ImagesDownloadTask.fromJson(taskJson())!;
      var b = ImagesDownloadTask.fromJson(taskJson())!;
      expect(a.uid, isNot(b.uid), reason: '同一本漫画的两个任务实例必须能区分');
      expect(a.toJson()['uid'], a.uid);
      expect(a.toProgressJson()['uid'], a.uid);
    });

    test('acceptsProgress 只认自己那一份', () {
      var task = ImagesDownloadTask.fromJson(taskJson(uid: "abc"))!;
      expect(task.acceptsProgress({"uid": "abc", "downloadedCount": 9}), isTrue);
      expect(task.acceptsProgress({"uid": "xyz", "downloadedCount": 9}), isFalse);
      // 没有 uid 的历史进度照收
      expect(task.acceptsProgress({"downloadedCount": 9}), isTrue);
    });
  });

  group('正文页文件名判定', () {
    test('页码命名的图算正文页', () {
      expect(isPageFileName("0.jpg"), isTrue);
      expect(isPageFileName("12.webp"), isTrue);
      expect(isPageFileName("7"), isTrue);
    });

    test('封面、隐藏文件和 json 不算', () {
      expect(isPageFileName("cover.jpg"), isFalse);
      expect(isPageFileName(".nomedia"), isFalse);
      expect(isPageFileName("details.json"), isFalse);
      expect(isPageFileName("readme.txt"), isFalse);
    });
  });

}
