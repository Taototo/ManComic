part of 'settings_page.dart';

/// 存储用量页。
///
/// 原来的设置页只有「缓存 320 MB / 2048 MB」一行，用户既看不出空间被谁占了，
/// 也不知道除缓存之外还有本地漫画、收藏封面、日志在吃存储。这里分类量一遍，
/// 能安全清的给入口，不能清的（收藏图、本地漫画、数据库）只显示账目。
class StorageSettings extends StatefulWidget {
  const StorageSettings({super.key});

  @override
  State<StorageSettings> createState() => _StorageSettingsState();
}

class _StorageSettingsState extends State<StorageSettings> {
  List<StorageUsage>? usages;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await computeStorageUsage();
    if (!mounted) {
      return;
    }
    setState(() {
      usages = data;
    });
  }

  int get _total =>
      usages?.fold<int>(0, (sum, e) => e.isChild ? sum : sum + e.bytes) ?? 0;

  void _clear(StorageUsage usage) {
    showConfirmDialog(
      context: context,
      title: "Clear @a".tlParams({'a': usage.label.tl}),
      content: "This cannot be undone.".tl,
      confirmText: "Clear".tl,
      onConfirm: () => _doClear(usage),
    );
  }

  Future<void> _doClear(StorageUsage usage) async {
    final dialog = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      allowCancel: false,
    );
    try {
      await clearStorageUsage(usage);
    } catch (e, s) {
      Log.error("Clear storage", e.toString(), s);
    }
    dialog.close();
    if (!mounted) {
      return;
    }
    context.showMessage(message: "Cleared".tl);
    await _load();
  }

  void _setCacheLimit() {
    showInputDialog(
      context: context,
      title: "Set Cache Limit".tl,
      hintText: "Size in MB".tl,
      inputValidator: RegExp(r"^\d+$"),
      onConfirm: (value) {
        appdata.settings['cacheSize'] = int.parse(value);
        appdata.saveData();
        setState(() {});
        CacheManager().setLimitSize(appdata.settings['cacheSize']);
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = usages;
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Storage".tl)),
        if (data == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          SliverToBoxAdapter(child: _buildSummary()),
          _SettingPartTitle(title: "Usage".tl, icon: Icons.pie_chart_outline),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildRow(data[index]),
              childCount: data.length,
            ),
          ),
          _SettingPartTitle(
            title: "Cache limit".tl,
            icon: Icons.tune_rounded,
          ),
          ListTile(
            contentPadding: kSettingTilePadding,
            title: Text("Automatic cleanup".tl),
            subtitle: Text(
              "When the cache exceeds this size, older files are removed first."
                  .tl,
            ),
            trailing: Text(
              "${appdata.settings['cacheSize']} MB",
              style: ts.s14,
            ),
            onTap: _setCacheLimit,
          ).toSliver(),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ],
    );
  }

  Widget _buildSummary() {
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        ),
        child: Row(
          children: [
            Icon(Icons.sd_storage_outlined, size: 30, color: colors.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bytesToReadableString(_total),
                    style: ts.s20.bold,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Cache, app data, local comics and logs".tl,
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: "Refresh".tl,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _load,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(StorageUsage usage) {
    return ListTile(
      contentPadding: EdgeInsetsDirectional.only(
        // 子项往里缩一级，用缩进表达层级，不再加图标——缓存下面的
        // 七八个子目录要是每个都配个图标，会比文字本身更吵。
        start: usage.isChild ? 68 : 48,
        end: 16,
      ),
      dense: usage.isChild,
      title: Text(
        usage.label.tl,
        style: usage.isChild ? ts.s14 : null,
      ),
      subtitle: Text(
        bytesToReadableString(usage.bytes),
        style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
      ),
      trailing: usage.clearable
          ? IconButton(
              tooltip: "Clear".tl,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _clear(usage),
            )
          : null,
    );
  }
}
