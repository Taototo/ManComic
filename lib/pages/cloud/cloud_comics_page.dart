import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/features/cloud_backup/backup_task_queue.dart';
import 'package:venera/features/cloud_library/remote_library_engine.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/cloud_storage/models.dart';
import 'package:venera/pages/cloud/storage.dart';
import 'package:venera/utils/cloud_bootstrap.dart';

/// 浏览一个网盘漫画库：封面网格 + 搜索，点开直接读。
///
/// 之前网盘里的漫画只能从「发现」页那个自动生成的页签进，页签没登记就完全
/// 找不到入口，用户根本不知道库在哪。这个页面把「选一本读」这件事做成独立
/// 入口，网盘页、备份页都能直接到这里。
class CloudComicsPage extends StatefulWidget {
  const CloudComicsPage({super.key, required this.library});

  final RemoteLibrary library;

  @override
  State<CloudComicsPage> createState() => _CloudComicsPageState();
}

class _CloudComicsPageState extends State<CloudComicsPage> {
  RemoteLibraryEngine? _engine;
  List<Comic> _comics = const [];
  String _keyword = '';
  int _page = 0;
  int _maxPage = 1;
  bool _loading = false;
  bool _initializing = true;
  String? _error;

  bool _queueWasBusy = false;

  @override
  void initState() {
    super.initState();
    _queueWasBusy = ArchiveTaskQueue.instance.isBusy;
    ArchiveTaskQueue.instance.addListener(_onQueueChanged);
    unawaited(_bind());
  }

  /// 后台上传结束后自动同步一次：用户可能刚传完就在这个页面等着看。
  void _onQueueChanged() {
    final busy = ArchiveTaskQueue.instance.isBusy;
    final finished = _queueWasBusy && !busy;
    _queueWasBusy = busy;
    if (finished) unawaited(_refresh());
  }

  @override
  void dispose() {
    ArchiveTaskQueue.instance.removeListener(_onQueueChanged);
    super.dispose();
  }

  Future<void> _bind() async {
    var engine = RemoteLibraryEngines.find(widget.library.sourceKey);
    if (engine == null) {
      // 源还没装配好（冷启动刚进来、或刚建库）：先让 bootstrap 装配一次。
      await CloudBootstrap.refresh();
      engine = RemoteLibraryEngines.find(widget.library.sourceKey);
    }
    if (!mounted) return;
    if (engine == null) {
      setState(() {
        _initializing = false;
        _error = '漫画库还没准备好，请确认网盘账号仍然可用后重试';
      });
      return;
    }
    setState(() => _engine = engine);
    await _load(reset: true);
    if (mounted) setState(() => _initializing = false);
  }

  Future<void> _load({bool reset = false}) async {
    final engine = _engine;
    if (engine == null || _loading) return;
    final target = reset ? 1 : _page + 1;
    if (target > _maxPage) return;
    setState(() {
      _loading = true;
      if (reset) _error = null;
    });
    try {
      final res = await engine.loadComics(target, keyword: _keyword);
      if (!mounted) return;
      if (res.error) {
        setState(() {
          _error = res.errorMessage;
          _loading = false;
        });
        return;
      }
      final pages = (res.subData as num?)?.toInt() ?? target;
      setState(() {
        _comics = reset ? res.data : [..._comics, ...res.data];
        _page = target;
        _maxPage = pages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    final engine = _engine;
    if (engine == null || _loading) return;
    setState(() => _loading = true);
    try {
      await engine.synchronize(force: true);
    } catch (_) {
      // 同步失败也要把已有索引读出来，错误会在列表里体现。
    }
    if (!mounted) return;
    setState(() => _loading = false);
    await _load(reset: true);
  }

  Future<void> _search() async {
    var text = _keyword;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: '搜索漫画',
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextFormField(
            autofocus: true,
            initialValue: text,
            decoration: const InputDecoration(
              labelText: '标题关键词',
              hintText: '留空显示全部',
            ),
            onChanged: (v) => text = v,
            onFieldSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(''),
            child: const Text('清除'),
          ),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () => Navigator.of(dialogContext).pop(text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    setState(() {
      _keyword = value.trim();
      _comics = const [];
      _page = 0;
      _maxPage = 1;
    });
    await _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final statusListenable = engine?.syncStatus;
    return Scaffold(
      appBar: Appbar(
        title: Text(widget.library.name),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: _search,
          ),
          IconButton(
            tooltip: '重新扫描',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: SmoothCustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(statusListenable)),
          if (_initializing)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_comics.isEmpty && _error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildError(_error!),
            )
          else if (_comics.isEmpty && !_loading)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildEmpty(),
            )
          else
            SliverGridComics(
              comics: _comics,
              onLastItemBuild: () {
                if (_page < _maxPage && !_loading) unawaited(_load());
              },
            ),
          if (_loading && _comics.isNotEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildHeader(ValueListenable<RemoteLibrarySyncStatus>? status) {
    final paths = widget.library.directories.join('\n');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paths.isEmpty ? '全部目录' : '目录：$paths',
            style: const TextStyle(fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (_keyword.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '搜索：$_keyword',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (status != null)
            ValueListenableBuilder<RemoteLibrarySyncStatus>(
              valueListenable: status,
              builder: (context, sync, _) {
                if (!sync.isSyncing) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    sync.total > 0
                        ? '正在扫描网盘：${sync.processed} / ${sync.total}'
                        : '正在扫描网盘…',
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              },
            ),
          if (_loading && _comics.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Button.outlined(
                  onPressed: () => App.rootContext.to(() => StorageAccountsPage()),
                  child: const Text('检查网盘账号'),
                ),
                const SizedBox(width: 12),
                Button.filled(
                  onPressed: () => _load(reset: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open_outlined, size: 40),
            const SizedBox(height: 12),
            Text(
              _keyword.isEmpty
                  ? '这个目录里还没有可阅读的漫画。\n把 CBZ 传到这个目录，或在「资源上载 → 漫画备份」里上传本地漫画。'
                  : '没有匹配「$_keyword」的漫画',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Button.outlined(
              onPressed: _refresh,
              child: const Text('重新扫描'),
            ),
          ],
        ),
      ),
    );
  }
}
