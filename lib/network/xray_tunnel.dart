import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/subscription.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/network/xray_core.dart';

enum TunnelState { stopped, starting, running, failed }

/// 一次连通性测试的结果。
class TunnelProbe {
  const TunnelProbe({required this.ok, this.milliseconds, this.message});

  final bool ok;

  /// 往返耗时，只在成功时有值。
  final int? milliseconds;

  final String? message;
}

class TunnelStatus {
  const TunnelStatus(this.state, {this.message, this.nodeName, this.port});

  final TunnelState state;

  final String? message;

  final String? nodeName;

  final int? port;

  bool get running => state == TunnelState.running;
}

/// 内置代理（Xray-core 跑在本进程里）。
///
/// 为什么不是 VpnService：本项目的诉求是「只代理自己 + 关掉 app 就干净」。这里
/// 只起一个监听 `127.0.0.1` 的 http 入站，再把自己的代理设置指过去，于是
/// - 别的 app 完全不知道这个端口存在（天然「只针对本 app」）；
/// - 进程一死端口就消失，不需要任何清理逻辑（天然「关了就是关」）。
/// VpnService 正好相反：系统级、要常驻通知、还要跟各种保活策略搏斗。
class XrayTunnel {
  XrayTunnel._();

  /// 「内置代理」总开关，跟着设置走（会随 WebDAV 同步，符合预期：
  /// 换设备后开着就该开着）。
  static const String _enabledKey = 'xrayEnabled';

  /// 上次选的节点名（outbound tag）。
  static const String _nodeKey = 'xrayNodeTag';

  static final ValueNotifier<TunnelStatus> status = ValueNotifier(
    const TunnelStatus(TunnelState.stopped),
  );

  static bool get enabled => appdata.settings[_enabledKey] == true;

  static Future<bool>? _supported;

  /// 这台机器能不能加载核心。UI 用它决定要不要显示入口。
  static Future<bool> available() => _supported ??= XrayCore.available();

  /// 测速用的目标。
  ///
  /// 用 http（不是 https）有两个理由：一是要走 N 个节点时每个都省掉一次 TLS
  /// 握手，二十多个节点的总耗时才压得住；二是它是 Clash / v2rayNG 的默认测速
  /// 点，数字和别的工具能对上。走的是我们自己的 HTTP 入站，所以「能通」本身
  /// 就证明代理在转发——直连这条路在 app 里根本不存在。
  static const _probeUrl = 'http://www.gstatic.com/generate_204';

  /// 单个端口的往返耗时。
  ///
  /// 这里刻意用 Dart 自带的 `HttpClient` 而不是 `AppDio`：后者身上挂着 Cookie
  /// 的 SQLite 查询、缓存键计算、请求日志和 FFI 边界，测出来的是"app 发一个
  /// 请求有多慢"，不是"这条路有多快"。
  static Future<int> _pingPort(int port, Duration timeout) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = timeout;
    final watch = Stopwatch()..start();
    try {
      final request = await client.getUrl(Uri.parse(_probeUrl));
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      watch.stop();
      if (response.statusCode != 204 && response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return watch.elapsedMilliseconds;
    } finally {
      client.close(force: true);
    }
  }

  static Future<TunnelProbe> _probePort(int port) async {
    try {
      final ms = await _pingPort(port, const Duration(seconds: 6));
      return TunnelProbe(ok: true, milliseconds: ms);
    } on TimeoutException {
      return const TunnelProbe(ok: false, message: '超时');
    } catch (e) {
      return TunnelProbe(ok: false, message: _friendlyProbeError(e));
    }
  }

  /// 当前节点能不能出网、要多久。
  static Future<TunnelProbe> probe() async {
    final port = status.value.port;
    if (!status.value.running || port == null) {
      return const TunnelProbe(ok: false, message: '代理未在运行');
    }
    return _probePort(port);
  }

  /// 一次把所有节点都测一遍。
  ///
  /// 关键在配置：**一个进程只能跑一个 Xray 实例**，所以不是"每个节点起一次"，
  /// 而是一条配置里放 N 个 http 入站 + N 个出口，再用 routing 把「第 i 个入站」
  /// 钉到「第 i 个出口」上。起一次、并发打 N 个回环端口，二十多个节点几秒就完。
  ///
  /// 代价是测试期间要停掉正在跑的隧道（同一个实例），结束再按原样拉起来。
  static Future<Map<String, TunnelProbe>> probeAll() async {
    final subscription = SubscriptionService.load();
    final nodes = visibleNodes(subscription);
    if (nodes.isEmpty) {
      return {};
    }
    final wasRunning = status.value.running;
    final previous = selectedNode;
    final results = <String, TunnelProbe>{};
    try {
      if (wasRunning) {
        await stop();
      }
      final ports = await XrayCore.freePorts(nodes.length);
      if (ports.length < nodes.length) {
        throw XrayException('拿不到足够的空闲端口');
      }
      await XrayCore.runXray(buildProbeConfig(ports: ports, nodes: nodes));
      // 并发 4：再多也只会在同一个出口 IP 上互相排队，还容易触发对端的限速。
      var next = 0;
      Future<void> worker() async {
        while (next < nodes.length) {
          final i = next++;
          results[nodes[i].name] = await _probePort(ports[i]);
        }
      }

      await Future.wait(
        List.generate(nodes.length < 4 ? nodes.length : 4, (_) => worker()),
      );
      return results;
    } finally {
      try {
        await XrayCore.stopXray();
      } catch (_) {
        // 没跑起来就停会报错，无所谓。
      }
      if (wasRunning) {
        if (previous != null) {
          appdata.settings[_nodeKey] = previous;
        }
        status.value = const TunnelStatus(TunnelState.stopped);
        setRuntimeProxy(null);
        await start();
      }
    }
  }

  /// 只留用户能理解的那半句，完整异常进日志。
  static String _friendlyProbeError(Object error) {
    final text = error.toString();
    if (text.contains('Connection refused')) {
      return '端口没人监听';
    }
    if (text.contains('handshake') || text.contains('certificate')) {
      return 'TLS 握手失败';
    }
    if (text.contains('Timeout') || text.contains('timeout')) {
      return '超时';
    }
    if (text.contains('HTTP ')) {
      return text.replaceAll('HttpException: ', '');
    }
    Log.error('Xray', '连通性测试失败: $error');
    return '连接失败';
  }

  static String? get selectedNode {
    final tag = appdata.settings[_nodeKey];
    return tag is String && tag.isNotEmpty ? tag : null;
  }

  static Future<void> selectNode(String tag) async {
    appdata.settings[_nodeKey] = tag;
    await appdata.saveData();
    if (status.value.running) {
      // 换节点直接重开，比让用户自己去关再开省事。
      await stop();
      await start();
    }
  }

  static Future<void> setEnabled(bool value) async {
    appdata.settings[_enabledKey] = value;
    await appdata.saveData();
    if (value) {
      await start();
    } else {
      await stop();
    }
  }

  /// 冷启动恢复。
  ///
  /// 进程被系统杀掉时隧道跟着没了，但 `settings['proxy']` 里还留着上一次的
  /// `127.0.0.1:<端口>`——那个端口现在没人监听，等于所有请求都打空。所以启动
  /// 时必须重新拉起（新端口）或者把这个残留清掉。
  static Future<void> restore() async {
    if (!enabled) {
      return;
    }
    if (!await XrayCore.available()) {
      await _fail('核心无法加载');
      return;
    }
    await start();
  }

  static Future<void> start() async {
    if (status.value.state == TunnelState.starting ||
        status.value.state == TunnelState.running) {
      return;
    }
    final subscription = SubscriptionService.load();
    if (visibleNodes(subscription).isEmpty) {
      await _fail('还没有可用的订阅节点');
      return;
    }
    final node = _pickNode(subscription);
    if (node == null) {
      await _fail('还没有可用的订阅节点');
      return;
    }
    status.value = const TunnelStatus(TunnelState.starting);
    try {
      final ports = await XrayCore.freePorts(1);
      if (ports.isEmpty) {
        throw XrayException('拿不到空闲端口');
      }
      final port = ports.first;
      await XrayCore.runXray(buildConfig(port: port, outbound: node.outbound));
      // 只覆盖内存里的代理，不动 settings（原因见 proxy.dart 的 _runtimeProxy）。
      setRuntimeProxy('127.0.0.1:$port');
      status.value = TunnelStatus(
        TunnelState.running,
        nodeName: node.name,
        port: port,
      );
      Log.info('Xray', 'tunnel started on 127.0.0.1:$port (${node.name})');
    } catch (e) {
      await _fail(e is XrayException ? e.message : e.toString());
    }
  }

  static Future<void> stop() async {
    try {
      await XrayCore.stopXray();
    } catch (e) {
      // 没跑起来的 stop 会报错，这里不用管。
    }
    setRuntimeProxy(null);
    status.value = const TunnelStatus(TunnelState.stopped);
  }

  static Future<void> _fail(String message) async {
    status.value = TunnelStatus(TunnelState.failed, message: message);
    appdata.settings[_enabledKey] = false;
    await appdata.saveData();
    setRuntimeProxy(null);
  }

  /// 订阅里用户没划掉的节点。
  static List<VpnNode> visibleNodes(VpnSubscription? subscription) {
    if (subscription == null) {
      return const [];
    }
    final hidden = SubscriptionService.hiddenNodes();
    return [
      for (final node in subscription.nodes)
        if (!hidden.contains(node.name)) node,
    ];
  }

  /// 批量测速用的配置：N 个 http 入站、N 个出口，routing 把第 i 个入站
  /// 钉到第 i 个出口上。
  ///
  /// 入站 tag 用 `probe-i` 而不是节点名：节点名是用户可改的中英文混排，
  /// Xray 虽然接受任意字符串作 tag，但拿它当 routing 的键太脆。
  static String buildProbeConfig({
    required List<int> ports,
    required List<VpnNode> nodes,
  }) {
    final count = nodes.length < ports.length ? nodes.length : ports.length;
    return jsonEncode({
      'log': {'loglevel': 'warning'},
      'inbounds': [
        for (var i = 0; i < count; i++)
          {
            'tag': 'probe-$i',
            'protocol': 'http',
            'listen': '127.0.0.1',
            'port': ports[i],
            'settings': {'timeout': 30},
          },
      ],
      'outbounds': [for (var i = 0; i < count; i++) nodes[i].outbound],
      'routing': {
        'rules': [
          for (var i = 0; i < count; i++)
            {
              'type': 'field',
              'inboundTag': ['probe-$i'],
              'outboundTag': nodes[i].outbound['tag'],
            },
        ],
      },
    });
  }

  static VpnNode? _pickNode(VpnSubscription? subscription) {
    final nodes = visibleNodes(subscription);
    final tag = selectedNode;
    if (tag != null) {
      for (final node in nodes) {
        if (node.name == tag) {
          return node;
        }
      }
    }
    return nodes.isEmpty ? null : nodes.first;
  }

  /// 生成的配置只有一条 http 入站 + 一个出口。
  ///
  /// 用 http 而不是 socks：本项目的两条网络腿里，rhttp（Rust/reqwest）两种都认，
  /// 但 Dart 自带的 `HttpClient`（JS 引擎、文件下载器）只会 `PROXY host:port`，
  /// 不认 SOCKS。入站给 http，两边都能用。
  static String buildConfig({
    required int port,
    required Map<String, dynamic> outbound,
  }) {
    return jsonEncode({
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'http-in',
          'protocol': 'http',
          'listen': '127.0.0.1',
          'port': port,
          'settings': {'timeout': 300},
        },
      ],
      'outbounds': [outbound],
    });
  }
}
