part of 'reader.dart';

class _ReaderGestureDetector extends StatefulWidget {
  const _ReaderGestureDetector({required this.child});

  final Widget child;

  @override
  State<_ReaderGestureDetector> createState() => _ReaderGestureDetectorState();
}

class _ReaderGestureDetectorState extends AutomaticGlobalState<_ReaderGestureDetector> {
  late TapGestureRecognizer _tapGestureRecognizer;

  static const _kDoubleTapMaxTime = Duration(milliseconds: 200);

  /// 长按判定时长。太短会在滑动时误触发（尤其是缓慢拖动阅读时）。
  static const _kLongPressMinTime = Duration(milliseconds: 420);

  /// 手指移动超过这个距离就判定为滑动，取消长按判定
  static const _kLongPressSlopSquared = 12.0 * 12.0;

  /// 长按已经打开 HUD 后，继续移动超过这个距离就认为用户其实想滑动
  static const _kLongPressCancelSquared = 30.0 * 30.0;

  static const _kDoubleTapMaxDistanceSquared = 20.0 * 20.0;

  static const _kTapToTurnPagePercent = 0.3;

  final _dragListeners = <_DragListener>[];

  int fingers = 0;

  late _ReaderState reader;

  bool ignoreNextTag = false;

  void ignoreNextTap() {
    ignoreNextTag = true;
  }

  void clearIgnoreNextTap() {
    ignoreNextTag = false;
  }

  @override
  void initState() {
    _tapGestureRecognizer = TapGestureRecognizer()
      ..onTapUp = onTapUp
      ..onSecondaryTapUp = (details) {
        onSecondaryTapUp(details.globalPosition);
      };
    super.initState();
    context.readerScaffold._gestureDetectorState = this;
    reader = context.reader;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.position == Offset.zero) {
          _previousEvent = null;
          return;
        }
        fingers++;
        if (ignoreNextTag) {
          ignoreNextTag = false;
          return;
        }
        // 每次按下都生成新的 token，旧的延时判定自动失效
        final token = ++_pointerToken;
        _lastTapPointer = event.pointer;
        _lastTapMoveDistance = Offset.zero;
        _tapSuppressed = false;
        _tapGestureRecognizer.addPointer(event);
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onStart?.call(event.position);
          }
          _dragInProgress = false;
        }
        Future.delayed(_kLongPressMinTime, () {
          if (!mounted || token != _pointerToken) return;
          if (_lastTapPointer != event.pointer || fingers != 1) return;
          if (_dragInProgress || _longPressInProgress) return;
          final moved = (_lastTapMoveDistance ?? Offset.zero).distanceSquared;
          if (moved < _kLongPressSlopSquared) {
            _tapSuppressed = true;
            onLongPressedDown(event.position);
            _longPressInProgress = true;
          } else {
            _dragInProgress = true;
            for (var dragListener in _dragListeners) {
              dragListener.onStart?.call(event.position);
              dragListener.onMove?.call(_lastTapMoveDistance!);
            }
          }
        });
      },
      onPointerMove: (event) {
        if (event.pointer == _lastTapPointer) {
          _lastTapMoveDistance = event.delta + _lastTapMoveDistance!;
          final moved = _lastTapMoveDistance!.distanceSquared;
          if (!_longPressInProgress && !_dragInProgress) {
            // 还没到长按时长就已经滑开 → 直接进入拖动，取消长按
            if (moved > _kLongPressSlopSquared) {
              _pointerToken++;
              _dragInProgress = true;
              for (var dragListener in _dragListeners) {
                dragListener.onStart?.call(event.position);
                dragListener.onMove?.call(_lastTapMoveDistance!);
              }
            }
          } else if (_longPressInProgress &&
              _longPressIsHud &&
              moved > _kLongPressCancelSquared) {
            // 长按误开了 HUD，但手指还在滑 → 关掉 HUD 并转为拖动
            _longPressInProgress = false;
            _longPressIsHud = false;
            _pointerToken++;
            context.readerScaffold.closeHud();
            _dragInProgress = true;
            for (var dragListener in _dragListeners) {
              dragListener.onStart?.call(event.position);
            }
          }
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onMove?.call(event.delta);
          }
        }
      },
      onPointerUp: (event) {
        fingers--;
        _longPressIsHud = false;
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerCancel: (event) {
        fingers--;
        _longPressIsHud = false;
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          onMouseWheel(event.scrollDelta.dy > 0);
        }
      },
      child: widget.child,
    );
  }

  void onMouseWheel(bool forward) {
    if (HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    if (context.reader.mode.key.startsWith('gallery')) {
      if (forward) {
        if (!context.reader.toNextPage() && !context.reader.isLastChapterOfGroup) {
          context.reader.toNextChapter();
        }
      } else {
        if (!context.reader.toPrevPage() && !context.reader.isFirstChapterOfGroup) {
          context.reader.toPrevChapter(toLastPage: true);
        }
      }
    }
  }

  TapUpDetails? _previousEvent;

  int? _lastTapPointer;

  Offset? _lastTapMoveDistance;

  /// 按下时递增，用于让尚未触发的长按判定失效
  int _pointerToken = 0;

  bool _longPressInProgress = false;

  /// 长按触发的是 HUD（而不是图片缩放），只有 HUD 才能在滑动时被取消
  bool _longPressIsHud = false;

  /// 长按已经消费掉这次点击，抬手时不要再当成 tap
  bool _tapSuppressed = false;

  bool _dragInProgress = false;

  bool get _enableDoubleTapToZoom =>
      appdata.settings.getReaderSetting(reader.cid, reader.type.sourceKey, 'enableDoubleTapToZoom');

  void onTapUp(TapUpDetails event) {
    if (event.globalPosition == Offset.zero &&
        event.localPosition == Offset.zero) {
      _previousEvent = null;
      return;
    }
    if (_tapSuppressed) {
      _tapSuppressed = false;
      _longPressInProgress = false;
      return;
    }
    final location = event.globalPosition;
    if (!_enableDoubleTapToZoom) {
      onTap(location);
      return;
    }
    final previousLocation = _previousEvent?.globalPosition;
    if (previousLocation != null) {
      if ((location - previousLocation).distanceSquared <
          _kDoubleTapMaxDistanceSquared) {
        onDoubleTap(location);
        _previousEvent = null;
        return;
      } else {
        onTap(previousLocation);
      }
    }
    _previousEvent = event;
    Future.delayed(_kDoubleTapMaxTime, () {
      if (_previousEvent == event) {
        onTap(location);
        _previousEvent = null;
      }
    });
  }

  void onTap(Offset location) {
    if (context.readerScaffold.isLocked) {
      return;
    }
    if (reader._imageViewController!.handleOnTap(location)) {
      return;
    } else if (context.readerScaffold.isOpen) {
      // 添加触觉反馈
      HapticFeedback.lightImpact();
      context.readerScaffold.openOrClose();
    } else {
      // Don't open toolbar on chapter comments page
      if (reader.isOnChapterCommentsPage) {
        return;
      }
      if (appdata.settings.getReaderSetting(
          reader.cid, reader.type.sourceKey, 'enableTapToTurnPages')) {
        bool isLeft = false, isRight = false, isTop = false, isBottom = false;
        final width = context.width;
        final height = context.height;
        final x = location.dx;
        final y = location.dy;
        if (x < width * _kTapToTurnPagePercent) {
          isLeft = true;
        } else if (x > width * (1 - _kTapToTurnPagePercent)) {
          isRight = true;
        }
        if (y < height * _kTapToTurnPagePercent) {
          isTop = true;
        } else if (y > height * (1 - _kTapToTurnPagePercent)) {
          isBottom = true;
        }
        bool isCenter = false;
        var prev = () {
          HapticFeedback.selectionClick();
          return context.reader.toPrevPage();
        };
        var next = () {
          HapticFeedback.selectionClick();
          return context.reader.toNextPage();
        };
        if (appdata.settings.getReaderSetting(
            reader.cid, reader.type.sourceKey, 'reverseTapToTurnPages')) {
          prev = () {
            HapticFeedback.selectionClick();
            return context.reader.toNextPage();
          };
          next = () {
            HapticFeedback.selectionClick();
            return context.reader.toPrevPage();
          };
        }
        switch (context.reader.mode) {
          case ReaderMode.galleryLeftToRight:
          case ReaderMode.continuousLeftToRight:
            if (isLeft) {
              prev();
            } else if (isRight) {
              next();
            } else {
              isCenter = true;
            }
          case ReaderMode.galleryRightToLeft:
          case ReaderMode.continuousRightToLeft:
            if (isLeft) {
              next();
            } else if (isRight) {
              prev();
            } else {
              isCenter = true;
            }
          case ReaderMode.galleryTopToBottom:
          case ReaderMode.continuousTopToBottom:
            if (isTop) {
              prev();
            } else if (isBottom) {
              next();
            } else {
              isCenter = true;
            }
        }
        if (!isCenter) {
          return;
        }
      }
      context.readerScaffold.openOrClose();
    }
  }

  void onDoubleTap(Offset location) {
    HapticFeedback.mediumImpact();
    context.reader._imageViewController?.handleDoubleTap(location);
  }

  void onSecondaryTapUp(Offset location) {
    showMenuX(
      context,
      location,
      [
        MenuEntry(
          icon: Icons.settings,
          text: "Settings".tl,
          onClick: () {
            context.readerScaffold.openSetting();
          },
        ),
        MenuEntry(
          icon: Icons.menu,
          text: "Chapters".tl,
          onClick: () {
            context.readerScaffold.openChapterDrawer();
          },
        ),
        MenuEntry(
          icon: Icons.fullscreen,
          text: "Fullscreen".tl,
          onClick: () {
            context.reader.fullscreen();
          },
        ),
        MenuEntry(
          icon: Icons.exit_to_app,
          text: "Exit".tl,
          onClick: () {
            context.pop();
          },
        ),
        if (App.isDesktop && !reader.isLoading)
          MenuEntry(
            icon: Icons.copy,
            text: "Copy Image".tl,
            onClick: () => copyImage(location),
          ),
        if (!reader.isLoading)
          MenuEntry(
            icon: Icons.download_outlined,
            text: "Save Image".tl,
            onClick: () => saveImage(location),
          ),
      ],
    );
  }

  void onLongPressedUp(Offset location) {
    context.reader._imageViewController?.handleLongPressUp(location);
  }

  void onLongPressedDown(Offset location) {
    final action = appdata.settings.getReaderSetting(
      reader.cid,
      reader.type.sourceKey,
      'longPressAction',
    );
    if (action == 'zoom') {
      _longPressIsHud = false;
      context.reader._imageViewController?.handleLongPressDown(location);
    } else {
      _longPressIsHud = true;
      context.readerScaffold.openHud();
    }
  }

  void addDragListener(_DragListener listener) {
    _dragListeners.add(listener);
  }

  void removeDragListener(_DragListener listener) {
    _dragListeners.remove(listener);
  }

  @override
  Object? get key => "reader_gesture";

  void copyImage(Offset location) async {
    var controller = reader._imageViewController;
    var image = await controller!.getImageByOffset(location);
    if (image != null) {
      writeImageToClipboard(image);
    } else {
      context.showMessage(message: "No Image");
    }
  }

  void saveImage(Offset location) async {
    var controller = reader._imageViewController;
    var image = await controller!.getImageByOffset(location);
    if (image != null) {
      var filetype = detectFileType(image);
      saveFile(filename: "image${filetype.ext}", data: image);
    } else {
      context.showMessage(message: "No Image");
    }
  }
}

class _DragListener {
  void Function(Offset point)? onStart;
  void Function(Offset offset)? onMove;
  void Function()? onEnd;

  _DragListener({this.onMove, this.onEnd});
}
