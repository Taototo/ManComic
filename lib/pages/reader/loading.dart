part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    final type = ComicType.fromKey(widget.sourceKey);
    var history = HistoryManager().find(widget.id, type);
    // 下载到本地的书直接从磁盘读：章节表用下载那一刻的快照，图由 images.dart
    // 按章走本地目录（缺页再回落到网络）。这样「继续阅读 / 最近阅读」不用先
    // 请求一次源站拿目录，断网也进得去——而这正是用户点「最近阅读」的期望。
    var localComic = _findLocalComic(type);
    if (localComic != null) {
      return Res(
        ReaderProps(
          type: type,
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history:
              history ??
              History.fromModel(model: localComic, ep: 0, page: 0),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    }
    var comicSource = ComicSource.find(widget.sourceKey);
    if (comicSource == null) {
      return Res.error("comic not found");
    }
    var comic = await comicSource.loadComicInfo!(widget.id);
    if (comic.error) {
      return Res.fromErrorRes(comic);
    }
    return Res(
      ReaderProps(
        type: type,
        cid: widget.id,
        name: comic.data.title,
        chapters: comic.data.chapters,
        history:
            history ??
            History.fromModel(model: comic.data, ep: 0, page: 0),
        author: comic.data.findAuthor() ?? "",
        tags: comic.data.plainTags,
      ),
    );
  }

  /// 本地库里有没有这本（`local` 类型的老记录也走这条路）。
  /// 库还没初始化好时按「没有」处理，别让阅读页因为查库失败而打不开。
  LocalComic? _findLocalComic(ComicType type) {
    try {
      return LocalManager().find(widget.id, type);
    } catch (e, s) {
      Log.error("Reader", "Failed to look up local comic: $e\n$s");
      return null;
    }
  }
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}
