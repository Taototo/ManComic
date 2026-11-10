part of 'settings_page.dart';

/// Favorites：收藏夹怎么用。
///
/// 只管和收藏相关的行为：点一下收藏是看详情还是直接读、长按快捷收藏放到哪个
/// 文件夹、读完之后要不要自动挪走。这些设置的共同点是「影响收藏夹里发生了什么」，
/// 和「书怎么看」（阅读）或「App 长什么样」（App）都不重叠。
class FavoritesSettings extends StatefulWidget {
  const FavoritesSettings({super.key});

  @override
  State<FavoritesSettings> createState() => _FavoritesSettingsState();
}

class _FavoritesSettingsState extends State<FavoritesSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Favorites".tl)),
        _SettingPartTitle(
          title: "Collection behavior".tl,
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
      ],
    );
  }
}
