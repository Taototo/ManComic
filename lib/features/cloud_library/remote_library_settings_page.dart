import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/features/cloud_library/remote_library_engine.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';
import 'package:venera/pages/cloud/cloud_comics_page.dart';
import 'package:venera/pages/cloud/storage.dart';

final _storage = RemoteStorageAccounts.instance;

bool _isPageTitleUsedElsewhere(String title, RemoteLibrary library) =>
    _storage.libraries.any(
      (item) => item.id != library.id && item.name == title,
    ) ||
    ComicSourceManager().all().any(
      (source) =>
          source.key != library.sourceKey &&
          source.explorePages.any((page) => page.title == title),
    );

List<String> _explorePages() =>
    (appdata.settings['explore_pages'] as List? ?? const [])
        .whereType<String>()
        .toList();

void _updatePageVisibility(RemoteLibrary library, RemoteLibrary? previous) {
  final pages = _explorePages();
  if (previous == null) {
    if (!pages.contains(library.name)) pages.add(library.name);
    appdata.settings['explore_pages'] = pages;
    return;
  }
  if (previous.name == library.name || !pages.contains(previous.name)) return;
  final index = pages.indexOf(previous.name);
  final oldTitleIsShared = _isPageTitleUsedElsewhere(previous.name, previous);
  final newTitleIsEnabled = pages.contains(library.name);
  if (!newTitleIsEnabled) {
    if (oldTitleIsShared) {
      pages.insert(index, library.name);
    } else {
      pages[index] = library.name;
    }
  } else if (!oldTitleIsShared) {
    pages.removeAt(index);
  }
  appdata.settings['explore_pages'] = pages;
}

void _removePageVisibility(RemoteLibrary library) {
  for (final setting in ['searchSources', 'disabledLibrarySearchSources']) {
    final keys = appdata.settings[setting] as List?;
    if (keys != null && keys.contains(library.sourceKey)) {
      appdata.settings[setting] = keys
          .where((key) => key != library.sourceKey)
          .toList();
    }
  }
  if (_isPageTitleUsedElsewhere(library.name, library)) return;
  final pages = _explorePages()..removeWhere((item) => item == library.name);
  appdata.settings['explore_pages'] = pages;
}

Future<void> showRemoteLibraryEditor(
  BuildContext context, {
  RemoteLibrary? initial,
  String? initialAccountId,
}) async {
  var name = initial?.name ?? '';
  final existingAccount = initial == null
      ? null
      : _storage.account(initial.accountId);
  StorageAccount? account =
      existingAccount ??
      (initial == null
          ? _storage.account(initialAccountId ?? '') ??
                _storage.accounts.firstOrNull
          : null);
  var directories = initial?.directories ?? const <String>[];
  var autoRefresh =
      initial?.autoRefresh ?? RemoteLibrary.defaultAutoRefresh(account);
  var autoRefreshChosen = initial != null;
  var refreshIntervalMinutes = initial?.refreshIntervalMinutes ?? 360;
  final result = await showDialog<RemoteLibrary>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => ContentDialog(
        title: initial == null
            ? '添加漫画库'
            : '编辑漫画库',
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: name,
                onChanged: (value) => name = value,
                decoration: InputDecoration(labelText: '名称'),
              ),
              RemoteLocationFields(
                accountId: account?.id ?? initial?.accountId,
                directories: directories,
                multiSelect: true,
                accountLocked: initial != null,
                onChanged: (value, selected) => setDialogState(() {
                  account = value;
                  directories = selected;
                  if (!autoRefreshChosen) {
                    autoRefresh = RemoteLibrary.defaultAutoRefresh(value);
                  }
                }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('自动更新漫画库'),
                value: autoRefresh,
                onChanged: (value) => setDialogState(() {
                  autoRefresh = value;
                  autoRefreshChosen = true;
                }),
              ),
              if (autoRefresh)
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: refreshIntervalMinutes,
                  decoration: InputDecoration(labelText: '更新间隔'),
                  items: [
                    DropdownMenuItem(
                      value: 15,
                      child: Text('每 15 分钟'),
                    ),
                    DropdownMenuItem(value: 60, child: Text('每小时')),
                    DropdownMenuItem(
                      value: 360,
                      child: Text('每 6 小时'),
                    ),
                    DropdownMenuItem(value: 1440, child: Text('每天')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => refreshIntervalMinutes = value);
                    }
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: actionButtonStyle,
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () {
              final trimmed = name.trim();
              if (trimmed.isEmpty || directories.isEmpty || account == null) {
                return;
              }
              final library = initial == null
                  ? RemoteComicLibraryRegistry.create(
                      accountId: account!.id,
                      directories: directories,
                      name: trimmed,
                    ).copyWith(
                      autoRefresh: autoRefresh,
                      refreshIntervalMinutes: refreshIntervalMinutes,
                    )
                  : initial.copyWith(
                      name: trimmed,
                      directories: directories,
                      autoRefresh: autoRefresh,
                      refreshIntervalMinutes: refreshIntervalMinutes,
                    );
              Navigator.pop(context, library);
            },
            child: Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (result == null) return;
  _updatePageVisibility(result, initial);
  await _storage.saveLibrary(result);
}

class RemoteLibrariesSliver extends StatefulWidget {
  const RemoteLibrariesSliver({super.key});

  @override
  State<RemoteLibrariesSliver> createState() => _RemoteLibrariesSliverState();
}

class _RemoteLibrariesSliverState extends State<RemoteLibrariesSliver> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _storage,
      builder: (context, _) {
        final libraries = _storage.libraries;
        if (libraries.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('暂无在线漫画库'),
            ),
          );
        }
        return SliverList.builder(
          itemCount: libraries.length,
          itemBuilder: (context, index) {
            final library = libraries[index];
            final account = _storage.account(library.accountId);
            final engine = RemoteLibraryEngines.find(library.sourceKey);
            final failures = engine?.failedRoots ?? const <String, String>{};
            return ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(library.name),
              subtitle: Text(
                '${account?.name ?? library.accountId}\n'
                '${library.directories.join('\n')}'
                '${failures.isEmpty ? '' : '\n${'失败'}: ${failures.keys.join(', ')}'}',
              ),
              isThreeLine:
                  library.directories.length > 1 || failures.isNotEmpty,
              onTap: () => context.to(() => CloudComicsPage(library: library)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh),
                    onPressed: engine == null
                        ? null
                        : () async {
                            await engine.synchronize(force: true);
                            if (mounted) setState(() {});
                          },
                  ),
                  IconButton(
                    tooltip: '设置',
                    icon: const Icon(Icons.tune),
                    onPressed: () =>
                        showRemoteLibraryEditor(context, initial: library),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      _removePageVisibility(library);
                      await _storage.removeLibrary(library.id);
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
