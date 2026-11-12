import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_gaps.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/translations.dart';

/// 「缺失章节检测」的结果面板。
///
/// 打开就开始扫：先数盘上的页（不联网），再把有图的章节拿去和源站比页数。
/// 扫完列出缺的章节，一键把它们的任务塞进下载队列——已经落盘的那几页不会
/// 重下，只补缺的。
///
/// 为什么不能只信 `downloadedChapters`：那个记录是「整本下完时按页数核对过」
/// 的产物，1.4.57 之前却会把缺页的半章也记成已下载；而下载时某一页连续失败
/// 会整章跳过，留下的半截既不在记录里，也和「一页没下」长得不一样——只有
/// 数一遍页数才分得清。
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

  bool _scanning = true;

  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _report = null;
      _cancelled = false;
      _done = 0;
      _total = 0;
    });
    final report = await ComicGapScanner.scan(
      widget.comic,
      onProgress: (done, total) {
        if (!mounted) {
          return;
        }
        setState(() {
          _done = done;
          _total = total;
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
                  ? "Checking @a / @b".tlParams({"a": _done, "b": _total})
                  : "Scanning...".tl,
            ),
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
            if (report.unverified > 0) ...[
              const SizedBox(height: 8),
              Text(
                "@a chapters could not be checked".tlParams({
                  "a": report.unverified,
                }),
                style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ).paddingHorizontal(32),
            ],
            const SizedBox(height: 16),
            TextButton(onPressed: _scan, child: Text("Rescan".tl)),
          ],
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
          if (report.unverified > 0)
            Text(
              "@a chapters could not be checked".tlParams({
                "a": report.unverified,
              }),
              style: ts.s12.withColor(colors.onSurfaceVariant),
            ),
          if (report.cancelled)
            Text(
              "Scan cancelled".tl,
              style: ts.s12.withColor(colors.onSurfaceVariant),
            ),
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
