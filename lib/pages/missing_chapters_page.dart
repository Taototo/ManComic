import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_gaps.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/translations.dart';

/// 「缺失章节检测」的结果面板。
///
/// 打开就开始扫：先数盘上的页（不联网，一页没有或页码断号当场就能判定），
/// 再只把「看着连续、但记录没替它作证」的章节拿去和源站比页数。扫完列出缺
/// 的章节，一键把它们的任务塞进下载队列——已经落盘的那几页不会重下。
///
/// 为什么不能只信 `downloadedChapters`：1.4.57 之前会把缺页的半章也记成已
/// 下载；而下载时某一页连续失败会整章跳过，留下的半截既不在记录里，也和
/// 「一页没下」长得不一样。
///
/// 为什么要跳过记录里的章节：一话一个请求，一本八百话的书就是八百个请求，
/// 用户等到的是「检测怎么这么慢」。想全查的有「全部再核对一遍」。
class MissingChaptersPage extends StatefulWidget {
  const MissingChaptersPage({super.key, required this.comic});

  final LocalComic comic;

  static void show(BuildContext context, LocalComic comic) {
    showSideBar(context, MissingChaptersPage(comic: comic));
  }

  @override
  State<MissingChaptersPage> createState() => _MissingChaptersPageState();
}

class _MissingChaptersPageState extends State<MissingChaptersPage> {
  ComicGapReport? _report;

  int _done = 0;

  int _total = 0;

  /// 当前是「数盘」还是「问源站」：两遍的分母不一样，文案得分开。
  bool _verifying = false;

  bool _scanning = true;

  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan({bool deep = false}) async {
    setState(() {
      _scanning = true;
      _report = null;
      _cancelled = false;
      _verifying = false;
      _done = 0;
      _total = 0;
    });
    var lastDone = 0;
    final report = await ComicGapScanner.scan(
      widget.comic,
      verifyRecorded: deep,
      onProgress: (done, total, verifying) {
        if (!mounted) {
          return;
        }
        // 几百话逐话 setState 会把主线程刷成幻灯片；整遍最多刷 60 次，
        // 阶段切换和收尾那两个点一定刷。
        final stride = total < 60 ? 1 : total ~/ 60;
        final edge = done >= total || verifying != _verifying || total != _total;
        if (!edge && done - lastDone < stride) {
          return;
        }
        lastDone = done;
        setState(() {
          _done = done;
          _total = total;
          _verifying = verifying;
        });
      },
      isCancelled: () => _cancelled || !mounted,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _report = report;
      _scanning = false;
    });
  }

  void _download([List<ChapterGap>? only]) {
    final source = widget.comic.comicType.comicSource;
    if (source == null) {
      return;
    }
    final targets = only ?? _report!.gaps;
    if (targets.isEmpty) {
      return;
    }
    // 同一本已经在队列里的话，addTask 只会把旧任务恢复起来，不会按这次的
    // 章节重建——用户会看到「下载已开始」却什么都没变。说清楚再退。
    if (LocalManager().findTask(widget.comic.id, widget.comic.comicType) !=
        null) {
      App.rootContext.showMessage(
        message: "Already in the download queue".tl,
      );
      context.pop();
      return;
    }
    LocalManager().addTask(
      ImagesDownloadTask(
        source: source,
        comicId: widget.comic.id,
        comicTitle: widget.comic.title,
        // 无章节表的漫画（单话）只有一个「空 id」章节，传空 id 会被当成
        // 「没指定章节」，所以这种书直接整本重下。
        chapters: widget.comic.chapters == null
            ? null
            : targets.map((e) => e.id).toList(),
      ),
    );
    App.rootContext.showMessage(message: "Download started".tl);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Missing chapters".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _buildBody(context)),
          if (!_scanning && (_report?.gaps.isNotEmpty ?? false))
            _buildFooter(context, _report!),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_scanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _total > 0
                  ? (_verifying
                        ? "Checking @a / @b".tlParams({"a": _done, "b": _total})
                        : "Scanning @a / @b".tlParams({
                            "a": _done,
                            "b": _total,
                          }))
                  : "Scanning...".tl,
            ),
            if (_total > 0) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 180,
                child: LinearProgressIndicator(
                  value: (_done / _total).clamp(0.0, 1.0),
                  minHeight: 3,
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                setState(() {
                  _cancelled = true;
                });
              },
              child: Text("Cancel".tl),
            ),
          ],
        ),
      );
    }
    final report = _report!;
    if (report.gaps.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 56,
                color: context.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                report.cancelled
                    ? "Scan cancelled".tl
                    : "No missing chapters".tl,
              ),
              ..._buildScopeNotice(report, center: true),
              const SizedBox(height: 16),
              TextButton(onPressed: _scan, child: Text("Rescan".tl)),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: report.gaps.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return _buildSummary(context, report);
        }
        return _buildRow(context, report.gaps[i - 1]);
      },
    );
  }

  /// 这次扫的「范围」：哪些章没核对、哪些章是信了记录才没问源站。
  ///
  /// 两者必须分开说。混成一句「没核对的章」，用户就分不清是源站挂了还是
  /// 本来就没查；而完全不提，用户会以为整本八百话都验过了。
  List<Widget> _buildScopeNotice(ComicGapReport report, {bool center = false}) {
    final style = ts.s12.withColor(
      Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return [
      if (report.unverified > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            "@a chapters could not be checked".tlParams({
              "a": report.unverified,
            }),
            style: style,
            textAlign: center ? TextAlign.center : TextAlign.start,
          ).paddingHorizontal(center ? 32 : 0),
        ),
      if (report.skipped > 0) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            "@a chapters were confirmed when downloaded".tlParams({
              "a": report.skipped,
            }),
            style: style,
            textAlign: center ? TextAlign.center : TextAlign.start,
          ).paddingHorizontal(center ? 32 : 0),
        ),
        TextButton(
          onPressed: () => _scan(deep: true),
          child: Text("Check them again".tl),
        ),
      ],
    ];
  }

  Widget _buildSummary(BuildContext context, ComicGapReport report) {
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "@a of @b chapters need attention".tlParams({
              "a": report.gaps.length,
              "b": report.total,
            }),
            style: ts.s16,
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (report.missingCount > 0)
                "@a not downloaded".tlParams({"a": report.missingCount}),
              if (report.incompleteCount > 0)
                "@a incomplete".tlParams({"a": report.incompleteCount}),
            ].join(" · "),
            style: ts.s12.withColor(colors.onSurfaceVariant),
          ),
          if (report.cancelled)
            Text(
              "Scan cancelled".tl,
              style: ts.s12.withColor(colors.onSurfaceVariant),
            ),
          ..._buildScopeNotice(report),
          const Divider().paddingVertical(8),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, ChapterGap gap) {
    final colors = context.colorScheme;
    final missing = gap.kind == ChapterGapKind.missing;
    final color = missing ? colors.error : context.useTextColor(Colors.orange);
    final String subtitle;
    if (missing) {
      subtitle = "Not downloaded".tl;
    } else if (gap.expectedPages > 0) {
      subtitle = "@a/@b pages".tlParams({
        "a": gap.localPages,
        "b": gap.expectedPages,
      });
    } else if (gap.holes) {
      subtitle = "@a pages, gaps inside".tlParams({"a": gap.localPages});
    } else {
      subtitle = "@a pages on device".tlParams({"a": gap.localPages});
    }
    return ListTile(
      leading: Icon(
        missing ? Icons.cloud_download_outlined : Icons.incomplete_circle,
        color: color,
      ),
      title: Text(gap.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, style: ts.s12.withColor(color)),
      onTap: () => _download([gap]),
    );
  }

  Widget _buildFooter(BuildContext context, ComicGapReport report) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: context.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _scan,
              child: Text("Rescan".tl),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: () => _download(),
              child: Text(
                "Download @c chapters".tlParams({"c": report.gaps.length}),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
