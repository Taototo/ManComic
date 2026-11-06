import 'dart:async';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/pages/splash_page.dart';
import 'package:venera/utils/io.dart';
import 'package:window_manager/window_manager.dart';
import 'components/components.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/appdata.dart';
import 'foundation/startup_gate.dart';
import 'headless.dart';
import 'init.dart';

void main(List<String> args) {
  if (args.contains('--headless')) {
    runHeadlessMode(args);
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(() async {
      WidgetsFlutterBinding.ensureInitialized();
      await init();
      runApp(const MyApp());
      if (App.isDesktop) {
        await windowManager.ensureInitialized();
        windowManager.waitUntilReadyToShow().then((_) async {
          await windowManager.setTitleBarStyle(
            TitleBarStyle.hidden,
            windowButtonVisibility: App.isMacOS,
          );
          if (App.isLinux) {
            await windowManager.setBackgroundColor(Colors.transparent);
          }
          await windowManager.setMinimumSize(const Size(500, 600));
          var placement = await WindowPlacement.loadFromFile();
          if (App.isLinux) {
            await windowManager.show();
            await placement.applyToWindow();
          } else {
            await placement.applyToWindow();
            await windowManager.show();
          }

          WindowPlacement.loop();
        });
      }
    }, (error, stack) {
      Log.error("Unhandled Exception", error, stack);
    });
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _showSplash = true;

  void _onSplashComplete() {
    // 启动页退场，主页即将出现：放行所有「等 UI 就绪」的延迟任务
    // （启动检查更新靠这个信号弹窗，不再用固定延时去猜）。
    completeStartup();
    setState(() {
      _showSplash = false;
    });
  }

  @override
  void initState() {
    App.registerForceRebuild(forceRebuild);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    checkUpdates();
    super.initState();
  }

  bool isAuthPageActive = false;

  OverlayEntry? hideContentOverlay;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!App.isMobile || !appdata.settings['authorizationRequired']) {
      return;
    }
    if (state == AppLifecycleState.inactive && hideContentOverlay == null) {
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: App.rootContext.colorScheme.surface,
            ),
          );
        },
      );
      Overlay.of(App.rootContext).insert(hideContentOverlay!);
    } else if (hideContentOverlay != null &&
        state == AppLifecycleState.resumed) {
      hideContentOverlay!.remove();
      hideContentOverlay = null;
    }
    if (state == AppLifecycleState.hidden &&
        !isAuthPageActive &&
        !IO.isSelectingFiles) {
      isAuthPageActive = true;
      App.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            App.rootContext.pop();
            isAuthPageActive = false;
          },
        ),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  void forceRebuild() {
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  Color translateColorSetting() {
    return switch (appdata.settings['color']) {
      'red' => Colors.red,
      'pink' => Colors.pink,
      'purple' => Colors.purple,
      'green' => Colors.green,
      'orange' => Colors.orange,
      'blue' => Colors.blue,
      'yellow' => Colors.yellow,
      'cyan' => Colors.cyan,
      _ => Colors.blue,
    };
  }

  ThemeData getTheme(
    Color primary,
    Color? secondary,
    Color? tertiary,
    Brightness brightness,
  ) {
    String? font;
    List<String>? fallback;
    if (App.isLinux || App.isWindows) {
      font = 'Noto Sans CJK';
      fallback = [
        'Segoe UI',
        'Noto Sans SC',
        'Noto Sans TC',
        'Noto Sans',
        'Microsoft YaHei',
        'PingFang SC',
        'Arial',
        'sans-serif'
      ];
    }
    final scheme = SeedColorScheme.fromSeeds(
      primaryKey: primary,
      secondaryKey: secondary,
      tertiaryKey: tertiary,
      brightness: brightness,
      tones: FlexTones.vividBackground(brightness),
    );
    final liquid = isLiquidTheme;
    return ThemeData(
      colorScheme: liquid ? liquidColorScheme(scheme) : scheme,
      fontFamily: font,
      fontFamilyFallback: fallback,
      // 液态主题的页面背景必须透明，否则每页都会盖住全局色斑，玻璃就只剩描边。
      // canvasColor 同理：Material 不带 color 时默认用它，留着不透明同样会挡。
      scaffoldBackgroundColor: liquid ? Colors.transparent : null,
      canvasColor: liquid ? Colors.transparent : null,
      // 对话框不跟着透明到能看见底下内容：它的可读性比玻璃感重要。留 94%
      // 不透明度，看起来是磨砂面板，文字仍然清楚。
      dialogTheme: liquid
          ? DialogThemeData(
              backgroundColor: scheme.surface.withValues(alpha: 0.94),
            )
          : null,
      // 下拉菜单同理：原来各处 showMenu 传的是写死的 F6F6F6 / 1E1E1E，
      // 液态下那是两块不透明死色。这里给一个统一的磨砂色，两处调用改成
      // 液态时不传 color（走这个主题值）。
      popupMenuTheme: liquid
          ? PopupMenuThemeData(
              color: scheme.surface.withValues(alpha: 0.90),
            )
          : null,
      // 这里**故意不改** filledButtonTheme / outlinedButtonTheme。
      // 全局改会把 `FilledButton.tonal` 也一起改成主色（两者的 style 会合并），
      // 详情页那种「下载是淡色、阅读是主色」的主次关系就没了。按钮的玻璃化
      // 交给 LiquidGlassButton 逐个做，其余按钮保持在半透明容器上即可。
      extensions: liquid ? const [LiquidTheme.on] : const [LiquidTheme.off],
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (_showSplash) {
      // 显示启动页
      home = SplashPage(onInitComplete: _onSplashComplete);
    } else if (appdata.settings['authorizationRequired']) {
      home = AuthPage(
        onSuccessfulAuth: () {
          App.rootContext.toReplacement(() => const MainPage());
        },
      );
    } else {
      home = const MainPage();
    }
    return DynamicColorBuilder(builder: (light, dark) {
      Color? primary, secondary, tertiary;
      if (appdata.settings['color'] != 'system' ||
          light == null ||
          dark == null) {
        primary = translateColorSetting();
      } else {
        primary = light.primary;
        secondary = light.secondary;
        tertiary = light.tertiary;
      }
      return MaterialApp(
        title: "ManComic",
        home: home,
        debugShowCheckedModeBanner: false,
        theme: getTheme(primary, secondary, tertiary, Brightness.light),
        navigatorKey: App.rootNavigatorKey,
        darkTheme: getTheme(primary, secondary, tertiary, Brightness.dark),
        themeMode: switch (appdata.settings['theme_mode']) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system
        },
        color: Colors.transparent,
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        locale: () {
          var lang = appdata.settings['language'];
          if (lang == 'system') {
            return null;
          }
          return switch (lang) {
            'zh-CN' => const Locale('zh', 'CN'),
            'zh-TW' => const Locale('zh', 'TW'),
            'en-US' => const Locale('en'),
            _ => null
          };
        }(),
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
          Locale('en'),
        ],
        builder: (context, widget) {
          ErrorWidget.builder = (details) {
            Log.error("Unhandled Exception",
                "${details.exception}\n${details.stack}");
            return Material(
              child: Center(
                child: Text(details.exception.toString()),
              ),
            );
          };
          if (widget != null) {
            /// 如果无法检测到状态栏高度设定指定高度
            /// https://github.com/flutter/flutter/issues/161086
            var isPaddingCheckError =
                MediaQuery.of(context).viewPadding.top <= 0 ||
                MediaQuery.of(context).viewPadding.top > 200;

            if (isPaddingCheckError && Platform.isAndroid) {
              widget = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewPadding: const EdgeInsets.only(
                      top: 15,
                      bottom: 15,
                    ),
                    padding: const EdgeInsets.only(
                      top: 15,
                      bottom: 15,
                    ),
                  ),
                  child: widget);
            }

            widget = OverlayWidget(widget);
            // 更新下载收起后的顶部悬浮条：放在导航器外层，切到任何页面
            // 都能看到，点一下就能展开回进度卡片。
            widget = Stack(
              fit: StackFit.expand,
              children: [widget, const UpdateDownloadBanner()],
            );
            if (App.isDesktop) {
              widget = Shortcuts(
                shortcuts: {
                  LogicalKeySet(LogicalKeyboardKey.escape): VoidCallbackIntent(
                    App.pop,
                  ),
                },
                child: MouseBackDetector(
                  onTapDown: App.pop,
                  child: WindowFrame(widget),
                ),
              );
            }
            if (isLiquidTheme) {
              // 全局只铺一块纯色，色斑交给**每一页自己**画（[AppPageBackground]）。
              //
              // 之前是全局铺一层色斑、所有页面共用。看着省事，但页面因此必须
              // 保持透明，转场时新页的半透明区域会把旧页透出来——也就是用户
              // 反复报的「重影」。现在每页自带同一套色斑：视觉上还是同一块背
              // 景（渐变固定在屏幕坐标上，滚动和切页都不动），但页面盖住页面
              // 时是真盖住。这层纯色负责兜住转场边缘和没有页面的瞬间。
              widget = Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: Theme.of(context).colorScheme.surface),
                  widget,
                ],
              );
            }
            return _SystemUiProvider(Material(
              color: (App.isLinux || isLiquidTheme)
                  ? Colors.transparent
                  : null,
              child: widget,
            ));
          }
          throw ('widget is null');
        },
      );
    });
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
