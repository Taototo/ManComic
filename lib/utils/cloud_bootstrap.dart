import 'dart:async';
import 'dart:convert';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/features/cloud_library/library_tabs.dart';
import 'package:venera/features/cloud_library/remote_library_engine.dart';
import 'package:venera/network/cloud_storage/accounts.dart';
import 'package:venera/network/cloud_storage/openlist_bridge.dart';

/// 网盘漫画库的运行时装配。
///
/// 为什么单独收口：库配置存在 `appdata.settings['remoteLibraries']`，账号在
/// `implicitData`。配置/账号任何一项变化都要重建对应的 ComicSource——否则
/// 用户在设置页改了目录，发现页还在读旧索引。这里负责这一整套生命周期。
class CloudBootstrap {
  CloudBootstrap._();

  static final _engines = <String, RemoteLibraryEngine>{};
  static String _signature = '';
  static Future<void>? _configuration;

  /// 配置原生内核。首帧之后调用，不占冷启动时间。
  ///
  /// 返回同一个 Future：夸克同步可能比首帧后的初始化更早发起，它 await 这里
  /// 就能等到内核真正就绪，而不是拿到一个「已经开始、还没完成」的假信号。
  static Future<void> configure() => _configuration ??= _configure();

  static Future<void> _configure() async {
    try {
      final available = await EmbeddedOpenListRpc.available();
      final accounts = RemoteStorageAccounts.instance;
      accounts.configureOpenList(
        EmbeddedOpenListRpc(),
        dataDir: '${App.dataPath}/openlist',
        // 刻意不给内核传代理：这里的后端只有夸克（国内直连最快最稳）。
        // 之前把 App 的代理（内置 Xray 隧道或设置里的节点）塞给内核，夸克
        // 服务端遇到境外出口会直接掐连接，Go 侧只能看到 `Get …: EOF`，
        // 表现为「连不上网盘」。真要全局代理，用户开系统 VPN 更合适。
        proxyResolver: null,
      );
      if (available) {
        await accounts.ensureInitialized();
      }
      // 历史版本里自动创建的备份库没写进发现页，升级后补一次页签。
      _watch();
      await refresh();
      // 源注册完之后再补页签：先写页签、后注册源的话，发现页会在过滤
      // 「只保留真实存在的 explore page」时把它丢掉。
      await migrateLibraryTabsOnce();
    } catch (e, s) {
      // 内核不可用不能拖垮整个 app：网盘功能入口会自己隐藏。
      Log.error('CloudBootstrap.configure', '$e\n$s');
    }
  }

  static void _watch() {
    RemoteStorageAccounts.instance.addListener(() {
      unawaited(refresh());
    });
  }

  /// 这个 sourceKey 是不是网盘漫画库的源。
  static bool isCloudSourceKey(String key) =>
      key == RemoteLibrarySource.sourceKey || key.startsWith('remote_library_');

  /// 等网盘库装配完成。
  ///
  /// 网盘库的源是首帧之后才注册的（绑定内核要走一次 channel）。冷启动后直接点
  /// 「继续阅读 / 历史里的网盘漫画」，很可能比注册更早，`ComicSource.find`
  /// 拿到 null，阅读器就报「comic not found」——看起来像是没指向网盘。
  static Future<void> ensureReady() async {
    await configure();
    await refresh();
  }

  /// 按历史记录里的封面判断这本是不是网盘漫画。
  ///
  /// 库被删掉之后 `sourceKey` 会退化成 `Unknown:<type>`，只能靠图片 key 认。
  static bool looksLikeCloudComic(String cover) =>
      cover.startsWith('remote-zip:') || cover.startsWith('remote-work-image:');

  /// 生成当前配置的签名。签名没变就不动源——避免 notifyListeners 递归。
  static String _computeSignature() {
    final accounts = RemoteStorageAccounts.instance;
    return jsonEncode([
      for (final lib in RemoteComicLibraryRegistry.read())
        [
          lib.id,
          lib.sourceKey,
          lib.accountId,
          lib.directories,
          lib.name,
          lib.autoRefresh,
          lib.refreshIntervalMinutes,
          () {
            final account = accounts.account(lib.accountId);
            if (account == null) return null;
            return [
              account.id,
              account.backend.name,
              account.driver,
              account.authorization,
            ];
          }(),
        ],
    ]);
  }

  static Future<void> refresh() async {
    final signature = _computeSignature();
    if (signature == _signature) return;
    _signature = signature;

    final accounts = RemoteStorageAccounts.instance;
    final active = <String>{};
    for (final lib in RemoteComicLibraryRegistry.read()) {
      final account = accounts.account(lib.accountId);
      if (account == null || !account.isConfigured) continue;
      active.add(lib.sourceKey);
      var engine = _engines[lib.sourceKey];
      if (engine == null || !engine.matches(lib, account)) {
        engine?.cancel();
        engine = RemoteLibraryEngine(
          library: lib,
          store: accounts.storeFor(lib.accountId),
        );
        _engines[lib.sourceKey] = engine;
        RemoteLibraryEngines.replace(engine);
      }
      ComicSourceManager().remove(lib.sourceKey);
      ComicSourceManager().add(engine.create());
    }
    for (final key in _engines.keys.toList()) {
      if (active.contains(key)) continue;
      _engines.remove(key)?.cancel();
      RemoteLibraryEngines.remove(key);
      ComicSourceManager().remove(key);
    }
    // 发现页只在 settings 变化时重算页签列表。库名可能先写进 explore_pages、
    // 源后注册（新建库、自动创建的备份库都是这个顺序），不重新发一次通知
    // 的话页签会被过滤掉，用户看到的就是「库建好了但找不到入口」。
    final pages = appdata.settings['explore_pages'];
    if (pages is List) {
      appdata.settings['explore_pages'] = List<String>.from(
        pages.whereType<String>(),
      );
    }
  }

  static Future<void> close() async {
    for (final engine in _engines.values) {
      await engine.cancel();
    }
    _engines.clear();
  }
}
