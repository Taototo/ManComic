part of "components.dart";

void showToast({
  required String message,
  required BuildContext context,
  Widget? icon,
  Widget? trailing,
  int? seconds,
}) {
  var newEntry = OverlayEntry(
      builder: (context) => _ToastOverlay(
            message: message,
            icon: icon,
            trailing: trailing,
          ));

  var state = context.findAncestorStateOfType<OverlayWidgetState>();

  state?.addOverlay(newEntry);

  Timer(Duration(seconds: seconds ?? 2), () => state?.remove(newEntry));
}

/// 屏幕中间的一行短提示，用于「再按一次退出」这类不打断操作的告知。
///
/// 特意用 OverlayEntry 而不是 Dialog：不铺遮罩、不拦截手势，
/// 提示还亮着的时候，下一次侧滑照样能传到 PopScope 上去。
OverlayEntry? _centerHintEntry;

void showCenterHint(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final old = _centerHintEntry;
  if (old != null) {
    if (old.mounted) {
      old.remove();
    }
    _centerHintEntry = null;
  }
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _CenterHintOverlay(
      message: message,
      duration: duration,
      onDone: () {
        if (identical(_centerHintEntry, entry)) {
          _centerHintEntry = null;
        }
        if (entry.mounted) {
          entry.remove();
        }
      },
    ),
  );
  _centerHintEntry = entry;
  overlay.insert(entry);
}

class _CenterHintOverlay extends StatefulWidget {
  const _CenterHintOverlay({
    required this.message,
    required this.duration,
    required this.onDone,
  });

  final String message;

  final Duration duration;

  final VoidCallback onDone;

  @override
  State<_CenterHintOverlay> createState() => _CenterHintOverlayState();
}

class _CenterHintOverlayState extends State<_CenterHintOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 160),
  )..forward();

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, () async {
      if (!mounted) return;
      await _controller.reverse();
      if (mounted) {
        widget.onDone();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: curve,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curve),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  // 原来写死半透明黑：深色模式下整个界面本来就接近纯黑，
                  // 黑胶囊贴在黑底上边界直接消失，只剩一行白字浮着，看着
                  // 像没渲染完。改成跟随主题的反色底 —— 深色主题给浅色
                  // 胶囊配深字，浅色主题维持深色胶囊配白字。
                  color: cs.inverseSurface.withValues(alpha: isDark ? 0.94 : 0.86),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: cs.onInverseSurface.withValues(alpha: 0.14),
                    width: 0.7,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.22),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onInverseSurface,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastOverlay extends StatelessWidget {
  const _ToastOverlay({required this.message, this.icon, this.trailing});

  final String message;

  final Widget? icon;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: Theme.of(context).colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
          elevation: 2,
          textStyle:
              ts.withColor(Theme.of(context).colorScheme.onInverseSurface),
          child: IconTheme(
            data: IconThemeData(
                color: Theme.of(context).colorScheme.onInverseSurface),
            child: IntrinsicWidth(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                constraints: BoxConstraints(
                  maxWidth: context.width - 32,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) icon!.paddingRight(8),
                    Expanded(
                      child: Text(
                        message,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w500),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (trailing != null) trailing!.paddingLeft(8)
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OverlayWidget extends StatefulWidget {
  const OverlayWidget(this.child, {super.key});

  final Widget child;

  @override
  State<OverlayWidget> createState() => OverlayWidgetState();
}

class OverlayWidgetState extends State<OverlayWidget> {
  final overlayKey = GlobalKey<OverlayState>();

  var entries = <OverlayEntry>[];

  void addOverlay(OverlayEntry entry) {
    if (overlayKey.currentState != null) {
      overlayKey.currentState!.insert(entry);
      entries.add(entry);
    }
  }

  void remove(OverlayEntry entry) {
    if (entries.remove(entry)) {
      entry.remove();
    }
  }

  void removeAll() {
    for (var entry in entries) {
      entry.remove();
    }
    entries.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(
      key: overlayKey,
      initialEntries: [OverlayEntry(builder: (context) => widget.child)],
    );
  }
}

void showDialogMessage(BuildContext context, String title, String message) {
  showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: title,
      content: Text(message).paddingHorizontal(16),
      actions: [
        FilledButton(
          onPressed: context.pop,
          child: Text("OK".tl),
        )
      ],
    ),
  );
}

Future<void> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  required void Function() onConfirm,
  String confirmText = "Confirm",
  Color? btnColor,
}) {
  return showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: title,
      content: Text(content).paddingHorizontal(16).paddingVertical(8),
      actions: [
        FilledButton(
          onPressed: () {
            context.pop();
            onConfirm();
          },
          style: FilledButton.styleFrom(
            backgroundColor: btnColor,
          ),
          child: Text(confirmText.tl),
        ),
      ],
    ),
  );
}

class LoadingDialogController {
  double? _progress;

  String? _message;

  void Function()? _closeDialog;

  void Function(double? value)? _serProgress;

  void Function(String message)? _setMessage;

  bool closed = false;

  void close() {
    if (closed) {
      return;
    }
    closed = true;
    if (_closeDialog == null) {
      Future.microtask(_closeDialog!);
    } else {
      _closeDialog!();
    }
  }

  void setProgress(double? value) {
    if (closed) {
      return;
    }
    _serProgress?.call(value);
  }

  void setMessage(String message) {
    if (closed) {
      return;
    }
    _setMessage?.call(message);
  }
}

LoadingDialogController showLoadingDialog(
  BuildContext context, {
  void Function()? onCancel,
  bool barrierDismissible = true,
  bool allowCancel = true,
  String? message,
  String cancelButtonText = "Cancel",
  bool withProgress = false,
}) {
  var controller = LoadingDialogController();
  controller._message = message;

  if (withProgress) {
    controller._progress = 0;
  }

  var loadingDialogRoute = DialogRoute(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext context) {
      return StatefulBuilder(builder: (context, setState) {
        controller._serProgress = (value) {
          setState(() {
            controller._progress = value;
          });
        };
        controller._setMessage = (message) {
          setState(() {
            controller._message = message;
          });
        };
        return ContentDialog(
          title: controller._message ?? 'Loading',
          content: LinearProgressIndicator(
            value: controller._progress,
            backgroundColor: context.colorScheme.surfaceContainer,
          ).paddingHorizontal(16).paddingVertical(16),
          actions: [
            FilledButton(
              onPressed: allowCancel
                  ? () {
                      controller.close();
                      onCancel?.call();
                    }
                  : null,
              child: Text(cancelButtonText.tl),
            )
          ],
        );
      });
    },
  );

  var navigator = Navigator.of(context, rootNavigator: true);

  navigator.push(loadingDialogRoute).then((value) => controller.closed = true);

  controller._closeDialog = () {
    navigator.removeRoute(loadingDialogRoute);
  };

  return controller;
}

class ContentDialog extends StatelessWidget {
  const ContentDialog({
    super.key,
    this.title, // 如果不传 title 将不会展示
    required this.content,
    this.dismissible = true,
    this.actions = const [],
    this.glass = false,
  });

  final String? title;

  final Widget content;

  final List<Widget> actions;

  final bool dismissible;

  /// 整块底板用液态玻璃，透出弹窗背后的页面。
  ///
  /// 玻璃的效果取决于「底下有没有东西可折射」。把玻璃放到**里面的某个
  /// 小部件**上是没用的：Dialog 底板本身就是不透明的 surface，玻璃压在
  /// 一块纯色上，只在边缘糊出一点自己的描边，看着像没生效——「抽一本」
  /// 之前怎么调卡片都调不出玻璃就是这个原因。
  ///
  /// 打开这一个开关时要配套调淡 `barrierColor`，否则遮罩把背后的页面压
  /// 成一片黑，玻璃采到的全是黑色。
  final bool glass;

  @override
  Widget build(BuildContext context) {
    var content = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title != null
              ? Appbar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: dismissible ? context.pop : null,
            ),
            title: Text(title!),
            backgroundColor: Colors.transparent,
          )
              : const SizedBox.shrink(),
          this.content,
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: actions,
          ).paddingRight(12),
          const SizedBox(height: 16),
        ],
      ),
    );
    Widget panel = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 600,
        minWidth: math.min(400, context.width - 16),
      ),
      child: MediaQuery.removePadding(
        removeTop: true,
        removeBottom: true,
        context: context,
        child: content,
      ),
    );
    if (glass) {
      final isDark = context.brightness == Brightness.dark;
      // 玻璃作为**背景层**垫在内容下面，而不是把内容整个包起来：
      // IntrinsicWidth 测量内在宽度时会去问 child，而玻璃内部是
      // LayoutBuilder / 着色器，遇到 intrinsic 查询会直接抛异常。
      // 放进 Stack 的 Positioned.fill 就不参与测量，布局仍由内容决定。
      panel = Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: LiquidGlassPanel(
                borderRadius: BorderRadius.circular(24),
                // standard：弹窗会被反复重挂载，premium 那套 toImageSync
                // 采样在这种场景下拿不到背景，玻璃会整块消失。
                quality: lg.GlassQuality.standard,
                // 底板上有标题、下拉框和按钮，底色要比卡片实一点才压得住；
                // 但也不能高到看不见背后的封面，0.42 是两者之间的那档。
                tintAlpha: isDark ? 0.56 : 0.42,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          panel,
        ],
      );
    }
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(glass ? 24 : 8),
        // 玻璃自己带菲涅尔高光和细边，Dialog 再描一圈就成双边框了。
        side: glass
            ? BorderSide.none
            : context.brightness == Brightness.dark
                ? BorderSide(color: context.colorScheme.outlineVariant)
                : BorderSide.none,
      ),
      insetPadding: context.width < 400
          ? const EdgeInsets.symmetric(horizontal: 4)
          : const EdgeInsets.symmetric(horizontal: 16),
      // 玻璃自己带阴影和质感，Dialog 再叠一层实心底色和白板阴影就白做了。
      elevation: glass ? 0 : 2,
      shadowColor: context.colorScheme.shadow,
      backgroundColor: glass ? Colors.transparent : context.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: IntrinsicWidth(child: panel),
      ),
    );
  }
}

Future<void> showInputDialog({
  required BuildContext context,
  required String title,
  String? hintText,
  required FutureOr<Object?> Function(String) onConfirm,
  String? initialValue,
  String confirmText = "Confirm",
  String cancelText = "Cancel",
  RegExp? inputValidator,
  String? image,
  Uint8List? imageData,
}) {
  var controller = TextEditingController(text: initialValue);
  bool isLoading = false;
  String? error;

  return showDialog(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: title,
            content: Column(
              children: [
                if (image != null)
                  SizedBox(
                    height: 108,
                    child: Image.network(image, fit: BoxFit.none),
                  ).paddingBottom(8),
                if (image == null && imageData != null)
                  SizedBox(
                    height: 108,
                    child: Image.memory(imageData, fit: BoxFit.none),
                  ).paddingBottom(8),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: hintText,
                    border: const OutlineInputBorder(),
                    errorText: error,
                  ),
                ).paddingHorizontal(12),
              ],
            ),
            actions: [
              Button.filled(
                isLoading: isLoading,
                onPressed: () async {
                  if (inputValidator != null &&
                      !inputValidator.hasMatch(controller.text)) {
                    setState(() => error = "Invalid input");
                    return;
                  }
                  var futureOr = onConfirm(controller.text);
                  Object? result;
                  if (futureOr is Future) {
                    setState(() => isLoading = true);
                    result = await futureOr;
                    setState(() => isLoading = false);
                  } else {
                    result = futureOr;
                  }
                  if (result == null) {
                    context.pop();
                  } else {
                    setState(() => error = result.toString());
                  }
                },
                child: Text(confirmText.tl),
              ),
            ],
          );
        },
      );
    },
  );
}

void showInfoDialog({
  required BuildContext context,
  required String title,
  required String content,
  String confirmText = "OK",
}) {
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: title,
        content: Text(content).paddingHorizontal(16).paddingVertical(8),
        actions: [
          Button.filled(
            onPressed: context.pop,
            child: Text(confirmText.tl),
          ),
        ],
      );
    },
  );
}

Future<int?> showSelectDialog({
  required String title,
  required List<String> options,
  int? initialIndex,
}) async {
  int? current = initialIndex;

  await showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: title,
            content: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Select(
                    current: current == null ? "" : options[current!],
                    values: options,
                    minWidth: 156,
                    onTap: (i) {
                      setState(() {
                        current = i;
                      });
                    },
                  )
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  current = null;
                  context.pop();
                },
                child: Text('Cancel'.tl),
              ),
              FilledButton(
                onPressed: current == null ? null : context.pop,
                child: Text('Confirm'.tl),
              ),
            ],
          );
        },
      );
    },
  );

  return current;
}
