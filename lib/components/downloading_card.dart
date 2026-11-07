import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// 下载中的漫画卡片：竖版缩略图 + 压在中间的圆形进度。
///
/// 显示在本地页顶部，也在下载管理页里复用同一套视觉。
class DownloadingCard extends StatefulWidget {
  const DownloadingCard({
    super.key,
    required this.task,
    this.width = 84,
    this.coverHeight = 112,
    this.ringSize = 44,
    this.showTitle = true,
    this.enableTap = true,
  });

  final DownloadTask task;

  final double width;

  final double coverHeight;

  final double ringSize;

  /// 下载管理页自己排版标题，横条这里才需要
  final bool showTitle;

  /// 关掉后点封面不跳转：下载管理页里点一下就跳阅读器太容易误触。
  final bool enableTap;

  @override
  State<DownloadingCard> createState() => _DownloadingCardState();
}

class _DownloadingCardState extends State<DownloadingCard> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DownloadingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enableTap ? () => _open(context) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: widget.width,
                height: widget.coverHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: context.colorScheme.secondaryContainer,
                      child: task.cover == null
                          ? const SizedBox()
                          : Image(
                              image: CachedImageProvider(task.cover!),
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, e, s) => const SizedBox(),
                            ),
                    ),
                    // 遮罩强度分档：跑着的时候压暗一点让圆环更清楚，暂停时
                    // 只轻轻压一层。圆环一直显示——百分比是这个卡片上最有用
                    // 的信息，不该因为暂停就消失。
                    ColoredBox(
                      color: Colors.black.withValues(
                        alpha: !task.isPaused || task.isError ? 0.32 : 0.12,
                      ),
                    ),
                    Center(
                      child: SizedBox(
                        width: widget.ringSize,
                        height: widget.ringSize,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: task.progress <= 0 ? null : task.progress,
                              strokeWidth: 3,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation(
                                Colors.white,
                              ),
                            ),
                            Text(
                              task.progress <= 0
                                  ? "--"
                                  : "${(task.progress * 100).round()}",
                              style: const TextStyle(
                                fontSize: 11,
                                height: 1,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (task.isError)
                      const Positioned(
                        right: 3,
                        top: 3,
                        child: Icon(
                          Icons.error_outline,
                          size: 15,
                          color: Colors.redAccent,
                        ),
                      )
                    else if (task.isPaused)
                      Positioned(
                        right: 3,
                        top: 3,
                        child: Icon(
                          task.userPaused
                              ? Icons.pause_circle_outline
                              : Icons.schedule,
                          size: 15,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (widget.showTitle) ...[
              const SizedBox(height: 4),
              Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s12,
              ),
              const SizedBox(height: 1),
              Text(
                statusLine(task),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: task.isError
                      ? context.colorScheme.error
                      : context.colorScheme.onSurface.toOpacity(0.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 点缩略图直接进阅读器读已经下好的部分。
  ///
  /// 一页都还没落盘时不去猜，直接告诉用户还没东西可看——否则会跳进一个
  /// 空白页，比什么都不做更让人困惑。
  Future<void> _open(BuildContext context) async {
    final t = task;
    if (t is! ImagesDownloadTask || t.comic == null) {
      showPopUpWidget(context, const DownloadingPage());
      return;
    }
    final details = t.comic!;
    final chapters = details.chapters;
    final count = chapters?.length ?? 1;
    var firstChapter = 0;
    for (var i = 1; i <= count; i++) {
      if (await LocalManager().hasLocalPages(t.id, t.comicType, i)) {
        firstChapter = i;
        break;
      }
    }
    if (!context.mounted) {
      return;
    }
    if (firstChapter == 0) {
      context.showMessage(message: "No downloaded pages yet".tl);
      return;
    }
    final history = HistoryManager().find(t.id, t.comicType) ??
        History.fromMap({
          "type": t.comicType.value,
          "time": DateTime.now().millisecondsSinceEpoch,
          "title": t.title,
          "subtitle": details.subTitle ?? "",
          "cover": t.cover ?? "",
          "ep": firstChapter,
          "page": 1,
          "id": t.id,
          "readEpisode": <String>[],
        });
    context.to(() => Reader(
          type: t.comicType,
          cid: t.id,
          name: t.title,
          chapters: chapters,
          // 只给全书序号，不给 initialChapterGroup：Reader 会拿 group 再往前
          // 累加一次偏移，两个一起传会把起点推到后面好几话。
          initialChapter: firstChapter,
          initialPage: history.ep == firstChapter ? history.page : 1,
          history: history,
          author: details.subTitle ?? "",
          tags: details.tags.entries
              .expand((e) => e.value.map((v) => "${e.key}:$v"))
              .toList(),
        ));
  }
}

/// 卡片底部那行小字：速度 / 状态。
String statusLine(DownloadTask task) {
  if (task.isError) {
    return "Failed".tl;
  }
  if (!task.isPaused) {
    if (task.speed > 0) {
      return "${bytesToReadableString(task.speed)}/s";
    }
    return task.message;
  }
  return task.userPaused ? "Paused".tl : "Queued".tl;
}
