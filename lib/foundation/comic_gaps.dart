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
  });

  /// 章节 id。无章节表的漫画（单话导入/单话下载）是空串。
  final String id;

  final String title;

  /// 磁盘上的页数。
  final int localPages;

  /// 源站的页数。`0` 表示没能核对（断网、源站抽风、没有源）。
  final int expectedPages;

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
  });

  /// 需要补的章节，保持目录顺序（第几话就排第几）。
  final List<ChapterGap> gaps;

  /// 这本书目录里一共几话。
  final int total;

  /// 本地有图、但没能向源站核对页数的章数。这里面可能还藏着缺页的。
  final int unverified;

  /// 用户中途取消了：结果只覆盖扫到的部分。
  final bool cancelled;

  bool get isEmpty => gaps.isEmpty;

  int get missingCount =>
      gaps.where((e) => e.kind == ChapterGapKind.missing).length;

  int get incompleteCount => gaps.length - missingCount;
}

/// 找出这本书在磁盘上缺了哪些章。
///
/// 两步走：先按目录数页（不联网，很快），再把**本地有图**的章节拿去和源站的
/// 地址表比页数。之所以要联网比，是因为「记录里算下完了」不足以证明文件齐：
/// 1.4.57 之前的版本会把缺了页的半章也记成已下载，事后看记录一切正常，实际
/// 却少了十几页。而不在记录里的章节只能靠页数才知道是「下了一半」还是
/// 「一页都没下」。
///
/// 只问有图的章节：一张图都没有的章必然是缺的，不必浪费一次请求。
class ComicGapScanner {
  /// 核对页数时同时问几章。和下载引擎的 `_imageListConcurrency` 同量级，
  /// 再高容易被源站当场限流。
  static const verifyConcurrency = 4;

  static Future<ComicGapReport> scan(
    LocalComic comic, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final manager = LocalManager();
    final chapters = comic.chapters;
    final cancelled = isCancelled ?? () => false;

    // 没有章节表的漫画（手工导入、单话）只有一层目录，数根目录就够了。
    if (chapters == null) {
      final pages = await manager.countChapterPages(comic.id, comic.comicType, 1);
      onProgress?.call(1, 1);
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

    // 第一遍：数页。这一步只读盘，断网也能跑完。
    final totalSteps = ids.length * 2;
    var steps = 0;
    for (var i = 0; i < ids.length; i++) {
      if (cancelled()) {
        return ComicGapReport(
          gaps: const [],
          total: ids.length,
          unverified: 0,
          cancelled: true,
        );
      }
      counts[ids[i]] = await manager.countChapterPages(
        comic.id,
        comic.comicType,
        ids[i],
      );
      onProgress?.call(++steps, totalSteps);
    }

    // 第二遍：向源站核对有图的那些章节。
    final suspects = [
      for (var i = 0; i < ids.length; i++)
        if ((counts[ids[i]] ?? 0) > 0) i,
    ];
    final short = <int, int>{}; // 章节下标 -> 源站页数
    final source = comic.comicType.comicSource;
    var unverified = 0;
    var didCancel = false;
    var checked = 0;

    if (source?.loadComicPages != null) {
      for (var start = 0; start < suspects.length; start += verifyConcurrency) {
        if (cancelled()) {
          didCancel = true;
          break;
        }
        final batch = suspects.skip(start).take(verifyConcurrency).toList();
        final results = await Future.wait(batch.map((index) async {
          try {
            final res = await source!.loadComicPages!(comic.id, ids[index]);
            return MapEntry(index, res);
          } catch (e) {
            Log.info("GapScan", "Failed to check ${ids[index]}: $e");
            return null;
          }
        }));
        checked += batch.length;
        for (final entry in results) {
          if (entry == null || entry.value.error) {
            // 问不到就当「没核对」，绝不能当成「不缺」——那样用户会以为
            // 这本书是完整的，而实际上可能正缺着页。
            unverified++;
            continue;
          }
          final expected = entry.value.data.length;
          final local = counts[ids[entry.key]] ?? 0;
          if (local < expected) {
            short[entry.key] = expected;
          }
        }
        steps = ids.length + start + batch.length;
        onProgress?.call(steps.clamp(0, totalSteps), totalSteps);
      }
    }

    if (didCancel) {
      // 取消时没轮到的章节一样「没核对」：不报出来的话，用户会以为剩下的
      // 都验过了。
      unverified += suspects.length - checked;
    }

    final gaps = classifyGaps(
      ids: ids,
      titles: titles,
      localPages: counts,
      expectedPages: {for (final e in short.entries) e.key: e.value},
    );

    return ComicGapReport(
      gaps: gaps,
      total: ids.length,
      unverified: unverified,
      cancelled: didCancel,
    );
  }

  /// 把「每话盘上几页」和「每话源站几页」合成缺口清单。
  ///
  /// 抽成纯函数是为了能测：这里一旦判错，用户要么漏补缺页、要么被拉去重下
  /// 一整本已经好好的书。
  ///
  /// - [localPages] 里没有、或者是 0 的章节一律算 [ChapterGapKind.missing]；
  /// - [expectedPages] 只放「核对出来确实更少」的章节（下标 -> 源站页数），
  ///   没核对上的不要放进来——不能把「不知道」当成「不缺」。
  static List<ChapterGap> classifyGaps({
    required List<String> ids,
    required List<String> titles,
    required Map<String, int> localPages,
    required Map<int, int> expectedPages,
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
      if (expected != null && local < expected) {
        gaps.add(
          ChapterGap(
            id: ids[i],
            title: title,
            localPages: local,
            expectedPages: expected,
          ),
        );
      }
    }
    return gaps;
  }
}
