part of 'reader.dart';

class _ReaderScaffold extends StatefulWidget {
  const _ReaderScaffold({required this.child});

  final Widget child;

  @override
  State<_ReaderScaffold> createState() => _ReaderScaffoldState();
}

class _ReaderScaffoldState extends State<_ReaderScaffold> {
  bool _isOpen = false;

  static const kTopBarHeight = 56.0;

  /// 内容是否正在滚动，用于让底部页码/时间等浮动信息临时淡出，避免遮挡画面
  bool _contentScrolling = false;

  void setContentScrolling(bool value) {
    if (_contentScrolling == value || !mounted) {
      return;
    }
    setState(() {
      _contentScrolling = value;
    });
  }

  bool get isOpen => _isOpen;

  bool get isReversed =>
      context.reader.mode == ReaderMode.galleryRightToLeft ||
      context.reader.mode == ReaderMode.continuousRightToLeft;

  int showFloatingButtonValue = 0;

  var lastValue = 0;

  _ReaderGestureDetectorState? _gestureDetectorState;

  bool _hudOpen = false;

  bool _locked = false;

  /// 护眼暖色是否生效（结合强度设置与夜间时段）
  bool _warmActive = false;

  Timer? _warmTimer;

  /// 夜间自动开启的时间范围
  static const int _warmNightStart = 20;

  static const int _warmNightEnd = 7;

  bool get isHudOpen => _hudOpen;

  bool get isLocked => _locked;

  void openHud() {
    if (_locked || _hudOpen) {
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _hudOpen = true;
    });
  }

  void closeHud() {
    if (!_hudOpen) {
      return;
    }
    setState(() {
      _hudOpen = false;
    });
  }

  void lock() {
    if (_locked) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _locked = true;
    });
    context.showMessage(message: "Long press to unlock".tl);
  }

  void unlock() {
    if (!_locked) return;
    HapticFeedback.lightImpact();
    setState(() {
      _locked = false;
    });
  }

  void setFloatingButton(int value) {
    lastValue = showFloatingButtonValue;
    if (value == 0) {
      if (showFloatingButtonValue != 0) {
        showFloatingButtonValue = 0;
        update();
      }
    }
    if (value == 1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = 1;
      update();
    } else if (value == -1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = -1;
      update();
    }
  }

  _DragListener? _imageFavoriteDragListener;

  void addDragListener() async {
    if (!mounted) return;
    var readerMode = context.reader.mode;

    // 横向阅读的时候, 如果纵向滑就触发收藏, 纵向阅读的时候, 如果横向滑动就触发收藏
    if (appdata.settings['quickCollectImage'] == 'Swipe') {
      if (_imageFavoriteDragListener == null) {
        double distance = 0;
        _imageFavoriteDragListener = _DragListener(
          onMove: (offset) {
            switch (readerMode) {
              case ReaderMode.continuousTopToBottom:
              case ReaderMode.galleryTopToBottom:
                distance += offset.dx;
              case ReaderMode.continuousLeftToRight:
              case ReaderMode.galleryLeftToRight:
              case ReaderMode.galleryRightToLeft:
              case ReaderMode.continuousRightToLeft:
                distance += offset.dy;
            }
          },
          onEnd: () {
            if (distance.abs() > 150) {
              addImageFavorite();
            }
            distance = 0;
          },
        );
      }
      _gestureDetectorState!.addDragListener(_imageFavoriteDragListener!);
    } else if (_imageFavoriteDragListener != null) {
      _gestureDetectorState!.removeDragListener(_imageFavoriteDragListener!);
    }
  }

  @override
  void initState() {
    sliderFocus.canRequestFocus = false;
    sliderFocus.addListener(() {
      if (sliderFocus.hasFocus) {
        sliderFocus.nextFocus();
      }
    });
    if (rotation != null) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.initState();
    refreshWarmFilter();
    _warmTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      refreshWarmFilter();
    });
    Future.delayed(const Duration(milliseconds: 200), addDragListener);
  }

  @override
  void dispose() {
    _warmTimer?.cancel();
    sliderFocus.dispose();
    super.dispose();
  }

  double get warmStrength =>
      ((appdata.settings['readerWarmFilter'] as num?)?.toDouble() ?? 0)
          .clamp(0, 100) /
      100;

  /// 根据设置与当前时间刷新暖色开关
  void refreshWarmFilter() {
    final strength = warmStrength;
    final auto = appdata.settings['readerWarmFilterAuto'] == true;
    final hour = DateTime.now().hour;
    final isNight = hour >= _warmNightStart || hour < _warmNightEnd;
    final active = strength > 0 && (!auto || isNight);
    if (active != _warmActive) {
      if (mounted) {
        setState(() {
          _warmActive = active;
        });
      } else {
        _warmActive = active;
      }
    }
  }

  Widget buildWarmFilter(Widget child) {
    if (!_warmActive) {
      return child;
    }
    final s = warmStrength.clamp(0.0, 1.0);
    // 通过压低蓝通道实现暖色，亮度基本不变
    return ColorFiltered(
      colorFilter: ColorFilter.mode(
        Color.fromARGB(
          255,
          255,
          (255 - 46 * s).round(),
          (255 - 118 * s).round(),
        ),
        BlendMode.modulate,
      ),
      child: child,
    );
  }

  void openOrClose() {
    if (!_isOpen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      if (!appdata.settings['showSystemStatusBar']) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
    setState(() {
      _isOpen = !_isOpen;
    });
  }

  bool? rotation;

  void update() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isOnChapterCommentsPage = context.reader.isOnChapterCommentsPage;
    return Stack(
      children: [
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: context.reader.isPageAnimating,
            child: buildWarmFilter(widget.child),
          ),
        ),
        if (!isOnChapterCommentsPage && !_isOpen) buildOverlayInfo(),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          right: 16,
          bottom: showFloatingButtonValue == 0 ? -58 : 36,
          child: buildEpChangeButton(),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !_isOpen,
            child: AnimatedSlide(
              // 用自身高度做位移（而不是写死常量），避免工具栏实际高度
              // 与 kTopBarHeight 不一致时露出一条边挡住内容
              offset: _isOpen ? Offset.zero : const Offset(0, -1),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: buildTop(),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !_isOpen,
            child: AnimatedSlide(
              offset: _isOpen ? Offset.zero : const Offset(0, 1),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: buildBottom(),
            ),
          ),
        ),
        if (_hudOpen) ...[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: closeHud,
              child: Container(
                color: Colors.black.withValues(alpha: 0.28),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 14 + context.padding.bottom,
            child: _ReaderHud(onLock: lock),
          ),
        ],
        if (_locked) ...[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                context.showMessage(message: "Long press to unlock".tl);
              },
              onLongPress: unlock,
              child: Container(color: Colors.transparent),
            ),
          ),
          Positioned(
            top: context.padding.top + 16,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.lock_outline,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "Locked, long press to unlock".tl,
                        style: ts.s10.withColor(Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget buildTop() {
    return GlassSurface(
      blur: GlassConfig.blur,
      child: Container(
        padding: EdgeInsets.only(top: context.padding.top),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              GlassConfig.surface(context),
              GlassConfig.surface(context, 0.38),
            ],
          ),
          border: Border(
            bottom: BorderSide(
              color: context.colorScheme.outlineVariant.withValues(alpha: 0.28),
              width: 0.5,
            ),
          ),
        ),
        child: SizedBox(
          height: kTopBarHeight,
          child: Padding(
            padding: EdgeInsets.only(
              left: context.padding.left,
              right: context.padding.right,
            ),
            child: Row(
              children: [
                const SizedBox(width: 4),
                // 现代化返回按钮
                Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 20,
                      color: context.colorScheme.onSurface,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: "Back".tl,
                  ),
                ),
                const SizedBox(width: 8),
                // 标题区域
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.reader.widget.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: context.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (context.reader.widget.chapters != null)
                        Text(
                          context.reader.widget.chapters!.titles.elementAtOrNull(
                                context.reader.chapter - 1,
                              ) ??
                              "Chapter ${context.reader.chapter}",
                          style: TextStyle(
                            fontSize: 12,
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 操作按钮组
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 章节评论按钮
                    if (shouldShowChapterComments())
                      Container(
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: context.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: Icon(
                            Icons.comment,
                            size: 20,
                            color: context.colorScheme.onSurface,
                          ),
                          onPressed: openChapterComments,
                          tooltip: "Chapter Comments".tl,
                        ),
                      ),
                    // 章节列表按钮
                    if (context.reader.widget.chapters != null)
                      Container(
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: context.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: Icon(
                            Icons.list_rounded,
                            size: 20,
                            color: context.colorScheme.onSurface,
                          ),
                          onPressed: openChapterDrawer,
                          tooltip: "Chapters".tl,
                        ),
                      ),
                    // 设置按钮
                    Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: context.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: IconButton(
                        icon: Icon(
                          Icons.tune_rounded,
                          size: 20,
                          color: context.colorScheme.onSurface,
                        ),
                        onPressed: openSetting,
                        tooltip: "Settings".tl,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool isLiked() {
    return ImageFavoriteManager().has(
      context.reader.cid,
      context.reader.type.sourceKey,
      context.reader.eid,
      context.reader.page,
      context.reader.chapter,
    );
  }

  void addImageFavorite() async {
    try {
      if (context.reader.images![0].contains('file://')) {
        showToast(
          message: "Local comic collection is not supported at present".tl,
          context: context,
        );
        return;
      }
      String id = context.reader.cid;
      int ep = context.reader.chapter;
      String eid = context.reader.eid;
      String title = context.reader.history!.title;
      String subTitle = context.reader.history!.subtitle;
      int maxPage = context.reader.images!.length;
      int? page = await selectImage();
      if (page == null) return;
      page += 1;
      String sourceKey = context.reader.type.sourceKey;
      String imageKey = context.reader.images![page - 1];
      List<String> tags = context.reader.widget.tags;
      String author = context.reader.widget.author;

      var epName =
          context.reader.widget.chapters?.titles.elementAtOrNull(
            context.reader.chapter - 1,
          ) ??
          "E${context.reader.chapter}";
      var translatedTags = tags.map((e) => e.translateTagsToCN).toList();

      if (isLiked()) {
        if (page == firstPage) {
          showToast(
            message: "The cover cannot be uncollected here".tl,
            context: context,
          );
          return;
        }
        ImageFavoriteManager().deleteImageFavorite([
          ImageFavorite(page, imageKey, null, eid, id, ep, sourceKey, epName),
        ]);
        showToast(
          message: "Uncollected the image".tl,
          context: context,
          seconds: 1,
        );
      } else {
        var imageFavoritesComic =
            ImageFavoriteManager().find(id, sourceKey) ??
            ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              tags,
              translatedTags,
              DateTime.now(),
              author,
              {},
              subTitle,
              maxPage,
            );
        ImageFavorite imageFavorite = ImageFavorite(
          page,
          imageKey,
          null,
          eid,
          id,
          ep,
          sourceKey,
          epName,
        );
        ImageFavoritesEp? imageFavoritesEp = imageFavoritesComic
            .imageFavoritesEp
            .firstWhereOrNull((e) {
              return e.ep == ep;
            });
        if (imageFavoritesEp == null) {
          if (page != firstPage) {
            var copy = imageFavorite.copyWith(
              page: firstPage,
              isAutoFavorite: true,
              imageKey: context.reader.images![0],
            );
            // 不是第一页的话, 自动塞一个封面进去
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [copy, imageFavorite],
              epName,
              maxPage,
            );
          } else {
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [imageFavorite],
              epName,
              maxPage,
            );
          }
          imageFavoritesComic.imageFavoritesEp.add(imageFavoritesEp);
        } else {
          if (imageFavoritesEp.eid != eid) {
            // 空字符串说明是从pica导入的, 那我们就手动刷一遍保证一致
            if (imageFavoritesEp.eid == "") {
              imageFavoritesEp.eid == eid;
            } else {
              // 避免多章节漫画源的章节顺序发生变化, 如果情况比较多, 做一个以eid为准更新ep的功能
              showToast(
                message:
                    "The chapter order of the comic may have changed, temporarily not supported for collection"
                        .tl,
                context: context,
              );
              return;
            }
          }
          imageFavoritesEp.imageFavorites.add(imageFavorite);
        }

        ImageFavoriteManager().addOrUpdateOrDelete(imageFavoritesComic);
        showToast(
          message: "Successfully collected".tl,
          context: context,
          seconds: 1,
        );
      }
      update();
    } catch (e, stackTrace) {
      Log.error("Image Favorite", e, stackTrace);
      showToast(message: e.toString(), context: context, seconds: 1);
    }
  }

  Widget buildBottom() {
    // Use maxPage for display (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    var text = "E${context.reader.chapter} : P$displayPage";
    if (context.reader.widget.chapters == null) {
      text = "P$displayPage";
    }

    return GlassSurface(
      blur: GlassConfig.blur,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              GlassConfig.surface(context, 1.15),
              GlassConfig.surface(context, 0.42),
            ],
          ),
          border: Border(
            top: BorderSide(
              color: context.colorScheme.outlineVariant.withValues(alpha: 0.28),
              width: 0.5,
            ),
          ),
        ),
        padding: EdgeInsets.only(bottom: context.padding.bottom),
        child: Padding(
          padding: EdgeInsets.only(
            left: context.padding.left,
            right: context.padding.right,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度信息和主要控制
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  children: [
                    // 页面信息
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: context.colorScheme.primaryContainer
                                .withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            text,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: context.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        Text(
                          "$displayPage / ${context.reader.maxPage}",
                          style: TextStyle(
                            fontSize: 12,
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 进度滑块
                    Row(
                      children: [
                        // 上一章按钮
                        Container(
                          decoration: BoxDecoration(
                            color: context.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: IconButton(
                            onPressed: () => !isReversed
                                ? context.reader.chapter > 1
                                      ? context.reader.toPrevChapter()
                                      : context.reader.toPage(1)
                                : context.reader.chapter <
                                      context.reader.maxChapter
                                ? context.reader.toNextChapter()
                                : context.reader.toPage(
                                    context.reader.maxPage,
                                  ),
                            icon: Icon(
                              !isReversed
                                  ? Icons.skip_previous_rounded
                                  : Icons.skip_next_rounded,
                              size: 20,
                              color: context.colorScheme.onSurface,
                            ),
                            tooltip: !isReversed
                                ? "Previous Chapter".tl
                                : "Next Chapter".tl,
                          ),
                        ),
                        const SizedBox(width: 12),
                        // 滑块
                        Expanded(child: buildModernSlider()),
                        const SizedBox(width: 12),
                        // 下一章按钮
                        Container(
                          decoration: BoxDecoration(
                            color: context.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: IconButton(
                            onPressed: () => !isReversed
                                ? context.reader.chapter <
                                          context.reader.maxChapter
                                      ? context.reader.toNextChapter()
                                      : context.reader.toPage(
                                          context.reader.maxPage,
                                        )
                                : context.reader.chapter > 1
                                ? context.reader.toPrevChapter()
                                : context.reader.toPage(1),
                            icon: Icon(
                              !isReversed
                                  ? Icons.skip_next_rounded
                                  : Icons.skip_previous_rounded,
                              size: 20,
                              color: context.colorScheme.onSurface,
                            ),
                            tooltip: !isReversed
                                ? "Next Chapter".tl
                                : "Previous Chapter".tl,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 功能按钮栏
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildBottomButton(
                      icon: isLiked()
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      label: "Favorite".tl,
                      onPressed: addImageFavorite,
                      isActive: isLiked(),
                    ),
                    _buildBottomButton(
                      icon: Icons.download_rounded,
                      label: "Save".tl,
                      onPressed: saveCurrentImage,
                    ),
                    _buildBottomButton(
                      icon: Icons.share_rounded,
                      label: "Share".tl,
                      onPressed: share,
                    ),
                    _buildBottomButton(
                      icon: context.reader.autoPageTurningTimer != null
                          ? Icons.timer_rounded
                          : Icons.timer_outlined,
                      label: "Auto".tl,
                      onPressed: () {
                        context.reader.autoPageTurning(
                          context.reader.cid,
                          context.reader.type,
                        );
                        update();
                      },
                      isActive: context.reader.autoPageTurningTimer != null,
                    ),
                    if (App.isAndroid)
                      _buildBottomButton(
                        icon: () {
                          if (rotation == null) {
                            return Icons.screen_rotation_rounded;
                          } else if (rotation == false) {
                            return Icons.screen_lock_portrait_rounded;
                          } else {
                            return Icons.screen_lock_landscape_rounded;
                          }
                        }.call(),
                        label: "Rotate".tl,
                        onPressed: () {
                          if (rotation == null) {
                            setState(() {
                              rotation = false;
                            });
                            SystemChrome.setPreferredOrientations([
                              DeviceOrientation.portraitUp,
                              DeviceOrientation.portraitDown,
                            ]);
                          } else if (rotation == false) {
                            setState(() {
                              rotation = true;
                            });
                            SystemChrome.setPreferredOrientations([
                              DeviceOrientation.landscapeLeft,
                              DeviceOrientation.landscapeRight,
                            ]);
                          } else {
                            setState(() {
                              rotation = null;
                            });
                            SystemChrome.setPreferredOrientations(
                              DeviceOrientation.values,
                            );
                          }
                        },
                      ),
                    if (App.isDesktop)
                      _buildBottomButton(
                        icon: Icons.fullscreen_rounded,
                        label: "Fullscreen".tl,
                        onPressed: () {
                          context.reader.fullscreen();
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool isActive = false,
  }) {
    return _BottomActionButton(
      icon: icon,
      label: label,
      onPressed: onPressed,
      isActive: isActive,
      // 翻页 / 切章时 isLiked 也会变，但那不是点出来的，不该弹。
      positionKey: '${context.reader.chapter}:${context.reader.page}',
    );
  }

  var sliderFocus = FocusNode();

  Widget buildSlider() {
    // Clamp page to maxPage (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    return CustomSlider(
      focusNode: sliderFocus,
      value: displayPage.toDouble(),
      min: 1,
      max: context.reader.maxPage
          .clamp(displayPage, 1 << 16)
          .toDouble(),
      reversed: isReversed,
      divisions: (context.reader.maxPage - 1).clamp(2, 1 << 16),
      onChanged: (i) {
        context.reader.toPage(i.toInt());
      },
    );
  }

  Widget buildModernSlider() {
    // Use maxPage for display (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.3,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: CustomSlider(
        focusNode: sliderFocus,
        value: displayPage.toDouble(),
        min: 1,
        max: context.reader.maxPage
            .clamp(displayPage, 1 << 16)
            .toDouble(),
        reversed: isReversed,
        divisions: (context.reader.maxPage - 1).clamp(2, 1 << 16),
        onChanged: (i) {
          context.reader.toPage(i.toInt());
        },
      ),
    );
  }

  /// 底部的页码胶囊 + 时钟电量。滚动时淡出，避免一直压在画面上。
  Widget buildOverlayInfo() {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _contentScrolling ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: Stack(
            children: [
              if (appdata.settings['showPageNumberInReader'] == true)
                buildPageInfoText(),
              buildStatusInfo(),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildPageInfoText() {
    var epName =
        context.reader.widget.chapters?.titles.elementAtOrNull(
          context.reader.chapter - 1,
        ) ??
        "E${context.reader.chapter}";
    if (epName.length > 12) {
      epName = "${epName.substring(0, 12)}...";
    }
    // Use maxPage for display (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    var pageText = "$displayPage/${context.reader.maxPage}";
    var text = context.reader.widget.chapters != null
        ? "$epName : $pageText"
        : pageText;

    return Positioned(
      bottom: 20,
      left: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget buildStatusInfo() {
    if (appdata.settings['enableClockAndBatteryInfoInReader']) {
      return Positioned(
        bottom: 13,
        right: 25,
        child: Row(
          children: [
            _ClockWidget(),
            const SizedBox(width: 10),
            _BatteryWidget(),
          ],
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
  }

  void openChapterDrawer() {
    _openSideBar(
      context.reader.widget.chapters!.isGrouped
          ? _GroupedChaptersView(context.reader)
          : _ChaptersView(context.reader),
      width: 400,
    );
  }

  void saveCurrentImage() async {
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    // Save file name: ComicName_EP{chapter}_P{page}.{ext} to avoid conflict.
    // The chapter index of different group is continuous, so we use chapter number is enough.
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    saveFile(data: data, filename: filename);
  }

  void share() async {
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    Share.shareFile(data: data, filename: filename, mime: fileType.mime);
  }

  void openSetting() {
    _openSideBar(
      ReaderSettings(
        comicId: context.reader.cid,
        comicSource: context.reader.type.sourceKey,
        onChanged: (key) {
          if (key == "readerMode") {
            context.reader.mode = ReaderMode.fromKey(
              appdata.settings.getReaderSetting(
                context.reader.cid,
                context.reader.type.sourceKey,
                key,
              ),
            );
          }
          if (key == "enableTurnPageByVolumeKey") {
            if (appdata.settings.getReaderSetting(
              context.reader.cid,
              context.reader.type.sourceKey,
              key,
            )) {
              context.reader.handleVolumeEvent();
            } else {
              context.reader.stopVolumeEvent();
            }
          }
          if (key == "quickCollectImage") {
            addDragListener();
          }
          if (key == "showChapterComments" || key == "showChapterCommentsAtEnd") {
            update();
          }
          context.reader.update();
        },
      ),
      width: 400,
    );
  }

  void _openSideBar(Widget widget, {double width = 400}) {
    _gestureDetectorState?.ignoreNextTap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSideBar(
        context,
        widget,
        width: width,
        dismissible: true,
      ).whenComplete(() {
        _gestureDetectorState?.clearIgnoreNextTap();
      });
    });
  }

  bool shouldShowChapterComments() {
    // Check if chapters exist
    if (context.reader.widget.chapters == null) return false;

    // Check if setting is enabled
    var showChapterComments = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      'showChapterComments',
    );
    if (showChapterComments != true) return false;

    // Check if comic source supports chapter comments
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null || source.chapterCommentsLoader == null) return false;

    return true;
  }

  void openChapterComments() {
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null) return;

    var chapters = context.reader.widget.chapters;
    if (chapters == null) return;

    var chapterIndex = context.reader.chapter - 1;
    var epId = chapters.ids.elementAt(chapterIndex);
    var chapterTitle = chapters.titles.elementAt(chapterIndex);

    showSideBar(
      context,
      ChapterCommentsPage(
        comicId: context.reader.cid,
        epId: epId,
        source: source,
        comicTitle: context.reader.widget.name,
        chapterTitle: chapterTitle,
      ),
    );
  }

  Widget buildEpChangeButton() {
    final extraWidth = context.padding.left + context.padding.right;
    if (context.reader.widget.chapters == null) return const SizedBox();
    switch (showFloatingButtonValue) {
      case 0:
        return Container(
          width: 58 + extraWidth,
          height: 58,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            lastValue == 1
                ? Icons.arrow_forward_ios
                : Icons.arrow_back_ios_outlined,
            size: 24,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        );
      case -1:
      case 1:
        return SizedBox(
          width: 58 + extraWidth,
          height: 58,
          child: Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
            elevation: 2,
            child: InkWell(
              onTap: () {
                if (showFloatingButtonValue == 1) {
                  context.reader.toNextChapter();
                } else if (showFloatingButtonValue == -1) {
                  context.reader.toPrevChapter();
                }
                setFloatingButton(0);
              },
              borderRadius: BorderRadius.circular(16),
              child: Center(
                child: Icon(
                  _getArrowIcon(
                    isReversed,
                    showFloatingButtonValue,
                  ),
                  size: 24,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        );
    }
    return const SizedBox();
  }

  IconData _getArrowIcon(bool reversed, int value) {
    if (reversed) {
      return value == 1 ? Icons.arrow_back_ios_outlined : Icons.arrow_forward_ios;
    } else {
      return value == 1 ? Icons.arrow_forward_ios : Icons.arrow_back_ios_outlined;
    }
  }

  /// If there is only one image on screen, return it.
  ///
  /// If there are multiple images on screen,
  /// show an overlay to let the user select an image.
  ///
  /// The return value is the index of the selected image.
  Future<int?> selectImage() async {
    var reader = context.reader;
    var imageViewController = context.reader._imageViewController;

    bool needsSelection = false;
    int? singleImageIndex;

    if (imageViewController is _GalleryModeState) {
      var range = imageViewController.getCurrentPageImageRange();
      if (range != null) {
        var (startIndex, endIndex) = range;
        int actualImageCount = endIndex - startIndex;
        if (actualImageCount == 1) {
          needsSelection = false;
          singleImageIndex = startIndex;
        } else {
          needsSelection = true;
        }
      }
    } else if (imageViewController is _ContinuousModeState) {
      needsSelection = false;
      singleImageIndex = reader.page - 1;
    }

    if (!needsSelection && singleImageIndex != null) {
      return singleImageIndex;
    } else {
      var location = await _showSelectImageOverlay();
      if (location == null) {
        return null;
      }
      var imageKey = imageViewController!.getImageKeyByOffset(location);
      if (imageKey == null) {
        return null;
      }
      return reader.images!.indexOf(imageKey);
    }
  }

  /// Same as [selectImage], but return the image data with its index.
  /// Returns (imageIndex, imageData) or null if cancelled.
  Future<(int, Uint8List)?> selectImageToData() async {
    var i = await selectImage();
    if (i == null) {
      return null;
    }
    var imageKey = context.reader.images![i];
    Uint8List data;
    if (imageKey.startsWith("file://")) {
      data = await File(imageKey.substring(7)).readAsBytes();
    } else {
      data = await (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
    return (i, data);
  }

  Future<Offset?> _showSelectImageOverlay() {
    if (_isOpen) {
      openOrClose();
    }

    var completer = Completer<Offset?>();

    var overlay = Overlay.of(context);
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: _SelectImageOverlayContent(
            onTap: (offset) {
              completer.complete(offset);
              entry!.remove();
            },
            onDispose: () {
              if (!completer.isCompleted) {
                completer.complete(null);
              }
            },
          ),
        );
      },
    );
    overlay.insert(entry);

    return completer.future;
  }
}

class _BatteryWidget extends StatefulWidget {
  @override
  _BatteryWidgetState createState() => _BatteryWidgetState();
}

class _BatteryWidgetState extends State<_BatteryWidget> {
  late Battery _battery;
  late int _batteryLevel = 100;
  Timer? _timer;
  bool _hasBattery = false;
  BatteryState state = BatteryState.unknown;

  @override
  void initState() {
    super.initState();
    _battery = Battery();
    _checkBatteryAvailability();
  }

  void _checkBatteryAvailability() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
      state = await _battery.batteryState;
      if (_batteryLevel > 0 && state != BatteryState.unknown) {
        setState(() {
          _hasBattery = true;
        });
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          _battery.batteryLevel.then((level) {
            if (_batteryLevel != level) {
              setState(() {
                _batteryLevel = level;
              });
            }
          });
        });
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBattery) {
      return const SizedBox.shrink(); //Empty Widget
    }
    return _batteryInfo(_batteryLevel);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _batteryInfo(int batteryLevel) {
    IconData batteryIcon;
    Color batteryColor = context.colorScheme.onSurface;

    if (state == BatteryState.charging) {
      batteryIcon = Icons.battery_charging_full;
    } else if (batteryLevel >= 96) {
      batteryIcon = Icons.battery_full_sharp;
    } else if (batteryLevel >= 84) {
      batteryIcon = Icons.battery_6_bar_sharp;
    } else if (batteryLevel >= 72) {
      batteryIcon = Icons.battery_5_bar_sharp;
    } else if (batteryLevel >= 60) {
      batteryIcon = Icons.battery_4_bar_sharp;
    } else if (batteryLevel >= 48) {
      batteryIcon = Icons.battery_3_bar_sharp;
    } else if (batteryLevel >= 36) {
      batteryIcon = Icons.battery_2_bar_sharp;
    } else if (batteryLevel >= 24) {
      batteryIcon = Icons.battery_1_bar_sharp;
    } else if (batteryLevel >= 12) {
      batteryIcon = Icons.battery_0_bar_sharp;
    } else {
      batteryIcon = Icons.battery_alert_sharp;
      batteryColor = Colors.red;
    }

    return Row(
      children: [
        Icon(
          batteryIcon,
          size: 16,
          color: batteryColor,
          // Stroke
          shadows: List.generate(9, (index) {
            if (index == 4) {
              return null;
            }
            double offsetX = (index % 3 - 1) * 0.8;
            double offsetY = ((index / 3).floor() - 1) * 0.8;
            return Shadow(
              color: context.colorScheme.onInverseSurface,
              offset: Offset(offsetX, offsetY),
            );
          }).whereType<Shadow>().toList(),
        ),
        Stack(
          children: [
            Text(
              '$batteryLevel%',
              style: TextStyle(
                fontSize: 14,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.onInverseSurface,
              ),
            ),
            Text('$batteryLevel%'),
          ],
        ),
      ],
    );
  }
}

class _ClockWidget extends StatefulWidget {
  @override
  _ClockWidgetState createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<_ClockWidget> {
  late String _currentTime;
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _currentTime = _getCurrentTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final time = _getCurrentTime();
      if (_currentTime != time) {
        setState(() {
          _currentTime = time;
        });
      }
    });
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Text(
          _currentTime,
          style: TextStyle(
            fontSize: 14,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4
              ..color = context.colorScheme.onInverseSurface,
          ),
        ),
        Text(_currentTime),
      ],
    );
  }
}

class _SelectImageOverlayContent extends StatefulWidget {
  const _SelectImageOverlayContent({
    required this.onTap,
    required this.onDispose,
  });

  final void Function(Offset) onTap;

  final void Function() onDispose;

  @override
  State<_SelectImageOverlayContent> createState() =>
      _SelectImageOverlayContentState();
}

class _SelectImageOverlayContentState
    extends State<_SelectImageOverlayContent> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        widget.onTap(details.globalPosition);
      },
      child: Container(
        color: Colors.black.withAlpha(50),
        child: Align(
          alignment: Alignment(0, -0.8),
          child: Container(
            width: 232,
            height: 42,
            decoration: BoxDecoration(
              color: context.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.info_outline),
                const SizedBox(width: 16),
                Text(
                  "Click to select an image".tl,
                  style: TextStyle(
                    fontSize: 16,
                    color: context.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 阅读器底部的功能按钮（收藏 / 保存 / 分享 / 自动 / 设置）。
///
/// 三层反馈叠在一起：
/// 1. 按住时图标轻微回缩 —— 任何按钮都有，手指一按就知道点到了；
/// 2. 收藏这类有「激活」态的按钮，从未激活变成激活时弹一下 + 轻触感；
/// 3. 翻页、切章也会让激活态变化，但那不是点击造成的，用 positionKey 抑制掉。
class _BottomActionButton extends StatefulWidget {
  const _BottomActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.isActive,
    required this.positionKey,
  });

  final IconData icon;

  final String label;

  final VoidCallback onPressed;

  final bool isActive;

  /// 当前章节:页码。变化说明是翻页引起的，不是点击。
  final String positionKey;

  @override
  State<_BottomActionButton> createState() => _BottomActionButtonState();
}

class _BottomActionButtonState extends State<_BottomActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  late final Animation<double> _bounce = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.32)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.32, end: 0.92)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.92, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 30,
    ),
  ]).animate(_controller);

  bool _pressed = false;

  late bool _wasActive = widget.isActive;

  late String _positionKey = widget.positionKey;

  @override
  void didUpdateWidget(_BottomActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_positionKey != widget.positionKey) {
      _positionKey = widget.positionKey;
      _wasActive = widget.isActive;
      return;
    }
    if (!_wasActive && widget.isActive) {
      HapticFeedback.lightImpact();
      _controller.forward(from: 0);
    }
    _wasActive = widget.isActive;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: widget.onPressed,
        onHighlightChanged: (v) {
          if (_pressed != v) {
            setState(() {
              _pressed = v;
            });
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: widget.isActive
                ? context.colorScheme.primaryContainer.withValues(alpha: 0.8)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: _pressed ? 0.86 : 1.0,
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOut,
                child: ScaleTransition(
                  scale: _bounce,
                  child: Icon(
                    widget.icon,
                    size: 20,
                    color: widget.isActive
                        ? context.colorScheme.primary
                        : context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight:
                      widget.isActive ? FontWeight.w600 : FontWeight.normal,
                  color: widget.isActive
                      ? context.colorScheme.primary
                      : context.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
