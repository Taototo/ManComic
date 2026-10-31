part of 'reader.dart';

class ComicImage extends StatefulWidget {
  /// Modified from flutter Image
  ComicImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.isAntiAlias = false,
    this.enableTrim = false,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
    this.onInit,
    this.onDispose,
  })  : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image),
        assert(cacheWidth == null || cacheWidth > 0),
        assert(cacheHeight == null || cacheHeight > 0);

  final ImageProvider image;

  final String? semanticLabel;

  final bool excludeFromSemantics;

  final double? width;

  final double? height;

  final bool gaplessPlayback;

  final bool matchTextDirection;

  final Rect? centerSlice;

  final ImageRepeat repeat;

  final AlignmentGeometry alignment;

  final BoxFit? fit;

  final BlendMode? colorBlendMode;

  final FilterQuality filterQuality;

  final Animation<double>? opacity;

  final Color? color;

  final bool isAntiAlias;

  /// 是否启用自动裁边（仅连续阅读模式的纵向排列使用，裁掉页面上下纯色留白）
  final bool enableTrim;

  final void Function(State<ComicImage> state)? onInit;

  final void Function(State<ComicImage> state)? onDispose;

  static void clear() => _ComicImageState.clear();

  @override
  State<ComicImage> createState() => _ComicImageState();
}

class _ComicImageState extends State<ComicImage> with WidgetsBindingObserver {
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  ImageChunkEvent? _loadingProgress;
  bool _isListeningToStream = false;
  late bool _invertColors;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<ComicImage>> _scrollAwareContext;
  Object? _lastException;
  ImageStreamCompleterHandle? _completerHandle;

  static final Map<int, Size> _cache = {};

  /// 已计算过的裁边结果（按 ImageProvider hashCode）
  static final Map<int, EdgeTrim> _trimCache = {};

  /// 正在计算中的图片，避免重复触发
  static final Set<int> _trimming = {};

  static clear() {
    _cache.clear();
    _trimCache.clear();
    _trimming.clear();
  }

  EdgeTrim? _trim;

  /// 读取裁边强度设置
  TrimLevel get _trimLevel =>
      TrimLevel.fromKey(appdata.settings['readerAutoTrim'] as String?);

  /// 图片解码完成后异步分析边缘留白，结果缓存起来
  void _maybeComputeTrim(ImageInfo info) {
    if (!widget.enableTrim) {
      return;
    }
    final level = _trimLevel;
    final key = widget.image.hashCode;
    if (level == TrimLevel.off) {
      if (_trim != null) {
        _trim = null;
      }
      return;
    }
    final cached = _trimCache[key];
    if (cached != null) {
      if (_trim != cached) {
        _trim = cached;
      }
      return;
    }
    if (!_trimming.add(key)) {
      return;
    }
    computeEdgeTrim(info.image, level).then((trim) {
      _trimming.remove(key);
      _trimCache[key] = trim;
      if (key == widget.image.hashCode && mounted && trim != _trim) {
        setState(() {
          _trim = trim;
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<ComicImage>>(this);
    widget.onInit?.call(this);
  }

  @override
  void dispose() {
    assert(_imageStream != null);
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    _replaceImage(info: null);
    widget.onDispose?.call(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    _resolveImage();

    if (TickerMode.of(context)) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(ComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolveImage();
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void reassemble() {
    _resolveImage(); // in case the image cache was flushed
    super.reassemble();
  }

  bool containsPoint(Offset point) {
    if (!mounted) {
      return false;
    }
    var renderBox = context.findRenderObject() as RenderBox;
    var localPoint = renderBox.globalToLocal(point);
    return renderBox.paintBounds.contains(localPoint);
  }

  void _updateInvertColors() {
    _invertColors = MediaQuery.maybeInvertColorsOf(context) ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _resolveImage() {
    final ScrollAwareImageProvider provider = ScrollAwareImageProvider<Object>(
      context: _scrollAwareContext,
      imageProvider: widget.image,
    );
    final ImageStream newStream =
        provider.resolve(createLocalImageConfiguration(
      context,
      size: widget.width != null && widget.height != null
          ? Size(widget.width!, widget.height!)
          : null,
    ));
    _updateSourceStream(newStream);
  }

  ImageStreamListener? _imageStreamListener;

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      _imageStreamListener = ImageStreamListener(
        _handleImageFrame,
        onChunk: _handleImageChunk,
        onError: (Object error, StackTrace? stackTrace) {
          setState(() {
            _lastException = error;
          });
        },
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    setState(() {
      _replaceImage(info: imageInfo);
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
    _maybeComputeTrim(imageInfo);
  }

  void _handleImageChunk(ImageChunkEvent event) {
    setState(() {
      _loadingProgress = event;
      _lastException = null;
    });
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    SchedulerBinding.instance
        .addPostFrameCallback((_) => oldImageInfo?.dispose());
    _imageInfo = info;
  }

  // Updates _imageStream to newStream, and moves the stream listener
  // registration from the old stream to the new stream (if a listener was
  // registered).
  void _updateSourceStream(ImageStream newStream) {
    if (_imageStream?.key == newStream.key) {
      return;
    }

    if (_isListeningToStream) {
      _imageStream!.removeListener(_getListener());
    }

    if (!widget.gaplessPlayback) {
      setState(() {
        _replaceImage(info: null);
      });
    }

    setState(() {
      _loadingProgress = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
    });

    _imageStream = newStream;
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }

  void _listenToStream() {
    if (_isListeningToStream) {
      return;
    }

    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;

    _isListeningToStream = true;
  }

  /// Stops listening to the image stream, if this state object has attached a
  /// listener.
  ///
  /// If the listener from this state is the last listener on the stream, the
  /// stream will be disposed. To keep the stream alive, set `keepStreamAlive`
  /// to true, which create [ImageStreamCompleterHandle] to keep the completer
  /// alive and is compatible with the [TickerMode] being off.
  void _stopListeningToStream({bool keepStreamAlive = false}) {
    if (!_isListeningToStream) {
      return;
    }

    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }

    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_lastException != null) {
      // display error and retry button on screen
      return SizedBox(
        height: widget.height == null ? 300 : null,
        width: widget.width == null ? 300 : null,
        child: Center(
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Text(
                      _lastException.toString(),
                      maxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(
                  height: 4,
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Listener(
                    onPointerDown: (details) {
                      GlobalState.find<_ReaderGestureDetectorState>().ignoreNextTap();
                      setState(() {
                        _loadingProgress = null;
                        _lastException = null;
                      });
                      _resolveImage();
                    },
                    child: SizedBox(
                      width: 84,
                      height: 36,
                      child: Center(
                        child: Text(
                          "Retry".tl,
                          style: TextStyle(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(
                  height: 16,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constrains) {
      var width = widget.width;
      var height = widget.height;

      if (_imageInfo != null) {
        // Record the height and the width of the image
        _cache[widget.image.hashCode] = Size(_imageInfo!.image.width.toDouble(),
            _imageInfo!.image.height.toDouble());
      }

      Size? cacheSize = _cache[widget.image.hashCode];
      if (cacheSize != null) {
        if (width == double.infinity) {
          width = constrains.maxWidth;
          height = width * cacheSize.height / cacheSize.width;
        } else if (height == double.infinity) {
          height = constrains.maxHeight;
          width = height * cacheSize.width / cacheSize.height;
        }
      } else {
        if (width == double.infinity) {
          width = constrains.maxWidth;
          height = 300;
        } else if (height == double.infinity) {
          height = constrains.maxHeight;
          width = 300;
        }
      }

      if (_imageInfo != null) {
        final trim = _trim;
        final canTrim = trim != null &&
            !trim.isNone &&
            width != null &&
            height != null &&
            width.isFinite &&
            height.isFinite &&
            width > 0 &&
            height > 0;

        // 需要裁边时按原图尺寸铺满，再用裁剪窗口只露出中间一段
        final rawWidth = width;
        final rawHeight = height;

        // build image
        Widget result = RawImage(
          image: _imageInfo?.image,
          debugImageLabel: _imageInfo?.debugLabel,
          width: rawWidth,
          height: rawHeight,
          scale: _imageInfo?.scale ?? 1.0,
          color: widget.color,
          opacity: widget.opacity,
          colorBlendMode: widget.colorBlendMode,
          fit: canTrim ? BoxFit.fill : widget.fit,
          alignment: widget.alignment,
          repeat: widget.repeat,
          centerSlice: widget.centerSlice,
          matchTextDirection: widget.matchTextDirection,
          invertColors: _invertColors,
          isAntiAlias: widget.isAntiAlias,
          filterQuality: widget.filterQuality,
        );

        if (!widget.excludeFromSemantics) {
          result = Semantics(
            container: widget.semanticLabel != null,
            image: true,
            label: widget.semanticLabel ?? '',
            child: result,
          );
        }

        if (canTrim) {
          final fullWidth = rawWidth!;
          final fullHeight = rawHeight!;
          final visibleHeight = fullHeight * (1 - trim.top - trim.bottom);
          return SizedBox(
            width: fullWidth,
            height: visibleHeight,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minWidth: fullWidth,
                maxWidth: fullWidth,
                minHeight: fullHeight,
                maxHeight: fullHeight,
                child: Transform.translate(
                  offset: Offset(0, -trim.top * fullHeight),
                  child: result,
                ),
              ),
            ),
          );
        }

        result = SizedBox(
          width: width,
          height: height,
          child: Center(
            child: result,
          ),
        );
        return result;
      } else {
        // build progress
        return SizedBox(
          width: width,
          height: height,
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                backgroundColor: context.colorScheme.surfaceContainer,
                value: (_loadingProgress != null &&
                        _loadingProgress!.expectedTotalBytes != null &&
                        _loadingProgress!.expectedTotalBytes! != 0)
                    ? _loadingProgress!.cumulativeBytesLoaded /
                        _loadingProgress!.expectedTotalBytes!
                    : 0,
              ),
            ),
          ),
        );
      }
    });
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder description) {
    super.debugFillProperties(description);
    description.add(DiagnosticsProperty<ImageStream>('stream', _imageStream));
    description.add(DiagnosticsProperty<ImageInfo>('pixels', _imageInfo));
    description.add(DiagnosticsProperty<ImageChunkEvent>(
        'loadingProgress', _loadingProgress));
    description.add(DiagnosticsProperty<int>('frameNumber', _frameNumber));
    description.add(DiagnosticsProperty<bool>(
        'wasSynchronouslyLoaded', _wasSynchronouslyLoaded));
  }
}
