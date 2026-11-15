import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/local_health.dart';
import 'package:venera/pages/local_health_page.dart';
import 'package:venera/utils/translations.dart';

/// 书库体检的判定层。
///
/// 这一层判错的代价是删用户的文件或者删记录：把「其实有图」的判成失效，
/// 用户点一下「全部清理」，几十 GB 就从列表里消失了（文件还在，但得自己
/// 去文件夹里找回来）。所以每个分类都单独钉一条，尤其是那几个「不该被
/// 列进来」的反例。
///
/// Windows 上 git 按 autocrlf 把源码换成 CRLF，而断言里写的是 `\n`。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

LocalComic comic({
  required String dir,
  Map<String, String>? chapters,
  List<String> downloaded = const [],
  String title = '测试漫画',
}) {
  return LocalComic(
    id: '1',
    title: title,
    subtitle: '',
    tags: const [],
    // 绝对路径：`LocalComic.baseDir` 见到分隔符就直接返回，不走 LocalManager
    // （单测里没有打开过数据库）。
    directory: dir,
    chapters: chapters == null ? null : ComicChapters(chapters),
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: downloaded,
    createdAt: DateTime(2026, 1, 1),
  );
}

LocalEntryScan entry(
  String dir, {
  bool dirExists = true,
  int pages = 10,
  List<String> onDisk = const [],
  int unknownDirs = 0,
  Map<String, String>? chapters,
  List<String> downloaded = const [],
}) {
  return LocalEntryScan(
    comic: comic(dir: dir, chapters: chapters, downloaded: downloaded),
    baseDir: dir,
    dirExists: dirExists,
    pages: pages,
    onDiskChapters: onDisk,
    unknownDirs: unknownDirs,
  );
}

LocalDirSnapshot dir(String name, int bytes, {int pages = 0}) {
  return LocalDirSnapshot(
    name: name,
    path: '/local/$name',
    bytes: bytes,
    pages: pages,
  );
}

void main() {
  group('失效记录', () {
    test('目录不在 = 失效', () {
      final report = buildLocalHealthReport(
        entries: [entry('/local/a', dirExists: false)],
        rootDirs: const [],
      );
      expect(report.deadEntries.length, 1);
      expect(
        report.deadEntries.single.reason,
        DeadEntryReason.directoryMissing,
      );
      expect(report.orphans, isEmpty, reason: '目录不在就谈不上残留目录');
    });

    test('目录在但一页都没有 = 失效', () {
      final report = buildLocalHealthReport(
        entries: [
          entry('/local/a', pages: 0, chapters: {'c1': '1'}),
        ],
        rootDirs: [dir('a', 0)],
      );
      expect(report.deadEntries.single.reason, DeadEntryReason.noPages);
      expect(report.orphans, isEmpty, reason: '这本书还占着这条记录，目录不算孤儿');
    });

    test('有页就不算失效', () {
      final report = buildLocalHealthReport(
        entries: [
          entry(
            '/local/a',
            pages: 3,
            onDisk: ['c1'],
            chapters: {'c1': '1'},
            downloaded: ['c1'],
          ),
        ],
        rootDirs: [dir('a', 1024, pages: 3)],
      );
      expect(report.deadEntries, isEmpty);
    });
  });

  group('记录与磁盘不符', () {
    test('记录 8 话、盘上 5 话', () {
      final chapters = {for (var i = 1; i <= 8; i++) 'c$i': '$i'};
      final report = buildLocalHealthReport(
        entries: [
          entry(
            '/local/a',
            onDisk: ['c1', 'c2', 'c3', 'c4', 'c5'],
            chapters: chapters,
            downloaded: chapters.keys.toList(),
          ),
        ],
        rootDirs: [dir('a', 1024, pages: 50)],
      );
      expect(report.staleEntries.length, 1);
      expect(report.staleEntries.single.missingFromDisk, ['c6', 'c7', 'c8']);
      expect(report.staleEntries.single.missingFromRecord, isEmpty);
    });

    test('盘上多出没记录的章', () {
      final report = buildLocalHealthReport(
        entries: [
          entry(
            '/local/a',
            onDisk: ['c1', 'c2'],
            chapters: {'c1': '1', 'c2': '2'},
            downloaded: ['c1'],
          ),
        ],
        rootDirs: [dir('a', 1024, pages: 20)],
      );
      expect(report.staleEntries.single.missingFromRecord, ['c2']);
      expect(report.staleEntries.single.missingFromDisk, isEmpty);
    });

    test('记录和磁盘一致就不报（顺序不同也算一致）', () {
      final report = buildLocalHealthReport(
        entries: [
          entry(
            '/local/a',
            onDisk: ['c1', 'c2'],
            chapters: {'c1': '1', 'c2': '2'},
            downloaded: ['c2', 'c1'],
          ),
        ],
        rootDirs: [dir('a', 1024, pages: 20)],
      );
      expect(report.staleEntries, isEmpty);
    });

    test('没有章节表的书只数页，不判记录', () {
      final report = buildLocalHealthReport(
        entries: [entry('/local/a', pages: 12)],
        rootDirs: [dir('a', 1024, pages: 12)],
      );
      expect(report.staleEntries, isEmpty);
      expect(report.unrecognized, isEmpty);
    });

    test('有图但一话都对不上 = 只报告，不给修', () {
      final report = buildLocalHealthReport(
        entries: [
          entry(
            '/local/a',
            onDisk: const [],
            unknownDirs: 3,
            chapters: {'c1': '1'},
            downloaded: ['c1'],
          ),
        ],
        rootDirs: [dir('a', 1024, pages: 30)],
      );
      expect(report.unrecognized.single.dirs, 3);
      // 修复的目标是「按磁盘重写记录」，这里一话都对不上，重写等于清空，
      // 所以绝不能把它列进 stale 让用户一键修掉。
      expect(report.staleEntries, isEmpty);
      expect(report.deadEntries, isEmpty);
    });
  });

  group('残留目录', () {
    test('没人认领的目录算残留', () {
      final report = buildLocalHealthReport(
        entries: [entry('/local/keep', pages: 1)],
        rootDirs: [dir('keep', 100), dir('lost', 500, pages: 8)],
      );
      expect(report.orphans.single.name, 'lost');
      expect(report.orphans.single.bytes, 500);
      expect(report.orphanBytes, 500);
    });

    test('记录指向子目录时，它的上级目录也算认领', () {
      final report = buildLocalHealthReport(
        entries: [entry('/local/book/volume-1', pages: 5)],
        rootDirs: [dir('book', 900, pages: 9)],
      );
      expect(report.orphans, isEmpty, reason: '按相等比会把它挪进回收站');
    });

    test('正在下载的目录不算残留', () {
      final report = buildLocalHealthReport(
        entries: const [],
        rootDirs: [dir('downloading', 400)],
        reservedPaths: ['/local/downloading'],
      );
      expect(report.orphans, isEmpty);
    });

    test('点开头的是自己的东西（回收站），永远不碰', () {
      final report = buildLocalHealthReport(
        entries: const [],
        rootDirs: [dir('.trash', 700), dir('.nomedia', 1)],
      );
      expect(report.orphans, isEmpty);
    });

    test('按占用从大到小排', () {
      final report = buildLocalHealthReport(
        entries: const [],
        rootDirs: [dir('small', 10), dir('big', 900), dir('mid', 300)],
      );
      expect(report.orphans.map((e) => e.name), ['big', 'mid', 'small']);
    });
  });

  group('路径规范化', () {
    test('分隔符和尾部斜杠不影响判定', () {
      expect(normalizeLocalPath('/local/a//'), '/local/a');
      expect(normalizeLocalPath(r'/local\a'), '/local/a');
    });

    test('Windows 上大小写不敏感', () {
      // CI 跑在 Linux，那里 `/Local` 和 `/local` 确实是两个目录，不能一概转
      // 小写；只有 Windows 才做归一。
      const raw = r'D:\Local\A\';
      if (Platform.isWindows) {
        expect(normalizeLocalPath(raw), 'd:/local/a');
      } else {
        expect(normalizeLocalPath(raw), 'D:/Local/A');
      }
    });

    test('反斜杠写的记录也能认领正斜杠的目录', () {
      final report = buildLocalHealthReport(
        entries: [entry(r'/local/a', pages: 3)],
        rootDirs: [dir('a', 100)],
      );
      expect(report.orphans, isEmpty);
    });
  });

  group('真实目录扫描', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('health');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    void writeChapter(String name, int pages) {
      final chapter = Directory('${root.path}/book/$name')
        ..createSync(recursive: true);
      for (var i = 0; i < pages; i++) {
        File('${chapter.path}/$i.jpg').writeAsStringSync('x');
      }
    }

    test('数得清页，封面和 details.json 不算页', () async {
      writeChapter('c1', 3);
      File('${root.path}/book/cover.jpg').writeAsStringSync('x');
      File('${root.path}/book/details.json').writeAsStringSync('{}');
      // 0 字节的页是上次写到一半被打断的，阅读器也不认。
      File('${root.path}/book/c1/9.jpg').writeAsStringSync('');
      final scan = await LocalLibraryHealth.scanEntry(
        comic(
          dir: '${root.path}/book',
          chapters: {'c1': '第1话'},
          downloaded: ['c1'],
        ),
      );
      expect(scan.dirExists, isTrue);
      expect(scan.pages, 3);
      expect(scan.onDiskChapters, ['c1']);
      expect(scan.unknownDirs, 0);
    });

    test('空目录里的章节不算下好', () async {
      Directory('${root.path}/book/c2').createSync(recursive: true);
      writeChapter('c1', 2);
      final scan = await LocalLibraryHealth.scanEntry(
        comic(
          dir: '${root.path}/book',
          chapters: {'c1': '第1话', 'c2': '第2话'},
          downloaded: ['c1', 'c2'],
        ),
      );
      expect(scan.onDiskChapters, ['c1']);
    });

    test('按标题建目录的老记录也能对上', () async {
      // 源站换过章节 id：记录里是 c9，盘上那层目录叫「第1话」。
      writeChapter('第1话', 2);
      final scan = await LocalLibraryHealth.scanEntry(
        comic(
          dir: '${root.path}/book',
          chapters: {'c9': '第1话'},
          downloaded: ['c9'],
        ),
      );
      expect(scan.onDiskChapters, ['c9']);
      expect(scan.unknownDirs, 0);
    });

    test('目录不在直接判失效，不再往下数', () async {
      final scan = await LocalLibraryHealth.scanEntry(
        comic(dir: '${root.path}/missing', chapters: {'c1': '1'}),
      );
      expect(scan.dirExists, isFalse);
      expect(scan.pages, 0);
    });

    test('量根目录能看出哪个文件夹是残留', () async {
      writeChapter('c1', 2);
      final orphan = Directory('${root.path}/gone')..createSync();
      File('${orphan.path}/0.jpg').writeAsStringSync('xxxx');
      final dirs = await LocalLibraryHealth.snapshotRoot(root.path);
      expect(dirs.map((e) => e.name), containsAll(['book', 'gone']));
      expect(dirs.firstWhere((e) => e.name == 'gone').pages, 1);
      expect(dirs.firstWhere((e) => e.name == 'gone').bytes, 4);
    });
  });

  group('守卫', () {
    test('清理残留目录只挪不删', () {
      final src = read('lib/foundation/local_health.dart');
      final start = src.indexOf('static Future<({List<String> moved');
      final end = src.indexOf('static Future<int> trashSize');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final quarantine = src.substring(start, end);
      expect(quarantine.contains('rename('), isTrue);
      expect(
        quarantine.contains('.delete('),
        isFalse,
        reason: '书库清理必须可逆，删了就没法反悔',
      );
    });
  });

  group('页面渲染', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await AppTranslation.init();
    });

    testWidgets('四类结果同时出现时窄屏不溢出', (tester) async {
      // 屏幕给高一点：SliverList 只建可见的那几行，360×900 下最后一类根本
      // 不会被布局，也就白测了。
      await tester.binding.setSurfaceSize(const Size(360, 1600));
      final report = LocalHealthReport(
        orphans: [
          OrphanDir(
            name: 'old-book',
            path: '/local/old-book',
            bytes: 30 * 1024 * 1024,
            pages: 120,
          ),
        ],
        deadEntries: [
          DeadEntry(
            comic: comic(dir: '/local/dead', title: '失效的书'),
            baseDir: '/local/dead',
            reason: DeadEntryReason.directoryMissing,
          ),
        ],
        staleEntries: [
          StaleEntry(
            comic: comic(
              dir: '/local/stale',
              title: '对不上的书',
              chapters: {'c1': '1', 'c2': '2'},
              downloaded: ['c1', 'c2'],
            ),
            recorded: const ['c1', 'c2'],
            onDisk: const ['c1'],
          ),
        ],
        unrecognized: [
          UnrecognizedEntry(
            comic: comic(dir: '/local/x', title: '认不出的书'),
            dirs: 2,
          ),
        ],
        trashBytes: 1024,
        trashDirs: 1,
        scannedEntries: 42,
        scannedDirs: 5,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LocalHealthPage(initialReport: report)),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 按数据（书名/目录名）断言，不看会随语言变化的标签。
      expect(find.text('old-book'), findsOneWidget);
      expect(find.text('失效的书'), findsOneWidget);
      expect(find.text('对不上的书'), findsOneWidget);
      expect(find.text('认不出的书'), findsOneWidget);
    });

    testWidgets('干净的书库只显示结论', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalHealthPage(
              initialReport: const LocalHealthReport(
                orphans: [],
                deadEntries: [],
                staleEntries: [],
                unrecognized: [],
                trashBytes: 0,
                trashDirs: 0,
                scannedEntries: 12,
                scannedDirs: 12,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.folder_off_outlined), findsNothing);
      expect(find.byIcon(Icons.recycling_rounded), findsNothing);
    });
  });
}
