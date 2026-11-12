import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';

/// 一章的体检结论。
enum ChapterGapKind {
  /// 一张图都没有：从没下过，或者文件夹被删了。
  missing,

  /// 本地有图，但比源站少——下载时某一页一直失败、整章被跳过留下的半截。
  incomplete,
}

class ChapterGap {
  ChapterGap({
    required this.id,
    required this.title,
    required this.localPages,
    required this.expectedPages,
    this.holes = false,
  });

  /// 章节 id。无章节表的漫画（单话导入/单话下载）是空串。
  final String id;

  final String title;

  /// 磁盘上的页数。
  final int localPages;

  /// 源站的页数。`0` 表示没问源站（[holes] 为真时靠断号判出来的）。
  final int expectedPages;

  /// 页码中间断了：缺的页不用问源站就能确定，但缺几页不知道。
  final bool holes;

  ChapterGapKind get kind =>
      localPages <= 0 ? ChapterGapKind.missing : ChapterGapKind.incomplete;

  /// 还差几页。核对不出来时按 0 算——不能拿「不知道」当「缺很多」。
  int get missingPages =>
      expectedPages > localPages ? expectedPages - localPages : 0;
}

class ComicGapReport {
  const ComicGapReport({
    required this.gaps,
    required this.total,
    required this.unverified,
    required this.cancelled,
    this.skipped = 0,
  });

  /// 需要补的章节，保持目录顺序（第几话就排第几）。
  final List<ChapterGap> gaps;

  /// 这本书目录里一共几话。
  final int total;

  /// 本地有图、但没能向源站核对页数的章数。这里面可能还藏着缺页的。
  final int unverified;

  /// 用户中途取消了：结果只覆盖扫到的部分。
  final bool cancelled;

  /// 磁盘上有图、记录里也标着「已下载」，因此没有联网核对的章数。
  ///
  /// 这些章在下载完成时已经按地址表逐页核对过（1.4.57 起的 `add()` 会核对），
  /// 把几百话全部再问一遍源站要几分钟，收益却接近于零。界面必须把这个数字
  /// 和「没核对」区分开说，否则用户会以为整本都验过了。
  final int skipped;

  bool get isEmpty => gaps.isEmpty;

  int get missingCount =>
      gaps.where((e) => e.kind == ChapterGapKind.missing).length;

  int get incompleteCount => gaps.length - missingCount;
}

/// 进度回调。第一遍数盘时 [verifying] 为 false，第二遍问源站时为 true，
/// 两遍的 [total] 不是同一个分母（第二遍只问有图的章节）。
typedef GapScanProgress = void Function(int done, int total, bool verifying);

/// 找出这本书在磁盘上缺了哪些章。
///
/// 两步走：
///
/// 1. **数盘**（不联网，几百话也就一两秒）。一页没有 = 缺；页码从 0 开始却
///    中间断号 = 缺，这两种都不必问源站。
/// 2. **核对**（联网，一话一个请求，这是慢的那一步）。只问「磁盘上有图、
///    但记录里没说它下完了」的章节，以及页码看着连续、但可能是「只差最后
///    一页」的章节。
///
/// 为什么不能只信 `downloadedChapters`：1.4.57 之前会把缺页的半章也记成已
/// 下载；而下载时某一页连续失败会整章跳过，留下的半截**既不在记录里**，也
/// 和「一页没下」长得不一样——只有数一遍才分得清。
///
/// 反过来也不能把记录里的章全部重问一遍：一本 800 话的书就是 800 个请求，
/// 用户等到的是「检测怎么这么慢」。[verifyRecorded] 打开才做全量核对。
class ComicGapScanner {
  /// 核对页数时同时问几章。下载引擎同一时间也在发（3 章 × 5 页），这里不必
  /// 更保守；再高容易被源站当场限流。
  static const verifyConcurrency = 6;

  /// 连续这么多次问不到就认为源站不可用，剩下的不再问。
  ///
  /// 源站挂掉时每个请求要等满 15 秒超时，800 话排队等于让用户盯着转圈半
  /// 小时。宁可报「有 N 话没核对上」，也不能把失败伪装成「正在检查」。
  static const maxConsecutiveFailures = 8;

  /// 本次运行里已经问到的页数，key 是「源 + 书 + 章节」。
  ///
  /// 用户点一次「重新扫描」不该再发几百个请求。源站改一话的页数极其罕见，
  /// 而一话页数扫一次要几秒。只放内存，重启即清；失败的查询不缓存。
  static final Map<String, int> _knownPages = {};

  static void clearCache() => _knownPages.clear();

  static String _cacheKey(LocalComic comic, String chapterId) =>
      "${comic.comicType.value}\u0000${comic.id}\u0000$chapterId";

  static Future<ComicGapReport> scan(
    LocalComic comic, {
    GapScanProgress? onProgress,
    bool Function()? isCancelled,
    bool verifyRecorded = false,
  }) async {
    final manager = LocalManager();
    final chapters = comic.chapters;
    final cancelled = isCancelled ?? () => false;

    // 没有章节表的漫画（手工导入、单话）只有一层目录，数根目录就够了。
    if (chapters == null) {
      final pages = await manager.countChapterPages(comic.id, comic.comicType, 1);
      onProgress?.call(1, 1, false);
      return ComicGapReport(
        gaps: pages > 0
            ? const []
            : [
                ChapterGap(
                  id: '',
                  title: comic.title,
                  localPages: 0,
                  expectedPages: 0,
                ),
              ],
        total: 1,
        unverified: 0,
        cancelled: false,
      );
    }

    final ids = chapters.ids.toList();
    final titles = chapters.titles.toList();
    final counts = <String, int>{};

    /// 断号的章节：id -> 本该有的页数下限。
    final holes = <String, int>{};

    // 第一遍：只读盘。
    for (var i = 0; i < ids.length; i++) {
      if (cancelled()) {
        return ComicGapReport(
          gaps: const [],
          total: ids.length,
          unverified: 0,
          cancelled: true,
        );
      }
      final scan = await manager.countChapterPagesIn(
        comic.baseDir,
        ids[i],
        chapters.allChapters[ids[i]],
      );
      counts[ids[i]] = scan.pages;
      if (hasPageHole(
        pages: scan.pages,
        slots: scan.slots,
        first: scan.first,
      )) {
        holes[ids[i]] = scan.slots;
      }
      onProgress?.call(i + 1, ids.length, false);
    }

    // 第二遍的候选：磁盘上有图、没断号，而且记录没替它作证。
    final loaded = comic.downloadedChapters.toSet();
    final suspects = <int>[
      for (var i = 0; i < ids.length; i++)
        if ((counts[ids[i]] ?? 0) > 0 &&
            !holes.containsKey(ids[i]) &&
            (verifyRecorded || !loaded.contains(ids[i])))
          i,
    ];
    var skipped = 0;
    if (!verifyRecorded) {
      for (var i = 0; i < ids.length; i++) {
        if ((counts[ids[i]] ?? 0) > 0 &&
            !holes.containsKey(ids[i]) &&
            loaded.contains(ids[i])) {
          skipped++;
        }
      }
    }

    final short = <int, int>{}; // 章节下标 -> 源站页数
    final source = comic.comicType.comicSource;
    var unverified = 0;
    var didCancel = false;
    var aborted = false;
    var checked = 0;
    var failures = 0;

    if (source?.loadComicPages == null) {
      // 没有源可问：这些都算「没核对」，不能算「不缺」。
      unverified += suspects.length;
    } else {
      for (var start = 0; start < suspects.length; start += verifyConcurrency) {
        if (cancelled()) {
          didCancel = true;
          break;
        }
        final end = start + verifyConcurrency < suspects.length
            ? start + verifyConcurrency
            : suspects.length;
        final batch = suspects.sublist(start, end);
        final results = await Future.wait(batch.map((index) async {
          final chapterId = ids[index];
          final key = _cacheKey(comic, chapterId);
          final known = _knownPages[key];
          if (known != null) {
            return MapEntry<int, int?>(index, known);
          }
          try {
            final res = await source!.loadComicPages!(comic.id, chapterId);
            if (res.error) {
              return MapEntry<int, int?>(index, null);
            }
            _knownPages[key] = res.data.length;
            return MapEntry<int, int?>(index, res.data.length);
          } catch (e) {
            Log.info("GapScan", "Failed to check $chapterId: $e");
            return MapEntry<int, int?>(index, null);
          }
        }));
        checked += batch.length;
        var batchSucceeded = false;
        for (final entry in results) {
          if (entry.value == null) {
            // 问不到就当「没核对」，绝不能当成「不缺」——那样用户会以为
            // 这本书是完整的，而实际上可能正缺着页。
            unverified++;
            failures++;
            continue;
          }
          batchSucceeded = true;
          if ((counts[ids[entry.key]] ?? 0) < entry.value!) {
            short[entry.key] = entry.value!;
          }
        }
        if (batchSucceeded) {
          failures = 0;
        }
        onProgress?.call(checked, suspects.length, true);
        if (failures >= maxConsecutiveFailures) {
          aborted = true;
          break;
        }
      }
    }

    if (didCancel || aborted) {
      // 取消/中止时没轮到的章节一样「没核对」：不报出来的话，用户会以为剩下
      // 的都验过了。
      unverified += suspects.length - checked;
    }

    final gaps = classifyGaps(
      ids: ids,
      titles: titles,
      localPages: counts,
      expectedPages: {for (final e in short.entries) e.key: e.value},
      slots: holes,
    );

    return ComicGapReport(
      gaps: gaps,
      total: ids.length,
      unverified: unverified,
      cancelled: didCancel,
      skipped: skipped,
    );
  }

  /// 页码从 0 起、最大页码 + 1 却比页数多 → 中间缺页。
  ///
  /// [first] 大于 0 时不下结论：手工导入的图、老版本按 1 起编号的目录都长
  /// 这样，一口咬定「每话都缺第一页」比漏报更糟。
  static bool hasPageHole({
    required int pages,
    required int slots,
    required int first,
  }) => first == 0 && slots > pages;

  /// 把「每话盘上几页」「每话源站几页」「哪几话页码断了」合成缺口清单。
  ///
  /// 抽成纯函数是为了能测：这里一旦判错，用户要么漏补缺页、要么被拉去重下
  /// 一整本已经好好的书。
  ///
  /// - [localPages] 里没有、或者是 0 的章节一律算 [ChapterGapKind.missing]；
  /// - [expectedPages] 只放「核对出来确实更少」的章节（下标 -> 源站页数），
  ///   没核对上的不要放进来——不能把「不知道」当成「不缺」；
  /// - [slots] 只放「页码从 0 起、中间却断了」的章节（章节 id -> 页数下限），
  ///   这些不必问源站也算缺口。
  static List<ChapterGap> classifyGaps({
    required List<String> ids,
    required List<String> titles,
    required Map<String, int> localPages,
    required Map<int, int> expectedPages,
    Map<String, int> slots = const {},
  }) {
    final gaps = <ChapterGap>[];
    for (var i = 0; i < ids.length; i++) {
      final local = localPages[ids[i]] ?? 0;
      final title = i < titles.length ? titles[i] : ids[i];
      if (local <= 0) {
        gaps.add(
          ChapterGap(
            id: ids[i],
            title: title,
            localPages: 0,
            expectedPages: 0,
          ),
        );
        continue;
      }
      final expected = expectedPages[i];
      if (expected != null) {
        if (local < expected) {
          gaps.add(
            ChapterGap(
              id: ids[i],
              title: title,
              localPages: local,
              expectedPages: expected,
            ),
          );
        }
        continue;
      }
      // 没问源站，但盘上页码断了：确定缺页，只是不知道总数。
      if ((slots[ids[i]] ?? 0) > local) {
        gaps.add(
          ChapterGap(
            id: ids[i],
            title: title,
            localPages: local,
            expectedPages: 0,
            holes: true,
          ),
        );
      }
    }
    return gaps;
  }
}
