import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cloud_storage/accounts.dart';
import 'package:venera/network/cloud_storage/openlist_bridge.dart';

/// 数据文件同步用的网盘内核装配。
///
/// 只负责把原生 OpenList/夸克内核绑到账号仓库。夸克同步可能抢在启动初始化
/// 之前发起，调用方 await [configure] 就能等到内核真正就绪，而不是拿到一个
/// 「已经开始、还没完成」的假信号。
class CloudKernel {
  CloudKernel._();

  static Future<void>? _configuration;

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
    } catch (e, s) {
      // 内核不可用不能拖垮整个 app：数据同步会自己报错并提示用户。
      Log.error('CloudKernel.configure', '$e\n$s');
    }
  }
}
