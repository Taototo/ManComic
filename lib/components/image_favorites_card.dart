import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

/// 图片收藏条目卡。
///
/// 图片收藏页与首页共用这一份实现，保证两处样式完全一致：
/// 标题 + 收藏数/总页数角标、横向缩略图条、底部日期|源与标签行。
class ImageFavoritesCard extends StatelessWidget {
  const ImageFavoritesCard({
    super.key,
    required this.comic,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.onThumbTap,
    this.onThumbLongPress,
    this.selectedImages,
    this.reserveTitleLines = 0,
    this.enableHero = true,
    this.backgroundColor,
    this.margin = const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
  });

  final ImageFavoritesComic comic;

  final VoidCallback? onTap;

  final VoidCallback? onLongPress;

  final void Function(TapDownDetails details)? onSecondaryTapDown;

  final void Function(ImageFavorite image)? onThumbTap;

  final void Function(ImageFavorite image)? onThumbLongPress;

  /// 多选模式下被选中的图片，用于高亮缩略图
  final Map<ImageFavorite, bool>? selectedImages;

  /// 标题预留的行数。首页卡片堆需要每张卡等高，传 2 让单行标题也占两行高度。
  final int reserveTitleLines;

  /// 首页会同时渲染多张卡，Hero tag 可能重复，传 false 关闭
  final bool enableHero;

  /// 卡片底色。默认透明（图片收藏页本身就在纯色列表上）；
  /// 首页卡片堆里前后两张卡完全重叠，必须填成页面底色，
  /// 否则后卡的文字会透过前卡显示出来，两行文字叠在一起看不清。
  final Color? backgroundColor;

  final EdgeInsets margin;

  List<ImageFavorite> get _images => comic.images.toList();

  @override
  Widget build(BuildContext context) {
    final images = _images;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onSecondaryTapDown: onSecondaryTapDown,
          onLongPress: onLongPress,
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildTop(context, images.length),
              SizedBox(
                height: 145,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemBuilder: (context, index) =>
                      _buildItem(context, images[index]),
                  itemCount: images.length,
                ),
              ).paddingHorizontal(8),
              buildBottom(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, ImageFavorite image) {
    final isSelected = selectedImages?[image] ?? false;
    final curPage = image.page;
    final pageText = curPage == firstPage
        ? '@a Cover'.tlParams({"a": image.epName})
        : curPage.toString();

    Widget thumb = Container(
      height: 128,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.secondaryContainer,
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedImage(
        image: ImageFavoritesProvider(image),
        width: 96,
        height: 128,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        cacheWidth: 300,
      ),
    );

    if (enableHero) {
      thumb = Hero(
        tag: "${image.sourceKey}${image.ep}${image.page}",
        child: thumb,
      );
    }

    return InkWell(
      onTap: onThumbTap == null ? null : () => onThumbTap!(image),
      onLongPress: onThumbLongPress == null
          ? null
          : () => onThumbLongPress!(image),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 98,
        height: 145,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            thumb,
            Text(
              pageText,
              style: ts.s10,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ).paddingHorizontal(4);
  }

  Widget buildTop(BuildContext context, int imageCount) {
    Widget title = Text(
      comic.title,
      style: const TextStyle(
        fontWeight: FontWeight.w500,
        fontSize: 16.0,
        height: 1.2,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      softWrap: true,
    );

    if (reserveTitleLines > 0) {
      title = SizedBox(
        height: 16.0 * 1.2 * reserveTitleLines,
        child: Align(alignment: Alignment.topLeft, child: title),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: title),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text("$imageCount/${comic.maxPageFromEp}", style: ts.s12),
        ),
      ],
    ).paddingHorizontal(16).paddingVertical(8);
  }

  Widget buildBottom(BuildContext context) {
    final enableTranslate = App.locale.languageCode == 'zh';
    final time = DateFormat('yyyy-MM-dd').format(comic.time);
    final tags = <String>[];
    for (var tag in comic.tags) {
      var text = enableTranslate ? tag.translateTagsToCN : tag;
      if (text.contains(':')) {
        text = text.split(':').last;
      }
      tags.add(text);
      if (tags.length == 5) {
        break;
      }
    }
    final comicSource = ComicSource.find(comic.sourceKey);
    return Row(
      children: [
        Text(
          "$time | ${comicSource?.name ?? "Unknown".tl}",
          textAlign: TextAlign.left,
          style: const TextStyle(fontSize: 12.0),
        ).paddingRight(8),
        if (tags.isNotEmpty)
          Expanded(
            child: Text(
              tags.join(" "),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12.0),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ).paddingHorizontal(8).paddingBottom(8);
  }
}
