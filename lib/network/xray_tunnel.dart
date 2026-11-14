import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/subscription.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/network/xray_core.dart';

enum TunnelState { stopped, starting, running, failed }

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
    if (subscription == null || subscription.nodes.isEmpty) {
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

  static VpnNode? _pickNode(VpnSubscription subscription) {
    final tag = selectedNode;
    if (tag != null) {
      for (final node in subscription.nodes) {
        if (node.name == tag) {
          return node;
        }
      }
    }
    return subscription.nodes.isEmpty ? null : subscription.nodes.first;
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
