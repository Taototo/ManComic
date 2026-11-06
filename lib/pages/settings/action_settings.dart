part of 'settings_page.dart';

/// 操作：怎么点、怎么滑、点完发生什么。
///
/// 和「阅读」的分工：阅读页管的是「书怎么看」（翻页方式、显示、图片处理），
/// 这一页管的是「手怎么用」——阅读器里的手势、收藏相关的快捷操作、以及
/// 需要额外验证才能进入的隐私项。这些设置共同的特点是「改了之后手上能立刻
/// 感觉到差别」，所以放在一起。
class ActionSettings extends StatefulWidget {
  const ActionSettings({super.key});

  @override
  State<ActionSettings> createState() => _ActionSettingsState();
}

class _ActionSettingsState extends State<ActionSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Actions".tl)),
        // 阅读器里的手势排在最前：这一页的主题就是「手怎么用」，手势是其中
        // 用得最频繁的一项。它们和阅读页共用同一套开关，放这里是因为关注点
        // 是「怎么操作」而不是「画面怎么显示」。
        SliverToBoxAdapter(child: const ReaderGestureSettings()),
        _SettingPartTitle(
          title: "Favorites".tl,
          icon: Icons.bookmark_border_rounded,
        ),
        SelectSetting(
          title: "Click favorite".tl,
          settingKey: "onClickFavorite",
          optionTranslation: {
            "viewDetail": "View Detail".tl,
            "read": "Read".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Quick Favorite".tl,
          settingKey: "quickFavorite",
          help:
              "Long press on the favorite button to quickly add to this folder"
                  .tl,
          optionTranslation: {
            for (var e in LocalFavoritesManager().folderNames) e: e
          },
        ).toSliver(),
        SelectSetting(
          title: "Add new favorite to".tl,
          settingKey: "newFavoriteAddTo",
          optionTranslation: {
            "start": "Start".tl,
            "end": "End".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Move favorite after reading".tl,
          settingKey: "moveFavoriteAfterRead",
          optionTranslation: {
            "none": "None".tl,
            "end": "End".tl,
            "start": "Start".tl,
          },
        ).toSliver(),
        _SwitchSetting(
          title: "Auto close favorite panel after operation".tl,
          settingKey: "autoCloseFavoritePanel",
        ).toSliver(),
        _SwitchSetting(
          title: "Show local favorites before network favorites".tl,
          settingKey: "localFavoritesFirst",
        ).toSliver(),
        _CallbackSetting(
          title: "Delete all unavailable local favorite items".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var count = await LocalFavoritesManager().removeInvalid();
            controller.close();
            context.showMessage(
              message: "Deleted @a favorite items".tlParams({'a': count}),
            );
          },
          actionTitle: 'Delete'.tl,
        ).toSliver(),
        // 阅读器里的手势：和阅读页共用同一套开关，放在这里是因为它们都是
        // 「手怎么操作」，而不是「画面怎么显示」。
        _SettingPartTitle(
          title: "Privacy & security".tl,
          icon: Icons.lock_outline_rounded,
        ),
        _SwitchSetting(
          title: "Privacy Shield for Favorites".tl,
          subtitle:
              "Blur the page until you tap to unlock, resets on app restart".tl,
          settingKey: "privacyFavorites",
        ).toSliver(),
        if (!App.isLinux)
          _SwitchSetting(
            title: "Authorization Required".tl,
            settingKey: "authorizationRequired",
            onChanged: () async {
              var current = appdata.settings['authorizationRequired'];
              if (current) {
                final auth = LocalAuthentication();
                final bool canAuthenticateWithBiometrics =
                    await auth.canCheckBiometrics;
                final bool canAuthenticate = canAuthenticateWithBiometrics ||
                    await auth.isDeviceSupported();
                if (!canAuthenticate) {
                  context.showMessage(message: "Biometrics not supported".tl);
                  setState(() {
                    appdata.settings['authorizationRequired'] = false;
                  });
                  appdata.saveData();
                  return;
                }
              }
            },
          ).toSliver(),
      ],
    );
  }
}
