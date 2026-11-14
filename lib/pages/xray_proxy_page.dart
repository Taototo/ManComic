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

  var _busy = false;

  var _supported = true;

  var _probing = false;

  TunnelProbe? _probe;

  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription = SubscriptionService.load();
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
    });
    try {
      final subscription = await SubscriptionService.refresh(url);
      await SubscriptionService.save(subscription);
      if (!mounted) return;
      setState(() {
        _subscription = subscription;
        // 换了节点列表，上一次的延迟就不作数了。
        _probe = null;
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
      _probe = null;
    });
    await XrayTunnel.setEnabled(value);
    if (!mounted) return;
    final status = XrayTunnel.status.value;
    setState(() {
      _busy = false;
      _error = status.state == TunnelState.failed ? status.message : null;
    });
  }

  Future<void> _test() async {
    setState(() {
      _probing = true;
      _probe = null;
    });
    final result = await XrayTunnel.probe();
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probe = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return ValueListenableBuilder<TunnelStatus>(
      valueListenable: XrayTunnel.status,
      builder: (context, status, _) {
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
            _buildProbeRow(colors),
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
                    "count": "${_subscription!.nodes.length}",
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
            if (_subscription != null && _subscription!.nodes.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text("Nodes".tl, style: ts.s14.bold),
              ),
              for (final node in _subscription!.nodes)
                RadioListTile<String>(
                  dense: true,
                  value: node.name,
                  groupValue:
                      XrayTunnel.selectedNode ??
                      _subscription!.nodes.first.name,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      // 换了节点，之前测的延迟不再对应当前出口。
                      _probe = null;
                    });
                    XrayTunnel.selectNode(value);
                  },
                  title: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s14,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  /// 「测试连接」+ 结果。
  ///
  /// 延迟这种东西只有当场测才有意义：节点随时会挂，所以结果不落盘、换节点
  /// 也清掉，避免用户看着一个十分钟前的好成绩去怀疑为什么打不开网页。
  Widget _buildProbeRow(ColorScheme colors) {
    final probe = _probe;
    final text = probe == null
        ? null
        : probe.ok
        ? "${probe.milliseconds} ms"
        : (probe.message ?? "Failed".tl);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Button.outlined(
            onPressed: () {
              if (_busy || _probing) return;
              _test();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_probing)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.speed_rounded, size: 16),
                const SizedBox(width: 6),
                Text(
                  _probing ? "Testing...".tl : "Test connection".tl,
                  style: ts.s12,
                ),
              ],
            ),
          ),
          if (text != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s12.withColor(
                  probe!.ok ? colors.primary : colors.error,
                ),
              ),
            ),
          ],
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
