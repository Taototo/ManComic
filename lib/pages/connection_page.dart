import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/xray_proxy_page.dart';

/// 「漫画源」和「内置代理」的合集页。
///
/// 这两个是同一类东西：**外部连接的配置**。源挂了是一条腿断，代理挂了是另一条
/// 腿断，而顶栏宽度只够 6 颗图标——与其再加一颗按钮，不如把两条腿并进一页，
/// 左右滑就能对照着看。
///
/// 用 `TabBarView` 而不是往里塞两个 `Column`：横向滑动是它自带的，手指从右往
/// 左一划就换页，不需要额外的 PageView 逻辑。
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  var _index = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    // 滑动过程中 index 会先变，动画结束时才稳定；两边都刷新一次只是多一帧，
    // 但漏掉就会让分段控件停在旧的那一格上。
    if (_tabs.index != _index && mounted) {
      setState(() {
        _index = _tabs.index;
      });
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          const GlassPageBackdrop(),
          Column(
            children: [
              SizedBox(height: MediaQuery.paddingOf(context).top),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    IconButton(
                      icon: const BackButtonIcon(),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Center(
                        child: GlassGroupSwitcher(
                          index: _index,
                          labels: const ["Comic Sources", "Built-in proxy"],
                          onChanged: (i) => _tabs.animateTo(i),
                        ),
                      ),
                    ),
                    // 和左边的返回键等宽，分段控件才是真正居中的。
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: colors.outlineVariant.withValues(alpha: 0.4),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: const [
                    ComicSourcePage(embedded: true),
                    XrayProxyBody(),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
