import 'dart:async';
import 'dart:convert';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/features/cloud_library/remote_library_engine.dart';
import 'package:venera/network/cloud_storage/accounts.dart';
import 'package:venera/network/cloud_storage/openlist_bridge.dart';
import 'package:venera/network/proxy.dart';

/// 网盘漫画库的运行时装配。
///
/// 为什么单独收口：库配置存在 `appdata.settings['remoteLibraries']`，账号在
/// `implicitData`。配置/账号任何一项变化都要重建对应的 ComicSource——否则
/// 用户在设置页改了目录，发现页还在读旧索引。这里负责这一整套生命周期。
class CloudBootstrap {
  CloudBootstrap._();

  static final _engines = <String, RemoteLibraryEngine>{};
  static String _signature = '';
  static bool _configured = false;

  /// 配置原生内核。首帧之后调用，不占冷启动时间。
  static Future<void> configure() async {
    if (_configured) return;
    _configured = true;
    try {
      final available = await EmbeddedOpenListRpc.available();
      final accounts = RemoteStorageAccounts.instance;
      accounts.configureOpenList(
        EmbeddedOpenListRpc(),
        dataDir: '${App.dataPath}/openlist',
        proxyResolver: available ? getProxy : null,
      );
      if (available) {
        await accounts.ensureInitialized();
      }
      _watch();
      await refresh();
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
            return [account.id, account.backend.name, account.driver, account.authorization];
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
  }

  static Future<void> close() async {
    for (final engine in _engines.values) {
      await engine.cancel();
    }
    _engines.clear();
  }
}
