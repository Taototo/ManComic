import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

/// 云端库搜索页使用的漫画列表最小实现。
///
/// ManComi 没有 features/comic_widgets，这里提供一个可用的分页列表：
/// 保留原版 [ComicList]/[ComicListState] 的构造与 [ComicListState.reload]
/// 契约，内部用 FutureBuilder 加载当前页并展示漫画标题。
typedef _LoadPage = Future<Res<List<Comic>>> Function(int page);

class ComicList extends StatefulWidget {
  const ComicList({
    super.key,
    this.loadPage,
    this.leadingSliver,
    this.emptySliver,
    this.preserveScrollPosition = false,
  });

  final _LoadPage? loadPage;
  final Widget? leadingSliver;
  final Widget? emptySliver;
  final bool preserveScrollPosition;

  @override
  ComicListState createState() => ComicListState();
}

class ComicListState extends State<ComicList> {
  int _generation = 0;

  Future<void> reload({bool reset = false, bool queueIfLoading = false}) async {
    if (!mounted) return;
    setState(() => _generation++);
  }

  @override
  Widget build(BuildContext context) {
    final loader = widget.loadPage;
    return CustomScrollView(
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        if (loader == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No comics')),
          )
        else
          SliverFillRemaining(
            hasScrollBody: false,
            child: FutureBuilder<Res<List<Comic>>>(
              key: ValueKey(_generation),
              future: loader(1),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError || snapshot.data?.error == true) {
                  return Center(
                    child: Text(snapshot.data?.errorMessage ?? '${snapshot.error}'),
                  );
                }
                final comics = snapshot.data?.dataOrNull ?? const <Comic>[];
                if (comics.isEmpty && widget.emptySliver != null) {
                  return Center(child: widget.emptySliver!);
                }
                return ListView.builder(
                  itemCount: comics.length,
                  itemBuilder: (context, index) =>
                      ListTile(title: Text(comics[index].title)),
                );
              },
            ),
          ),
      ],
    );
  }
}
