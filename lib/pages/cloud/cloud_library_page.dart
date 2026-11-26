import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/features/cloud_library/remote_library_settings_page.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/network/cloud_storage/openlist_bridge.dart';
import 'package:venera/pages/cloud/storage.dart';

/// 网盘功能总入口：账号管理 + 在线漫画库。
///
/// 作为独立页从「设置 → 内容」进入；配置好的库同时会注册成漫画源出现在
/// 发现页（见 utils/cloud_bootstrap.dart），两条入口共用同一份配置。
class CloudLibraryPage extends StatefulWidget {
  const CloudLibraryPage({super.key});

  @override
  State<CloudLibraryPage> createState() => _CloudLibraryPageState();
}

class _CloudLibraryPageState extends State<CloudLibraryPage> {
  bool? _available;

  @override
  void initState() {
    super.initState();
    EmbeddedOpenListRpc.available().then((value) {
      if (mounted) setState(() => _available = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final available = _available ?? (App.isAndroid || App.isIOS);
    return Scaffold(
      appBar: Appbar(title: const Text('网盘与在线漫画库')),
      body: SmoothCustomScrollView(
        slivers: [
          if (!available)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('当前平台不支持内置网盘内核（仅 Android / iOS）。'),
                ),
              ),
            ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '账号',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('网盘账号'),
              subtitle: const Text('夸克网盘 / WebDAV'),
              trailing: const Icon(Icons.arrow_right),
              onTap: () => context.to(() => StorageAccountsPage()),
            ),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                '在线漫画库',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
          ),
          const RemoteLibrariesSliver(),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
