import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/subscription.dart';
import 'package:venera/network/xray_core.dart';
import 'package:venera/network/xray_tunnel.dart';
import 'package:venera/utils/translations.dart';

/// 内置代理页（设置里的入口用）。
class XrayProxyPage extends StatelessWidget {
  const XrayProxyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Built-in proxy".tl,
      body: const XrayProxyBody(),
    );
  }
}

/// 无脚手架的版本。
///
/// 「漫画源 / 内置代理」合集页把它塞进 TabBarView，所以不能再自带一层
/// Scaffold —— 否则合集页的顶栏下面会再长出一个标题栏。
///
/// 和系统代理 / VpnService 的区别写在 [XrayTunnel] 的注释里：核心跑在本进程，
/// 只监听 127.0.0.1，进程一死端口就没了——所以「关掉 app 代理就没了」不需要
/// 任何清理逻辑，是结构上就成立的事。
class XrayProxyBody extends StatefulWidget {
  const XrayProxyBody({super.key});

  @override
  State<XrayProxyBody> createState() => _XrayProxyBodyState();
}

class _XrayProxyBodyState extends State<XrayProxyBody> {
  late final TextEditingController _url;

  VpnSubscription? _subscription;

  /// 刷新订阅中。
  var _busy = false;

  var _supported = true;

  /// 批量测速中。
  var _testingAll = false;

  /// 节点名 → 上一次测出来的结果。只活在这次打开页面期间：节点会挂、线路会变，
  /// 十分钟前的成绩拿来看只会误导人。
  Map<String, TunnelProbe> _results = {};

  var _hiddenCount = 0;

  String? _error;

  List<VpnNode> get _nodes => XrayTunnel.visibleNodes(_subscription);

  @override
  void initState() {
    super.initState();
    _subscription = SubscriptionService.load();
    _hiddenCount = SubscriptionService.hiddenNodes().length;
    _url = TextEditingController(text: _subscription?.url ?? '');
    XrayTunnel.available().then((ok) {
      if (mounted) {
        setState(() {
          _supported = ok;
        });
      }
    });
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() {
        _error = "Paste a subscription link first".tl;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _results = {};
    });
    try {
      final subscription = await SubscriptionService.refresh(url);
      await SubscriptionService.save(subscription);
      if (!mounted) return;
      setState(() {
        _subscription = subscription;
        _hiddenCount = SubscriptionService.hiddenNodes().length;
      });
      // 订阅换了节点列表，正在跑的隧道要按新列表重开。
      if (XrayTunnel.status.value.running) {
        await XrayTunnel.stop();
        await XrayTunnel.start();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is XrayException ? e.message : e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() {
      _busy = true;
      _error = null;
      // 换了出口，之前那批延迟就不再对应当前这条路。
      _results = {};
    });
    await XrayTunnel.setEnabled(value);
    if (!mounted) return;
    final status = XrayTunnel.status.value;
    setState(() {
      _busy = false;
      _error = status.state == TunnelState.failed ? status.message : null;
    });
  }

  /// 「测试连接」：把所有节点都过一遍，结果贴在各自行的末尾。
  Future<void> _testAll() async {
    // 一个进程只能跑一个 Xray 实例，测全部就得先把当前隧道停掉再换成
    // "N 个入站"的那份配置，测完再拉回来。正在用的人会感觉断一下，
    // 所以先说一声，别让人以为是崩了。
    if (XrayTunnel.status.value.running) {
      showCenterHint(App.rootContext, "The proxy pauses while testing".tl);
    }
    setState(() {
      _testingAll = true;
      _results = {};
      _error = null;
    });
    try {
      final results = await XrayTunnel.probeAll();
      if (!mounted) return;
      setState(() {
        _results = results;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is XrayException ? e.message : e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _testingAll = false;
        });
      }
    }
  }

  /// 点一行节点 = 换过去连上，然后立刻告诉你这条路通不通。
  ///
  /// 结果用 [showCenterHint]：就是「再按一次退出」的那种屏幕中间一行字。
  /// 这里不需要按钮也不需要遮罩——用户点节点是为了接着用，不是为了读报告。
  Future<void> _selectNode(VpnNode node) async {
    setState(() {
      _results = {};
      _error = null;
    });
    // 换节点要重启核心（一两百毫秒），测速又可能等上几秒。中间先给一句，
    // 免得用户以为点空了又点一次。
    showCenterHint(App.rootContext, "Connecting...".tl);
    await XrayTunnel.selectNode(node.name);
    if (!XrayTunnel.status.value.running) {
      // 没开代理时点节点也算「连这一台」。
      await XrayTunnel.setEnabled(true);
    }
    if (!mounted) return;
    final status = XrayTunnel.status.value;
    if (!status.running) {
      showCenterHint(App.rootContext, status.message ?? "Failed".tl);
      return;
    }
    setState(() {}); // 让状态卡立刻显示新节点
    final probe = await XrayTunnel.probe();
    if (!mounted) return;
    showCenterHint(
      App.rootContext,
      probe.ok
          ? "${node.name} · ${probe.milliseconds} ms"
          : "${node.name} · ${probe.message ?? "Failed".tl}",
      duration: const Duration(seconds: 3),
    );
  }

  Future<void> _hideNode(VpnNode node) async {
    await SubscriptionService.hideNode(node.name);
    if (!mounted) return;
    setState(() {
      _hiddenCount = SubscriptionService.hiddenNodes().length;
      _results.remove(node.name);
    });
    showCenterHint(App.rootContext, "Hidden".tl);
  }

  Future<void> _restoreHidden() async {
    await SubscriptionService.restoreHiddenNodes();
    if (!mounted) return;
    setState(() {
      _hiddenCount = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return ValueListenableBuilder<TunnelStatus>(
      valueListenable: XrayTunnel.status,
      builder: (context, status, _) {
        final nodes = _nodes;
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                "The proxy runs inside this app and only carries its own traffic. Closing the app removes it, no need to switch it off manually."
                    .tl,
                style: ts.s12.withColor(colors.onSurfaceVariant),
              ),
            ),
            if (!_supported)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  "This device cannot load the proxy core".tl,
                  style: ts.s12.withColor(colors.error),
                ),
              ),
            _buildStatusCard(status),
            _buildTestRow(colors),
            SwitchListTile(
              title: Text("Enable".tl),
              subtitle: status.state == TunnelState.failed
                  ? Text(
                      status.message ?? "",
                      style: ts.s12.withColor(colors.error),
                    )
                  : null,
              value: XrayTunnel.enabled,
              onChanged: _supported && !_busy ? _toggle : null,
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text("Subscription".tl, style: ts.s14.bold),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _url,
                style: ts.s14,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: "https://…",
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  suffixIcon: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: "Refresh".tl,
                          icon: const Icon(Icons.refresh, size: 20),
                          onPressed: _refresh,
                        ),
                ),
              ),
            ),
            if (_subscription != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  "@count nodes · @time".tlParams({
                    "count": "${nodes.length}",
                    "time": _formatTime(_subscription!.updatedAt),
                  }),
                  style: ts.s12.withColor(colors.onSurfaceVariant),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(_error!, style: ts.s12.withColor(colors.error)),
              ),
            if (nodes.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text("Nodes".tl, style: ts.s14.bold),
              ),
              for (final node in nodes) _buildNodeRow(context, node, status),
              if (_hiddenCount > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _restoreHidden,
                      icon: const Icon(Icons.undo, size: 16),
                      label: Text(
                        "@n hidden · Restore".tlParams({"n": _hiddenCount}),
                        style: ts.s12,
                      ),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildNodeRow(
    BuildContext context,
    VpnNode node,
    TunnelStatus status,
  ) {
    final colors = context.colorScheme;
    final result = _results[node.name];
    final current =
        XrayTunnel.selectedNode ?? (status.running ? status.nodeName : null);
    // 只有真的在跑的时候才勾上：写了设置但隧道没起来，勾着会让人以为已经连了。
    final selected = current == node.name && status.running;
    return RadioListTile<String>(
      dense: true,
      value: node.name,
      groupValue: selected ? node.name : null,
      onChanged: (value) {
        if (value != null) {
          _selectNode(node);
        }
      },
      secondary: IconButton(
        tooltip: "Delete".tl,
        icon: const Icon(Icons.delete_outline, size: 18),
        color: colors.onSurfaceVariant,
        onPressed: () => _hideNode(node),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              node.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts.s14,
            ),
          ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                result.ok
                    ? "${result.milliseconds} ms"
                    : (result.message ?? ""),
                style: ts.s10.withColor(
                  result.ok ? colors.primary : colors.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 「测试连接」+ 已测数量。
  Widget _buildTestRow(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Button.outlined(
            onPressed: () {
              if (_busy || _testingAll) return;
              _testAll();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_testingAll)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.speed_rounded, size: 16),
                const SizedBox(width: 6),
                Text(
                  _testingAll ? "Testing...".tl : "Test all".tl,
                  style: ts.s12,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _results.isEmpty
                ? const SizedBox.shrink()
                : Text(
                    "@n tested".tlParams({"n": _results.length}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s10.withColor(colors.onSurfaceVariant),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(TunnelStatus status) {
    final colors = context.colorScheme;
    final (label, color) = switch (status.state) {
      TunnelState.running => ("Running".tl, colors.primary),
      TunnelState.starting => ("Starting".tl, colors.tertiary),
      TunnelState.failed => ("Failed".tl, colors.error),
      TunnelState.stopped => ("Not running".tl, colors.onSurfaceVariant),
    };
    final detail = status.running
        ? "${status.nodeName ?? ""} · 127.0.0.1:${status.port ?? ""}"
        : (status.message ?? "");
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: ts.s14.withColor(color)),
                  if (detail.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s10.withColor(colors.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int millis) {
    if (millis <= 0) return "-";
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return "${time.year}-${two(time.month)}-${two(time.day)} "
        "${two(time.hour)}:${two(time.minute)}";
  }
}
