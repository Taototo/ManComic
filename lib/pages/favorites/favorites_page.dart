import 'dart:convert';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
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
import 'package:venera/pages/source_match_sheet.dart';
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

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  String? folder;

  bool isNetwork = false;

  FolderList? folderList;

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
    var data = appdata.implicitData['favoriteFolder'];
    if (data != null) {
      folder = data['name'];
      isNetwork = data['isNetwork'] ?? false;
    }
    if (folder != null
        && !isNetwork
        && !LocalFavoritesManager().existsFolder(folder!)) {
      folder = null;
    }
    locked = Privacy.isFavoritesLocked;
    appdata.settings.addListener(onSettingsChanged);
    super.initState();
  }

  @override
  void dispose() {
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
        return Align(
          alignment: Alignment.centerLeft,
          child: Material(
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
          ),
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

  Widget buildBody() {
    if (folder == null) {
      return CustomScrollView(
        slivers: [
          SliverAppbar(
            leading: Tooltip(
              message: "Folders".tl,
              child: context.width <= _kTwoPanelChangeWidth
                  ? IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: showFolderSelector,
                    )
                  : null,
            ),
            title: GestureDetector(
              onTap: context.width < _kTwoPanelChangeWidth
                  ? showFolderSelector
                  : null,
              child: Text("Unselected".tl),
            ),
          ),
        ],
      );
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
