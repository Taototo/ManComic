import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/home_modules.dart';
import 'package:venera/utils/translations.dart';

/// 首页模块自定义：拖动排序 + 开关显隐。
class HomeModulesPage extends StatefulWidget {
  const HomeModulesPage({super.key});

  @override
  State<HomeModulesPage> createState() => _HomeModulesPageState();
}

class _HomeModulesPageState extends State<HomeModulesPage> {
  late List<String> _order;

  late Set<String> _enabled;

  @override
  void initState() {
    super.initState();
    // 保证 order 里包含全部模块（含还没配置过的新模块）
    _order = HomeModules.order.toList();
    for (final def in HomeModules.definitions) {
      if (!_order.contains(def.id)) {
        _order.add(def.id);
      }
    }
    _enabled = HomeModules.enabledIds;
    super.initState();
  }

  void _save() {
    HomeModules.save(_order, _enabled);
    App.forceRebuild();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text("Home Modules".tl),
            actions: [
              IconButton(
                tooltip: "Reset".tl,
                icon: const Icon(Icons.restart_alt),
                onPressed: () {
                  setState(() {
                    _order = HomeModules.definitions.map((e) => e.id).toList();
                    _enabled = HomeModules.definitions.map((e) => e.id).toSet();
                  });
                  _save();
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                "Drag to reorder, switch off to hide a section on the home page."
                    .tl,
                style: ts.s12.withColor(colors.onSurfaceVariant),
              ),
            ),
          ),
          SliverReorderableList(
            itemCount: _order.length,
            onReorderItem: (oldIndex, newIndex) {
              setState(() {
                final id = _order.removeAt(oldIndex);
                _order.insert(newIndex, id);
              });
              _save();
            },
            itemBuilder: (context, index) {
              final id = _order[index];
              final def = HomeModules.byId(id);
              if (def == null) {
                return SizedBox(key: ValueKey(id));
              }
              final on = _enabled.contains(id);
              return Material(
                key: ValueKey(id),
                color: Colors.transparent,
                child: ListTile(
                  leading: Icon(
                    def.icon,
                    color: on ? colors.primary : colors.onSurfaceVariant,
                  ),
                  title: Text(
                    def.title.tl,
                    style: ts.s14.withColor(
                      on ? colors.onSurface : colors.onSurfaceVariant,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: on,
                        onChanged: (value) {
                          setState(() {
                            if (value) {
                              _enabled.add(id);
                            } else {
                              _enabled.remove(id);
                            }
                          });
                          _save();
                        },
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: Icon(
                          Icons.drag_handle,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}
