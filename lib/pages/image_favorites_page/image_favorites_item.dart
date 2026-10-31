part of 'image_favorites_page.dart';

class _ImageFavoritesItem extends StatefulWidget {
  const _ImageFavoritesItem({
    required this.imageFavoritesComic,
    required this.selectedImageFavorites,
    required this.addSelected,
    required this.multiSelectMode,
    required this.finalImageFavoritesComicList,
  });

  final ImageFavoritesComic imageFavoritesComic;
  final Function(ImageFavorite) addSelected;
  final Map<ImageFavorite, bool> selectedImageFavorites;
  final List<ImageFavoritesComic> finalImageFavoritesComicList;
  final bool multiSelectMode;

  @override
  State<_ImageFavoritesItem> createState() => _ImageFavoritesItemState();
}

class _ImageFavoritesItemState extends State<_ImageFavoritesItem> {
  void goComicInfo(ImageFavoritesComic comic) {
    App.mainNavigatorKey?.currentContext?.to(() => ComicPage(
          id: comic.id,
          sourceKey: comic.sourceKey,
        ));
  }

  void goReaderPage(ImageFavoritesComic comic, int ep, int page) {
    App.rootContext.to(
      () => ReaderWithLoading(
        id: comic.id,
        sourceKey: comic.sourceKey,
        initialEp: ep,
        initialPage: page,
      ),
    );
  }

  void goPhotoView(ImageFavorite imageFavorite) {
    Navigator.of(App.rootContext).push(MaterialPageRoute(
        builder: (context) => ImageFavoritesPhotoView(
              comic: widget.imageFavoritesComic,
              imageFavorite: imageFavorite,
            )));
  }

  void copyTitle() {
    Clipboard.setData(ClipboardData(text: widget.imageFavoritesComic.title));
    App.rootContext.showMessage(message: 'Copy the title successfully'.tl);
  }

  void onLongPress() {
    var renderBox = context.findRenderObject() as RenderBox;
    var size = renderBox.size;
    var location = renderBox.localToGlobal(
      Offset((size.width - 242) / 2, size.height / 2),
    );
    showMenu(location, context);
  }

  void onSecondaryTap(TapDownDetails details) {
    showMenu(details.globalPosition, context);
  }

  void showMenu(Offset location, BuildContext context) {
    showMenuX(
      App.rootContext,
      location,
      [
        MenuEntry(
          icon: Icons.chrome_reader_mode_outlined,
          text: 'Details'.tl,
          onClick: () {
            goComicInfo(widget.imageFavoritesComic);
          },
        ),
        MenuEntry(
          icon: Icons.copy,
          text: 'Copy Title'.tl,
          onClick: () {
            copyTitle();
          },
        ),
        MenuEntry(
          icon: Icons.select_all,
          text: 'Select All'.tl,
          onClick: () {
            for (var ele in widget.imageFavoritesComic.images) {
              widget.addSelected(ele);
            }
          },
        ),
        MenuEntry(
          icon: Icons.read_more,
          text: 'Photo View'.tl,
          onClick: () {
            goPhotoView(widget.imageFavoritesComic.images.first);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImageFavoritesCard(
      comic: widget.imageFavoritesComic,
      onTap: () {
        if (widget.multiSelectMode) {
          for (var ele in widget.imageFavoritesComic.images) {
            widget.addSelected(ele);
          }
        } else {
          // 单击跳转漫画详情
          goComicInfo(widget.imageFavoritesComic);
        }
      },
      onLongPress: onLongPress,
      onSecondaryTapDown: onSecondaryTap,
      selectedImages: widget.selectedImageFavorites,
      onThumbTap: (image) {
        // 单击去阅读页面, 跳转到当前点击的page
        if (widget.multiSelectMode) {
          widget.addSelected(image);
        } else {
          goReaderPage(widget.imageFavoritesComic, image.ep, image.page);
        }
      },
      onThumbLongPress: goPhotoView,
    );
  }
}
