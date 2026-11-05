import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/smart_shelf.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/title_sort.dart';
import 'package:venera/utils/translations.dart';

/// 智能书架：按标签规则自动生成的收藏视图。
class SmartShelfPage extends StatefulWidget {
  const SmartShelfPage({super.key});

  @override
  State<SmartShelfPage> createState() => _SmartShelfPageState();
}

class _SmartShelfPageState extends State<SmartShelfPage> {
  var shelves = <SmartShelf>[];

  int _selected = 0;

  List<FavoriteItem> comics = [];

  @override
  void initState() {
    super.initState();
    shelves = SmartShelfManager.list();
    _refresh();
  }

  void _refresh() {
    if (shelves.isEmpty) {
      comics = [];
      return;
    }
    if (_selected >= shelves.length) {
      _selected = shelves.length - 1;
    }
    comics = SmartShelfManager.comicsOf(shelves[_selected]);
  }

  Future<void> _edit([SmartShelf? shelf]) async {
    final result = await showDialog<SmartShelf>(
      context: context,
      builder: (_) => _ShelfEditor(shelf: shelf),
    );
    if (result == null) return;
    setState(() {
      if (shelf == null) {
        shelves.add(result);
        _selected = shelves.length - 1;
      } else {
        final index = shelves.indexOf(shelf);
        shelves[index] = result;
      }
      SmartShelfManager.save(shelves);
      _refresh();
    });
  }

  void _delete(SmartShelf shelf) {
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content: "Delete 智能书架 @n ?".tlParams({"n": shelf.name}),
      onConfirm: () {
        setState(() {
          shelves.remove(shelf);
          SmartShelfManager.save(shelves);
          _refresh();
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(
          title: Text("Smart shelf".tl),
          actions: [
            IconButton(
              tooltip: "New shelf".tl,
              icon: const Icon(Icons.add),
              onPressed: () => _edit(),
            ),
          ],
        ),
        if (shelves.isEmpty)
          SliverToBoxAdapter(child: _buildEmpty(colors))
        else ...[
          SliverToBoxAdapter(
            child: SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: shelves.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final shelf = shelves[index];
                  final active = index == _selected;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selected = index;
                        _refresh();
                      });
                    },
                    onLongPress: () => _delete(shelf),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: active
                            ? colors.primary.withValues(alpha: 0.16)
                            : colors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: active
                              ? colors.primary.withValues(alpha: 0.5)
                              : colors.outlineVariant.withValues(alpha: 0.4),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            shelf.name,
                            style: ts.s12.withColor(
                              active ? colors.primary : colors.onSurface,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.edit_outlined,
                            size: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Text(
                "${comics.length} 部作品".tl,
                style: ts.s10.withColor(colors.onSurfaceVariant),
              ),
            ),
          ),
          if (comics.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    "没有符合条件的收藏".tl,
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                  ),
                ),
              ),
            )
          else
            SliverGridComics(
              comics: comics,
              menuBuilder: (c) => [
                MenuEntry(
                  icon: Icons.edit_outlined,
                  text: "Edit shelf".tl,
                  onClick: () => _edit(shelves[_selected]),
                ),
                MenuEntry(
                  icon: Icons.delete_outline,
                  text: "Delete".tl,
                  color: colors.error,
                  isDanger: true,
                  onClick: () => _delete(shelves[_selected]),
                ),
              ],
            ),
        ],
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  Widget _buildEmpty(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        children: [
          Icon(
            Icons.auto_awesome_motion_outlined,
            size: 44,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            "用标签规则自动整理收藏，例如「连载中 + 百合」".tl,
            textAlign: TextAlign.center,
            style: ts.s12.withColor(colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: Text("New shelf".tl),
          ),
        ],
      ),
    );
  }
}

class _ShelfEditor extends StatefulWidget {
  const _ShelfEditor({this.shelf});

  final SmartShelf? shelf;

  @override
  State<_ShelfEditor> createState() => _ShelfEditorState();
}

class _ShelfEditorState extends State<_ShelfEditor> {
  late final TextEditingController _name;

  late final Set<String> _tags;

  late String _sort;

  late final List<String> _allTags;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.shelf?.name ?? '');
    _tags = {...?widget.shelf?.tags};
    _sort = widget.shelf?.sort ?? titleSortDefault;
    _allTags = SmartShelfManager.allTags();
    for (final tag in _tags) {
      if (!_allTags.contains(tag)) {
        _allTags.insert(0, tag);
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return AlertDialog(
      title: Text(widget.shelf == null ? "New shelf".tl : "Edit shelf".tl),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: "Name".tl,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),
              Text("Tags (all required)".tl, style: ts.s12),
              const SizedBox(height: 6),
              if (_allTags.isEmpty)
                Text(
                  "收藏里还没有标签".tl,
                  style: ts.s10.withColor(colors.onSurfaceVariant),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _allTags.map((tag) {
                        final selected = _tags.contains(tag);
                        return FilterChip(
                          label: Text(tag, style: ts.s10),
                          selected: selected,
                          onSelected: (value) {
                            setState(() {
                              if (value) {
                                _tags.add(tag);
                              } else {
                                _tags.remove(tag);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              Text("Sort".tl, style: ts.s12),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final entry in {
                    titleSortDefault: "Default".tl,
                    titleSortAZ: "Name A-Z".tl,
                    titleSortZA: "Name Z-A".tl,
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value, style: ts.s10),
                      selected: _sort == entry.key,
                      onSelected: (_) {
                        setState(() {
                          _sort = entry.key;
                        });
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("Cancel".tl),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(
              SmartShelf(name: name, tags: _tags.toList(), sort: _sort),
            );
          },
          child: Text("Save".tl),
        ),
      ],
    );
  }
}
