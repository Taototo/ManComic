import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

/// 漫画备份到网盘（WebDAV）的队列。
///
/// 和数据同步那套 WebDAV 完全独立：那边只传几 MB 的收藏与历史，放在
/// 坚果云这类小额度盘上刚好；漫画动辄几百 MB，必须单独配一个大盘。
/// 两套配置共用同一个 Key 会互相覆盖，所以配置项是 `comicWebdav`。
///
/// 上传按本地目录原样镜像，一个文件一个文件传。不打包成 zip，是因为
/// 网盘线路要支持「按页懒加载」——只有每个文件都是独立的 HTTP 资源，
/// 阅读器才能只拉当前页。代价是请求数多，所以这里做了两件事：
///   1. 每进一个目录先 PROPFIND 一次拿已有文件名，只传缺的（断点续传）；
///   2. 全程串行，避免把中转/网盘打限速。
class CloudLibrary with ChangeNotifier {
  CloudLibrary._();

  static CloudLibrary? _instance;

  factory CloudLibrary() => _instance ??= CloudLibrary._();

  /// 当前配置：[url, user, pass]，未配置时为 null。
  List<String>? get config {
    final c = appdata.settings['comicWebdav'];
    if (c is! List || c.length != 3 || c.whereType<String>().length != 3) {
      return null;
    }
    final list = List<String>.from(c);
    if (list[0].trim().isEmpty) {
      return null;
    }
    return list;
  }

  bool get isConfigured => config != null;

  final List<CloudUploadTask> _tasks = [];

  /// 上传队列，按加入顺序执行。
  List<CloudUploadTask> get tasks => List.unmodifiable(_tasks);

  bool _running = false;

  bool get isRunning => _running;

  bool _stopRequested = false;

  int get pendingCount =>
      _tasks.where((e) => e.status == CloudUploadStatus.pending).length;

  int get failedCount =>
      _tasks.where((e) => e.status == CloudUploadStatus.failed).length;

  /// 本次运行中已创建过的远端目录，避免每张图都发一次 mkdir。
  final Set<String> _createdDirs = {};

  File get _taskFile =>
      File(FilePath.join(App.dataPath, 'cloud_upload_tasks.json'));

  /// 是否已经备份过（或在队列里）。
  bool isBackedUp(String comicId, String sourceKey) {
    return _tasks.any(
      (e) =>
          e.comicId == comicId &&
          e.sourceKey == sourceKey &&
          e.status != CloudUploadStatus.failed,
    );
  }

  CloudUploadTask? taskOf(String comicId, String sourceKey) {
    for (final task in _tasks) {
      if (task.comicId == comicId && task.sourceKey == sourceKey) {
        return task;
      }
    }
    return null;
  }

  void loadTasks() {
    try {
      if (!_taskFile.existsSync()) {
        return;
      }
      final data = jsonDecode(_taskFile.readAsStringSync());
      if (data is! List) {
        return;
      }
      _tasks
        ..clear()
        ..addAll(
          data
              .whereType<Map>()
              .map((e) => CloudUploadTask.fromJson(Map.from(e)))
              .whereType<CloudUploadTask>(),
        );
      // 上次退出时正在传的那本，重新排队；否则会永远停在 uploading。
      for (final task in _tasks) {
        if (task.status == CloudUploadStatus.uploading) {
          task.status = CloudUploadStatus.pending;
        }
      }
      notifyListeners();
    } catch (e, s) {
      Log.error("CloudLibrary", "load tasks failed: $e", s);
    }
  }

  Future<void> saveTasks() async {
    try {
      await _taskFile.writeAsString(
        jsonEncode(_tasks.map((e) => e.toJson()).toList()),
      );
    } catch (e, s) {
      Log.error("CloudLibrary", "save tasks failed: $e", s);
    }
  }

  /// 把一本本地漫画加入上传队列。
  void enqueue(LocalComic comic) {
    final key = "${comic.comicType.sourceKey}/${comic.id}";
    final existing = _tasks.where((e) => e.key == key).toList();
    // 已经传完的不重复排队；失败或中断的重新来一次。
    if (existing.any((e) => e.status == CloudUploadStatus.done)) {
      return;
    }
    _tasks.removeWhere((e) => e.key == key);
    _tasks.add(
      CloudUploadTask(
        comicId: comic.id,
        sourceKey: comic.comicType.sourceKey,
        directory: comic.directory,
        title: comic.title,
      ),
    );
    saveTasks();
    notifyListeners();
    unawaited(run());
  }

  void retryFailed() {
    for (final task in _tasks) {
      if (task.status == CloudUploadStatus.failed) {
        task
          ..status = CloudUploadStatus.pending
          ..error = null
          ..uploaded = 0
          ..total = 0;
      }
    }
    saveTasks();
    notifyListeners();
    unawaited(run());
  }

  void removeTask(CloudUploadTask task) {
    _tasks.remove(task);
    saveTasks();
    notifyListeners();
  }

  /// 停止当前运行。正在传的那个文件会传完，之后不再取新任务。
  void stop() {
    _stopRequested = true;
  }

  Client _newClient(List<String> config) {
    return newClient(
      config[0],
      user: config[1],
      password: config[2],
      adapter: RHttpAdapter(),
    );
  }

  /// 网盘上某个文件的直链。分段编码：整串 encode 会把 `/` 也转义掉。
  String imageUrl(String path) {
    final base = config?[0] ?? '';
    var normalized = base;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final encoded = path
        .split('/')
        .where((e) => e.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return "$normalized/$encoded";
  }

  /// 老下载（1.4.28 之前）目录里没有 details.json，网盘线路就没有详情可读。
  /// 用本地库里的标题、封面、章节表补一份最小快照，旧漫画也能在线读。
  static Map<String, dynamic> _minimalDetails(LocalComic comic) {
    return {
      "title": comic.title,
      "subtitle": comic.subtitle,
      "cover": comic.cover,
      "tags": comic.tags,
      "chapters": comic.chapters?.toJson(),
      "sourceKey": comic.comicType.sourceKey,
      "comicId": comic.id,
    };
  }

  Future<void> run() async {
    if (_running) {
      return;
    }
    final config = this.config;
    if (config == null) {
      return;
    }
    _running = true;
    _stopRequested = false;
    _createdDirs.clear();
    notifyListeners();
    try {
      final client = _newClient(config);
      while (!_stopRequested) {
        final task = _tasks.firstWhereOrNull(
          (e) => e.status == CloudUploadStatus.pending,
        );
        if (task == null) {
          break;
        }
        task
          ..status = CloudUploadStatus.uploading
          ..error = null
          ..uploaded = 0;
        notifyListeners();
        try {
          await _uploadComic(client, task);
          task.status = CloudUploadStatus.done;
          Log.info("CloudLibrary", "${task.title} uploaded");
        } catch (e, s) {
          task
            ..status = CloudUploadStatus.failed
            ..error = e.toString();
          Log.error("CloudLibrary", "upload ${task.title} failed: $e", s);
        }
        await saveTasks();
        notifyListeners();
      }
    } catch (e, s) {
      Log.error("CloudLibrary", "run failed: $e", s);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _uploadComic(Client client, CloudUploadTask task) async {
    final base = FilePath.join(LocalManager().path, task.directory);
    if (!Directory(base).existsSync()) {
      throw "Local files not found";
    }
    final files = <File>[];
    await for (final entity in Directory(base).list(recursive: true)) {
      if (entity is File) {
        // 隐藏文件和 .nomedia 不需要上传
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('.')) {
          continue;
        }
        files.add(entity);
      }
    }
    if (files.isEmpty) {
      throw "Nothing to upload";
    }

    // 缺详情快照时补一份（见 _minimalDetails）。它不走磁盘，直接作为
    // 一个待上传的内存文件混进根目录那一组。
    final generated = <String, Uint8List>{};
    if (!File(FilePath.join(base, 'details.json')).existsSync()) {
      final comic = LocalManager().find(
        task.comicId,
        ComicType.fromKey(task.sourceKey),
      );
      if (comic != null) {
        generated['details.json'] = Uint8List.fromList(
          utf8.encode(jsonEncode(_minimalDetails(comic))),
        );
      }
    }

    task.total = files.length + generated.length;
    notifyListeners();

    // 按所在目录分组：同一目录只查一次远端清单。
    final byDir = <String, List<File>>{};
    for (final file in files) {
      final rel = _relative(file.path, base);
      final index = rel.lastIndexOf('/');
      final dir = index == -1 ? '' : rel.substring(0, index);
      byDir.putIfAbsent(dir, () => []).add(file);
    }
    if (generated.isNotEmpty) {
      byDir.putIfAbsent('', () => []);
    }

    for (final entry in byDir.entries) {
      if (_stopRequested) {
        return;
      }
      final remoteDir = entry.key.isEmpty
          ? "/${task.directory}"
          : "/${task.directory}/${entry.key}";
      await _ensureDir(client, remoteDir);

      // 远端已有的文件名。拿不到就当空集合，全部重传一遍——
      // 顶多浪费一次流量，总比因为一次 PROPFIND 失败而整本卡住好。
      final existing = <String>{};
      try {
        final list = await client.readDir(remoteDir);
        for (final remote in list) {
          existing.add(_baseName(remote.name ?? ''));
        }
      } catch (_) {}

      for (final file in entry.value) {
        if (_stopRequested) {
          return;
        }
        final name = _baseName(file.path);
        if (existing.contains(name)) {
          task.uploaded++;
          notifyListeners();
          continue;
        }
        final bytes = await file.readAsBytes();
        await client.write("$remoteDir/$name", bytes);
        task.uploaded++;
        notifyListeners();
      }

      if (entry.key.isEmpty && generated.isNotEmpty) {
        for (final extra in generated.entries) {
          if (existing.contains(extra.key)) {
            continue;
          }
          await client.write("$remoteDir/${extra.key}", extra.value);
          task.uploaded++;
          notifyListeners();
        }
      }
    }
  }

  Future<void> _ensureDir(Client client, String path) async {
    final parts = path.split('/').where((e) => e.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current = "$current/$part";
      if (_createdDirs.contains(current)) {
        continue;
      }
      try {
        await client.mkdir(current);
      } catch (_) {
        // 已存在
      }
      _createdDirs.add(current);
    }
  }

  /// 测试连接：在目标根目录列一次文件，确认地址、账号、权限都通。
  Future<String?> testConnection(List<String> config) async {
    try {
      final client = _newClient(config);
      await client.readDir('/');
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  static String _relative(String path, String base) {
    var p = path.replaceAll('\\', '/');
    var b = base.replaceAll('\\', '/');
    if (p.startsWith(b)) {
      p = p.substring(b.length);
    }
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    return p;
  }

  static String _baseName(String path) {
    final p = path.replaceAll('\\', '/');
    final index = p.lastIndexOf('/');
    return index == -1 ? p : p.substring(index + 1);
  }
}

enum CloudUploadStatus { pending, uploading, done, failed }

class CloudUploadTask {
  CloudUploadTask({
    required this.comicId,
    required this.sourceKey,
    required this.directory,
    required this.title,
    this.status = CloudUploadStatus.pending,
    this.uploaded = 0,
    this.total = 0,
    this.error,
  });

  final String comicId;

  final String sourceKey;

  /// 本地目录名，也是网盘上的目录名。
  final String directory;

  final String title;

  CloudUploadStatus status;

  /// 已处理（含跳过）的文件数
  int uploaded;

  /// 总文件数，开始传之前是 0
  int total;

  String? error;

  String get key => "$sourceKey/$comicId";

  double get progress {
    if (total <= 0) {
      return status == CloudUploadStatus.done ? 1 : 0;
    }
    return (uploaded / total).clamp(0, 1).toDouble();
  }

  Map<String, dynamic> toJson() {
    return {
      "comicId": comicId,
      "sourceKey": sourceKey,
      "directory": directory,
      "title": title,
      "status": status.name,
      "uploaded": uploaded,
      "total": total,
      "error": error,
    };
  }

  static CloudUploadTask? fromJson(Map map) {
    final comicId = map["comicId"];
    final directory = map["directory"];
    if (comicId is! String || directory is! String) {
      return null;
    }
    return CloudUploadTask(
      comicId: comicId,
      sourceKey: map["sourceKey"]?.toString() ?? "local",
      directory: directory,
      title: map["title"]?.toString() ?? directory,
      status: CloudUploadStatus.values.firstWhere(
        (e) => e.name == map["status"],
        orElse: () => CloudUploadStatus.pending,
      ),
      uploaded: map["uploaded"] is int ? map["uploaded"] : 0,
      total: map["total"] is int ? map["total"] : 0,
      error: map["error"]?.toString(),
    );
  }
}
