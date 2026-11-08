import 'dart:convert';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/privacy.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/pages/smart_shelf_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/pinyin_search.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/title_sort.dart';
import 'package:venera/utils/translations.dart';

part 'favorite_actions.dart';
part 'side_bar.dart';
part 'local_favorites_page.dart';
part 'network_favorites_page.dart';

const _kLeftBarWidth = 256.0;

const _kTwoPanelChangeWidth = 720.0;

/// 收藏夹抽屉的开关入口。
///
/// 收藏页自己的标题栏（原来那个「未选择 / 文件夹名」的 SliverAppbar）已经
/// 去掉了——它压在玻璃顶栏下面，等于又多一条实色横杠。抽屉的入口因此提到
/// 了顶栏的图标位上，顶栏和页面是两棵子树，只能由上层把「点一下」这件事
/// 转发进来，和推荐页的分段控件是同一个套路。
class FavoritesFolderController {
  VoidCallback? open;
}

/// 收藏页交给玻璃顶栏的内容：文件夹名 + 页面自己的操作按钮。
///
/// 收藏页原来自己有一条 SliverAppbar（文件夹名 + 排序 / 多选 / 搜索 / 更多），
/// 它就压在玻璃顶栏下面：顶上等于多出一条实色横杠，同一屏里还有两个搜索
/// 图标各管各的。现在那条栏整体去掉，标题和图标位都由页面交给顶栏。
///
/// [update] 带一个 owner：切文件夹时**新**页面的 initState 会先跑、**旧**
/// 页面的 dispose 后跑，不带 owner 的话旧页面的清理会把新页面刚写进去的
/// 内容一起抹掉（顶栏闪一下空白）。
class FavoritesTopBarController extends ChangeNotifier {
  Object? _owner;

  String? _title;

  List<PaneActionEntry> _actions = const [];

  String? get title => _title;

  List<PaneActionEntry> get actions => _actions;

  void update(
    Object owner, {
    String? title,
    List<PaneActionEntry> actions = const [],
  }) {
    final changed = title != _title || !_sameActions(_actions, actions);
    _owner = owner;
    _title = title;
    _actions = actions;
    if (changed) {
      notifyListeners();
    }
  }

  void clear(Object owner) {
    if (!identical(_owner, owner)) {
      return;
    }
    _owner = null;
    if (_title == null && _actions.isEmpty) {
      return;
    }
    _title = null;
    _actions = const [];
    notifyListeners();
  }

  /// 只比「看得见的那部分」：onTap 每次 build 都是新闭包，逐项比闭包会让
  /// 顶栏每帧重建一次（还会顺手把顶栏玻璃重置一遍）。
  static bool _sameActions(List<PaneActionEntry> a, List<PaneActionEntry> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i].icon != b[i].icon ||
          a[i].label != b[i].label ||
          a[i].color != b[i].color) {
        return false;
      }
    }
    return true;
  }
}

/// 声明「这一页在顶栏里显示什么」。
///
/// 包在收藏页各子页的最外层：谁在树上，顶栏就听谁的。做成 widget 而不是让
/// 每个页面自己去调 controller，一来 StatelessWidget（网络收藏的几个子页
/// 都是）也能用，二来「写入」必须排在 build 之后——在 initState 里直接通知
/// 会撞上「build 期间 markNeedsBuild」。
class FavoritesTopBarScope extends StatefulWidget {
  const FavoritesTopBarScope({
    super.key,
    required this.controller,
    required this.title,
    this.actions = const [],
    required this.child,
  });

  final FavoritesTopBarController controller;

  /// 顶栏标题位的内容。文件夹名这类「随时可能变」的东西放这里，
  /// 比塞进图标位更合适——它本来就在原来那条栏的左边。
  final String? title;

  final List<PaneActionEntry> actions;

  final Widget child;

  @override
  State<FavoritesTopBarScope> createState() => _FavoritesTopBarScopeState();
}

class _FavoritesTopBarScopeState extends State<FavoritesTopBarScope> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant FavoritesTopBarScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每次重建都重新写一遍：图标本身会随状态变（筛选被改过要高亮、
    // 是否已选多选状态会换掉整组动作），而 [FavoritesTopBarController]
    // 只在「看得见的部分」变了才通知顶栏重画，所以这里是廉价的。
    _schedule();
  }

  @override
  void dispose() {
    widget.controller.clear(this);
    super.dispose();
  }

  void _schedule() {
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) {
        return;
      }
      widget.controller.update(
        this,
        title: widget.title,
        actions: widget.actions,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key, this.folders, this.topBar});

  /// 抽屉入口。为 null 时页面自己把入口留在页面里（测试或独立使用）。
  final FavoritesFolderController? folders;

  /// 顶栏内容（文件夹名 + 页面操作按钮）。为 null 时页面不往顶栏写东西，
  /// 各子页会把原来那条 SliverAppbar 留着——单独使用本页时仍然可用。
  final FavoritesTopBarController? topBar;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

/// 从 implicitData 里恢复上次选中的收藏夹，返回 (folder, isNetwork)。
///
/// 「全部」「已阅」不是磁盘上的真实目录，而是两个哨兵名（定义见
/// `local_favorites_page.dart`）。它们必须原样保留：早先的写法只放行了
/// 「已阅」，「全部」每次都会被当成「文件夹已被删除」重置成 null（未选择），
/// 于是切到别的 tab 再回来、页面重建一次，筛选就丢了。
///
/// 抽成纯函数是为了能单独测 —— 这类 bug 的表现是"偶尔没记住"，在界面上
/// 很难稳定复现。
(String?, bool) resolveFavoriteFolder(
  Object? data, {
  required bool Function(String folder) existsFolder,
}) {
  if (data is! Map) {
    return (null, false);
  }
  final name = data['name'];
  final isNetwork = data['isNetwork'] == true;
  if (name is! String) {
    return (null, isNetwork);
  }
  if (isNetwork) {
    return (name, true);
  }
  if (name == _localAllFolderLabel || name == _localReadFolderLabel) {
    return (name, false);
  }
  return (existsFolder(name) ? name : null, false);
}

class _FavoritesPageState extends State<FavoritesPage> {
  String? folder;

  bool isNetwork = false;

  FolderList? folderList;

  /// 顶栏内容的上游。各子页通过 [FavoritesTopBarScope] 往里写。
  FavoritesTopBarController? get topBar => widget.topBar;

  /// 隐私保护：当前是否被模糊遮罩挡住
  bool locked = false;

  void onSettingsChanged() {
    if (!mounted) return;
    var shouldLock = Privacy.isFavoritesLocked;
    if (shouldLock != locked) {
      setState(() {
        locked = shouldLock;
      });
    }
  }

  void unlock() {
    Privacy.unlockFavorites();
    if (mounted) {
      setState(() {
        locked = false;
      });
    }
  }

  void setFolder(bool isNetwork, String? folder) {
    setState(() {
      this.isNetwork = isNetwork;
      this.folder = folder;
    });
    folderList?.update();
    appdata.implicitData['favoriteFolder'] = {
      'name': folder,
      'isNetwork': isNetwork,
    };
    appdata.writeImplicitData();
  }

  @override
  void initState() {
    final restored = resolveFavoriteFolder(
      appdata.implicitData['favoriteFolder'],
      existsFolder: (name) => LocalFavoritesManager().existsFolder(name),
    );
    folder = restored.$1;
    isNetwork = restored.$2;
    locked = Privacy.isFavoritesLocked;
    widget.folders?.open = showFolderSelector;
    appdata.settings.addListener(onSettingsChanged);
    super.initState();
  }

  @override
  void dispose() {
    if (widget.folders?.open == showFolderSelector) {
      widget.folders?.open = null;
    }
    appdata.settings.removeListener(onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconTheme(
      data: IconThemeData(color: Theme.of(context).colorScheme.secondary),
      child: Stack(
        children: [
          AnimatedPositioned(
            left: context.width <= _kTwoPanelChangeWidth ? -_kLeftBarWidth : 0,
            top: 0,
            bottom: 0,
            duration: const Duration(milliseconds: 200),
            child: (const _LeftBar()).fixWidth(_kLeftBarWidth),
          ),
          Positioned(
            top: 0,
            left: context.width <= _kTwoPanelChangeWidth ? 0 : _kLeftBarWidth,
            right: 0,
            bottom: 0,
            child: buildBody(),
          ),
          if (locked)
            Positioned.fill(
              child: _PrivacyShield(onUnlock: unlock),
            ),
        ],
      ),
    );
  }

  void showFolderSelector() {
    Navigator.of(App.rootContext).push(PageRouteBuilder(
      barrierDismissible: true,
      fullscreenDialog: true,
      opaque: false,
      barrierColor: Colors.black.toOpacity(0.36),
      pageBuilder: (context, animation, secondary) {
        // 液态开启时抽屉换成磨砂玻璃面板。
        //
        // 磨砂的要点是**强模糊 + 淡底色**，而不是把底色加白：底色一浓，
        // 后面的封面看不见了，模糊也就白做了——那只是一块半透明白板。
        // 这里 blur 给到 44（引擎按 sigma/3.5 折算成 12.6 的模糊强度），
        // 底色只留 0.45，身后的封面化成一团有颜色的雾，文字依然是满色。
        //
        // 档位用 standard：抽屉是滑入动画，standard 走实时 BackdropFilter，
        // 每一帧都在重新模糊下面的内容；premium 会把背景采样成一张静态
        // 纹理，滑的那两三百毫秒里看起来像贴在屏幕上一块浆糊。
        final surface = LiquidGlassEngine.enabled
            ? LiquidGlassPanel(
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(18),
                ),
                quality: lg.GlassQuality.standard,
                blur: 44,
                tintAlpha: 0.45,
                child: Material(
                  type: MaterialType.transparency,
                  child: SizedBox(
                    width: min(300, context.width - 16),
                    child: _LeftBar(
                      withAppbar: true,
                      onGlassBackground: true,
                      favPage: this,
                      onSelected: () {
                        context.pop();
                      },
                    ),
                  ),
                ),
              )
            : Material(
                child: SizedBox(
                  width: min(300, context.width - 16),
                  child: _LeftBar(
                    withAppbar: true,
                    favPage: this,
                    onSelected: () {
                      context.pop();
                    },
                  ),
                ),
              );
        return Align(
          alignment: Alignment.centerLeft,
          child: surface,
        );
      },
      transitionsBuilder: (context, animation, secondary, child) {
        var offset =
            Tween<Offset>(begin: const Offset(-1, 0), end: const Offset(0, 0));
        return SlideTransition(
          position: offset.animate(CurvedAnimation(
            parent: animation,
            curve: Curves.fastOutSlowIn,
          )),
          child: child,
        );
      },
    ));
  }

  /// 还没选收藏夹时的占位。
  ///
  /// 这里原来是一条「未选择」标题栏 + 目录按钮。那条栏压在玻璃顶栏下面，
  /// 顶上等于多出一条实色横杠，和主页那种「内容从玻璃底下穿过去」完全不是
  /// 一个观感。入口已经挪到顶栏的图标位上，页面里只留一句提示和一个按钮。
  /// 宽屏走双栏，左侧目录一直可见，不需要这个占位。
  Widget buildNoFolderSelected() {
    if (context.width > _kTwoPanelChangeWidth) {
      return const SizedBox();
    }
    final cs = context.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.collections_bookmark_outlined,
            size: 46,
            color: cs.onSurfaceVariant.toOpacity(0.45),
          ),
          const SizedBox(height: 14),
          Text(
            "No folder selected".tl,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: showFolderSelector,
            icon: const Icon(Icons.folder_outlined, size: 18),
            label: Text("Folders".tl),
          ),
        ],
      ),
    );
  }

  Widget buildBody() {
    if (folder == null) {
      return buildNoFolderSelected();
    }
    if (!isNetwork) {
      return _LocalFavoritesPage(
          folder: folder!, key: PageStorageKey("local_$folder"));
    } else {
      var favoriteData = getFavoriteDataOrNull(folder!);
      if (favoriteData == null) {
        folder = null;
        return buildBody();
      } else {
        return NetworkFavoritePage(favoriteData,
            key: PageStorageKey("network_$folder"));
      }
    }
  }
}

abstract interface class FolderList {
  void update();

  void updateFolders();
}

/// 收藏页隐私保护遮罩：不透明雾面 + 居中眼睛，点按任意位置解锁。
///
/// 遮罩底色接近不透明是有意为之：BackdropFilter 在第一帧（下层内容尚未绘制）
/// 或图片刚解码时拿不到可模糊的背景，半透明底会让人短暂看到真实内容。
/// 模糊只负责质感，遮挡由底色负责。
class _PrivacyShield extends StatefulWidget {
  const _PrivacyShield({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  State<_PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<_PrivacyShield>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
    lowerBound: 0.97,
    upperBound: 1.03,
  )..repeat(reverse: true);

  /// 解锁时驱动「雾面消散」：模糊逐渐变清、遮罩淡出、眼睛放大上浮
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );

  bool _pressed = false;

  bool _unlocking = false;

  @override
  void dispose() {
    _pulse.dispose();
    _reveal.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (_unlocking) return;
    setState(() {
      _unlocking = true;
    });
    _pulse.stop();
    _reveal.forward(from: 0).then((_) {
      if (mounted) {
        widget.onUnlock();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_reveal.value);
        final sigma = 40 * (1 - t);
        return Opacity(
          opacity: 1 - t,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => setState(() => _pressed = true),
                onTapUp: (_) => setState(() => _pressed = false),
                onTapCancel: () => setState(() => _pressed = false),
                onTap: _handleTap,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.1,
                      colors: [
                        cs.surface.toOpacity(0.93),
                        cs.surface.toOpacity(0.97),
                      ],
                    ),
                  ),
                  child: Center(
                    child: Transform.translate(
                      offset: Offset(0, -30 * t),
                      child: Transform.scale(
                        scale: 1 + 0.24 * t,
                        child: Opacity(
                          opacity: (1 - t * 1.7).clamp(0.0, 1.0),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            builder: (context, v, child) {
                              return Opacity(
                                opacity: v,
                                child: Transform.scale(
                                  scale: 0.94 + 0.06 * v,
                                  child: child,
                                ),
                              );
                            },
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedBuilder(
                                  animation: _pulse,
                                  builder: (context, child) {
                                    final scale =
                                        _pulse.value * (_pressed ? 0.92 : 1.0);
                                    return Transform.scale(
                                      scale: scale,
                                      child: child,
                                    );
                                  },
                                  child: Container(
                                    width: 92,
                                    height: 92,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: cs.onSurface.toOpacity(0.05),
                                      border: Border.all(
                                        color: cs.outlineVariant.toOpacity(0.7),
                                        width: 0.8,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.toOpacity(0.10),
                                          blurRadius: 24,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.visibility_outlined,
                                      size: 38,
                                      color: cs.onSurface.toOpacity(0.75),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  "Favorites Locked".tl,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: cs.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  "Tap anywhere to view favorites".tl,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurface.toOpacity(0.6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
