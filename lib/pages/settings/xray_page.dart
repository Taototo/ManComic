part of 'settings_page.dart';

/// 内置代理：导入订阅链接，只隧道本 app 自己的流量。
///
/// 和系统代理 / VpnService 的区别写在 [XrayTunnel] 的注释里：核心跑在本进程，
/// 只监听 127.0.0.1，进程一死端口就没了——所以「关掉 app 代理就没了」不需要
/// 任何清理逻辑，是结构上就成立的事。
class XrayPage extends StatefulWidget {
  const XrayPage({super.key});

  @override
  State<XrayPage> createState() => _XrayPageState();
}

class _XrayPageState extends State<XrayPage> {
  late final TextEditingController _url;

  VpnSubscription? _subscription;

  var _busy = false;

  var _supported = true;

  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription = SubscriptionService.load();
    _url = TextEditingController(text: _subscription?.url ?? '');
    XrayCore.available().then((ok) {
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
    });
    await XrayTunnel.setEnabled(value);
    if (!mounted) return;
    final status = XrayTunnel.status.value;
    setState(() {
      _busy = false;
      _error = status.state == TunnelState.failed ? status.message : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return PopUpWidgetScaffold(
      title: "Built-in proxy".tl,
      body: ValueListenableBuilder<TunnelStatus>(
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
              const SizedBox(height: 8),
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
                      setState(() {});
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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
