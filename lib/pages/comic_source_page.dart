import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_health.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_help_page.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    if (!source.url.isURL) {
      if (showLoading) {
        App.rootContext.showMessage(message: "Invalid url config".tl);
        return;
      } else {
        throw Exception("Invalid url config");
      }
    }
    ComicSourceManager().remove(source.key);
    bool cancel = false;
    LoadingDialogController? controller;
    if (showLoading) {
      controller = showLoadingDialog(
        App.rootContext,
        onCancel: () => cancel = true,
        barrierDismissible: false,
      );
    }
    try {
      var res = await AppDio().get<String>(
        source.url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      controller?.close();
      await ComicSourceParser().parse(res.data!, source.filePath);
      await io.File(source.filePath).writeAsString(res.data!);
      if (ComicSourceManager().availableUpdates.containsKey(source.key)) {
        ComicSourceManager().availableUpdates.remove(source.key);
      }
    } catch (e) {
      if (cancel) return;
      if (showLoading) {
        App.rootContext.showMessage(message: e.toString());
      } else {
        rethrow;
      }
    }
    // 源文件换了，之前的探测结果（延迟、返回条数）已经不能代表新版本，
    // 留着会让卡片上挂一个和实际对不上的分数。
    SourceHealthService.instance.forget(source.key);
    await ComicSourceManager().reload();
    if (showLoading) {
      App.forceRebuild();
    }
  }

  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    var dio = AppDio();
    var res = await dio.get<String>(appdata.settings['comicSourceListUrl']);
    if (res.statusCode != 200) {
      return -1;
    }
    var list = jsonDecode(res.data!) as List;
    var versions = <String, String>{};
    for (var source in list) {
      versions[source['key']] = source['version'];
    }
    var shouldUpdate = <String>[];
    for (var source in ComicSource.all()) {
      if (versions.containsKey(source.key) &&
          compareSemVer(versions[source.key]!, source.version)) {
        shouldUpdate.add(source.key);
      }
    }
    if (shouldUpdate.isNotEmpty) {
      var updates = <String, String>{};
      for (var key in shouldUpdate) {
        updates[key] = versions[key]!;
      }
      ComicSourceManager().updateAvailableUpdates(updates);
    }
    return shouldUpdate.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var url = "";

  final _health = SourceHealthService.instance;

  void updateUI() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
    _health.addListener(updateUI);
    // 只补测没有结果的源，所以在这个页面里来回切不会又跑一遍。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _health.testAll(ComicSource.all());
    });
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(updateUI);
    _health.removeListener(updateUI);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = ComicSource.all();
    return Stack(
      children: [
        const GlassPageBackdrop(),
        SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              title: Text('Comic Source'.tl),
              actions: [
                // 体检页已经并进来了，全源重测就放在这颗按钮上。
                // 单个源还是点那一行（见列表）。
                IconButton(
                  tooltip: "Test again".tl,
                  icon: _health.running
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: _health.running
                      ? null
                      : () => _health.testAll(sources, force: true),
                ),
              ],
            ),
            SliverToBoxAdapter(child: _buildAddCard(context)),
            if (sources.isEmpty)
              SliverToBoxAdapter(child: _buildEmpty(context))
            else ...[
              SliverToBoxAdapter(child: _buildListHeader(context, sources)),
              // 所有源收在一张卡里，行与行之间用分隔线切开。
              //
              // 原来每个源是一张独立的玻璃卡：八个源就是八层模糊、八个圆角、
              // 八次阴影，滚动时每帧都在重算；而且卡与卡之间的空隙让「一共
              // 有几个源、几个挂了」这件事散了。单个源一行读起来就是
              // 一张表，逐行对比健康状态快得多。
              SliverToBoxAdapter(child: _buildSourceList(context, sources)),
            ],
            SliverPadding(
              padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildListHeader(BuildContext context, List<ComicSource> sources) {
    final colors = context.colorScheme;
    final items = sources.map(_health.of).toList();
    final healthy =
        items.where((e) => e.status == SourceHealthStatus.ok).length;
    final failed =
        items.where((e) => e.status == SourceHealthStatus.error).length;
    final tested = items.where((e) => e.tested).length;
    final updating = _health.running;
    final avg = _averageLatency(items);
    String text;
    if (tested == 0) {
      text = updating
          ? "Testing source status".tl
          : "@a sources".tlParams({"a": sources.length});
    } else {
      text = "@a sources · @b available".tlParams({
        "a": sources.length,
        "b": healthy,
      });
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 一行里塞了源数、可用数、失败数和平均延迟，窄屏放不下。
              // 左边整体省略，别让 Row 溢出——测试里 360 宽就是这种屏。
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: text),
                      if (failed > 0)
                        TextSpan(
                          text: " · "
                              "${"@n failed".tlParams({"n": failed})}",
                          style: TextStyle(color: colors.error),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts.s12.withColor(colors.onSurfaceVariant),
                ),
              ),
              // 平均延迟只在有「通了的源」时才有意义，跟着可用数一起看。
              if (avg != null)
                Text(
                  "${avg}ms",
                  style: ts.s10.withColor(
                    colors.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
              if (updating) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          // 行本身现在就是体检入口，这个动作没有可见的按钮，必须写出来，
          // 否则用户只会发现「点一下怎么转圈了」。
          const SizedBox(height: 3),
          Text(
            "Tap a row to retest".tl,
            style: ts.s10.withColor(
              colors.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }

  /// 体检页并进来时一起搬过来的平均延迟：只看「测通了」的源，
  /// 失败源的耗时没有参考价值（都挂在超时上）。
  int? _averageLatency(List<SourceHealth> items) {
    final latencies = items
        .where((e) => e.status == SourceHealthStatus.ok && e.latency != null)
        .map((e) => e.latency!)
        .toList();
    if (latencies.isEmpty) {
      return null;
    }
    return latencies.reduce((a, b) => a + b) ~/ latencies.length;
  }

  /// 一页源 = 一张卡 + 每行一个源。
  ///
  /// 行的信息密度按体检页来排：左边状态圆点、中间名字与「版本 · 能力」两行，
  /// 右边分数、状态词和进详情的箭头。分数和状态词同时保留——分数用来横向
  /// 比较，状态词用来一眼判断好与不好。
  Widget _buildSourceList(BuildContext context, List<ComicSource> sources) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(22),
        blur: math.min(GlassConfig.blur, 18.0),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < sources.length; i++)
                _SourceRow(
                  key: ValueKey(sources[i].key),
                  source: sources[i],
                  health: _health.of(sources[i]),
                  newVersion: _updateOf(sources[i]),
                  showDivider: i != sources.length - 1,
                  onOpenDetail: () => _openDetail(sources[i]),
                  // 和体检页同一个动作：点一下就把这一个源重测一遍。
                  onRetest: () => _health.testOne(_health.of(sources[i])),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 有比本地更新、且确实更晚的版本才返回，否则 [String]? 为空。
  String? _updateOf(ComicSource source) {
    final newVersion = ComicSourceManager().availableUpdates[source.key];
    if (newVersion != null && compareSemVer(newVersion, source.version)) {
      return newVersion;
    }
    return null;
  }

  Widget _buildEmpty(BuildContext context) {    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(22),
        blur: 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
          child: Column(
            children: [
              Icon(
                Icons.extension_outlined,
                size: 34,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text("No comic source".tl, style: ts.s14),
              const SizedBox(height: 4),
              Text(
                "Fill in a source URL above, or import a .js config file".tl,
                textAlign: TextAlign.center,
                style: ts.s12.withColor(colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddCard(BuildContext context) {
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(24),
        blur: 18,
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.add_circle_outline,
                      size: 18,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "Add comic source".tl,
                      style: ts.s14.merge(
                        const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('source-url-field'),
                        style: ts.s14,
                        decoration: InputDecoration(
                          hintText: "Paste a source URL".tl,
                          hintStyle: ts.s14.withColor(
                            colors.onSurfaceVariant.withValues(alpha: 0.75),
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: colors.onSurface.withValues(alpha: 0.05),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (value) {
                          url = value;
                        },
                        onSubmitted: handleAddSource,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SubmitButton(onTap: () => handleAddSource(url)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _AddAction(
                      icon: Icons.article_outlined,
                      label: "Source list".tl,
                      onTap: () {
                        showPopUpWidget(
                          App.rootContext,
                          _ComicSourceList(handleAddSource),
                        );
                      },
                    ),
                    _AddAction(
                      icon: Icons.file_open_outlined,
                      label: "Config file".tl,
                      onTap: _selectFile,
                    ),
                    _AddAction(
                      icon: Icons.help_outline_rounded,
                      label: "Help".tl,
                      onTap: help,
                    ),
                    _AddAction(
                      icon: Icons.system_update_alt_rounded,
                      label: "Check updates".tl,
                      onTap: () async {
                        await showDialog(
                          context: context,
                          builder: (_) => const _CheckUpdatesDialog(),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openDetail(ComicSource source) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (_) => _SourceDetailSheet(
        source: source,
        onUpdate: (s) => update(s),
        onEdit: edit,
        onDelete: delete,
      ),
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        var file = File(source.filePath);
        file.delete();
        ComicSourceManager().remove(source.key);
        SourceHealthService.instance.forget(source.key);
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        await Process.run("code", [source.filePath], runInShell: true);
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: Text("Reload Configs".tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text("Cancel".tl),
              ),
              TextButton(
                onPressed: () async {
                  await ComicSourceManager().reload();
                  App.forceRebuild();
                },
                child: Text("Continue".tl),
              ),
            ],
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    context.to(
      () => _EditFilePage(source.filePath, () async {
        await ComicSourceManager().reload();
        setState(() {});
      }),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    context.to(() => const ComicSourceHelpPage());
  }

  Future<void> handleAddSource(String url) async {
    if (url.isEmpty) {
      return;
    }
    var splits = url.split("/");
    splits.removeWhere((element) => element == "");
    var fileName = splits.last;
    bool cancel = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () => cancel = true,
      barrierDismissible: false,
    );
    try {
      var res = await AppDio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      controller.close();
      await addSource(res.data!, fileName);
    } catch (e, s) {
      if (cancel) return;
      context.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  Future<void> addSource(String js, String fileName) async {
    var comicSource = await ComicSourceParser().createAndParse(js, fileName);
    ComicSourceManager().add(comicSource);
    _addAllPagesWithComicSource(comicSource);
    appdata.saveData();
    App.forceRebuild();
  }
}

/// 添加源卡片里的提交按钮，提交时给一点视觉反馈（源文件可能要下载一会儿）。
class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: colors.primary,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Icon(Icons.arrow_forward_rounded,
              size: 20, color: colors.onPrimary),
        ),
      ),
    );
  }
}

/// 卡片底部的四个图标操作：竖排图标 + 短标签，比横排按钮省宽度。
class _AddAction extends StatelessWidget {
  const _AddAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;

  final String label;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: colors.primary),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s10.withColor(colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// 健康分环形进度。没测过时画一圈淡底轨并显示「—」，
/// 而不是画一个 0 分的空环——「没测」和「测出 0 分」得能区分开。
class _HealthRing extends StatelessWidget {
  const _HealthRing({
    required this.health,
    required this.color,
    this.size = 40,
  });

  final SourceHealth health;

  final Color color;

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final score = health.score;
    final active = score != null;
    final ringColor = active ? color : colors.onSurfaceVariant;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          ratio: active ? health.ratio : 0,
          color: ringColor,
          trackAlpha: active ? 0.18 : 0.12,
          strokeWidth: size * 0.075,
        ),
        child: Center(
          child: health.status == SourceHealthStatus.testing
              ? SizedBox(
                  width: size * 0.36,
                  height: size * 0.36,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: ringColor,
                  ),
                )
              : Text(
                  active ? "$score" : "—",
                  style: TextStyle(
                    // 100 是三位数，字号再大就在环里顶满了
                    fontSize: size * 0.30,
                    height: 1.0,
                    fontWeight: FontWeight.w600,
                    color: ringColor,
                  ),
                ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.ratio,
    required this.color,
    required this.trackAlpha,
    required this.strokeWidth,
  });

  final double ratio;

  final Color color;

  final double trackAlpha;

  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color.withValues(alpha: trackAlpha);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2, false, track);
    if (ratio <= 0) {
      return;
    }
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * ratio.clamp(0.0, 1.0),
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.ratio != ratio ||
      old.color != color ||
      old.trackAlpha != trackAlpha ||
      old.strokeWidth != strokeWidth;
}

/// 一个源 = 一行，版式和原来的体检表完全对齐。
///
/// 左边那个状态圆点替掉了原来的首字头像：八个源竖排下来，八个小圆点连成
/// 一条颜色带，哪几个挂了扫一眼就能看出来；而「每个源一种彩色方块」其实
/// 不携带任何信息——名字就写在旁边，颜色只是让眼睛多跳一次。
///
/// 体检功能直接搬到了行上：点行 = 重测这一个源，进详情改
/// 由右侧箭头负责。重测是高频动作，进详情是低频动作，不该抢同一个手势。
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.source,
    required this.health,
    required this.onOpenDetail,
    required this.onRetest,
    required this.showDivider,
    this.newVersion,
  });

  final ComicSource source;

  final SourceHealth health;

  /// 有可更新的版本时为非空
  final String? newVersion;

  /// 打开源详情面板
  final VoidCallback onOpenDetail;

  /// 重新体检这个源
  final VoidCallback onRetest;

  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final statusColor = _sourceHealthColor(colors, health.status);
    final testing = health.status == SourceHealthStatus.testing;
    final score = health.score;
    return InkWell(
      onTap: testing ? null : onRetest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 4, 11),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              source.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts.s14.merge(
                                const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          if (newVersion != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                "Update".tl,
                                style: ts.s8.withColor(colors.primary),
                              ),
                            ),
                          ],
                          if (source.isLogged) ...[
                            const SizedBox(width: 5),
                            Icon(
                              Icons.verified_user_outlined,
                              size: 12,
                              color: colors.primary.withValues(alpha: 0.75),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _sourceMetaLine(source),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s10.withColor(colors.onSurfaceVariant),
                      ),
                      // 出错时才多给一行：报错信息是「为什么不能用」的唯一
                      // 线索，其余状态不需要这一段，行高保持紧凑。
                      if (health.message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            health.message!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts.s10.withColor(statusColor),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // 分数：没测过显示「—」，测的过程中转圈。固定宽度让所有行的
                // 名字左边缘对齐——数字宽度一变，整列都会跟着抖。
                SizedBox(
                  width: 30,
                  height: 28,
                  child: Center(
                    child: testing
                        ? SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: statusColor,
                            ),
                          )
                        : Text(
                            score == null ? "—" : "$score",
                            style: ts.s14
                                .withColor(statusColor)
                                .merge(
                                  const TextStyle(fontWeight: FontWeight.w700),
                                ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                // 状态词长度不固定（「20 results」和「Search not supported」差
                // 三倍），必须给上限并允许省略，否则窄屏上整行会被它顶出去。
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 82),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      // 中性底色 + 彩色文字：分数本身已经是彩色的，标签再铺
                      // 一层同色底会在视觉上连成一块，两个信息看起来像一个。
                      color: colors.surfaceContainerHighest.withValues(
                        alpha: 0.7,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      health.statusText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s10.withColor(statusColor),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: "Details".tl,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(34, 34),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: colors.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  onPressed: onOpenDetail,
                ),
              ],
            ),
          ),
          if (showDivider)
            Container(
              height: 0.7,
              margin: const EdgeInsets.only(left: 36),
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
  }
}

Color _sourceHealthColor(ColorScheme colors, SourceHealthStatus status) {
  switch (status) {
    // 用 iOS 系统色，比 M3 的绿/橙更亮一档，和玻璃底色在一起更正。
    case SourceHealthStatus.ok:
      return const Color(0xFF34C759);
    case SourceHealthStatus.empty:
      return const Color(0xFFFF9F0A);
    case SourceHealthStatus.error:
      return colors.error;
    case SourceHealthStatus.testing:
      return colors.primary;
    case SourceHealthStatus.waiting:
    case SourceHealthStatus.unsupported:
      return colors.onSurfaceVariant;
  }
}

/// 副标题只放「版本 + 能力」。健康状态交给右边的分数和标签，不在这里重复。
String _sourceMetaLine(ComicSource source) {
  final parts = <String>["v${source.version}"];
  if (source.explorePages.isNotEmpty) {
    parts.add("${"Explore".tl} ${source.explorePages.length}");
  }
  if (source.categoryData != null) parts.add("Category".tl);
  if (source.searchPageData != null) parts.add("Search".tl);
  if (source.favoriteData != null) parts.add("Favorites".tl);
  if (source.account != null) parts.add("Login".tl);
  return parts.join(" · ");
}

/// 源详情面板：健康数据 + 操作 + 源自己的设置项 + 账号。
class _SourceDetailSheet extends StatefulWidget {
  const _SourceDetailSheet({
    required this.source,
    required this.onUpdate,
    required this.onEdit,
    required this.onDelete,
  });

  final ComicSource source;

  final void Function(ComicSource source) onUpdate;

  final void Function(ComicSource source) onEdit;

  final void Function(ComicSource source) onDelete;

  @override
  State<_SourceDetailSheet> createState() => _SourceDetailSheetState();
}

class _SourceDetailSheetState extends State<_SourceDetailSheet> {
  final _health = SourceHealthService.instance;

  /// 更新/编辑后源对象会被替换，读的时候始终取当前实例。
  ComicSource get source =>
      ComicSource.find(widget.source.key) ?? widget.source;

  SourceHealth get health => _health.of(source);

  final _reLogin = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _health.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _health.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final settings = buildSourceSettings().toList();
    final account = _buildAccount().toList();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 30,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: LiquidGlass(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          blur: 24,
          // 详情面板是一块「要读内容」的面板，不是浮在画面上的装饰：设置项、
          // 账号信息、错误消息全都写在上面。原来跟着全局玻璃浓度走（默认
          // 58%），底下的源列表和封面直接透上来，字压着图看不清。这里钉死
          // 到接近不透明，模糊只用来软化边缘。
          opacity: 0.95,
          shadow: false,
          // 内容少时贴合内容高度，别留一大片空白；超过 82% 才滚动。
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
                child: Row(
                  children: [
                    // 和列表行用同一颗状态点：从哪一行点进来，抬头就能对上。
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: _sourceHealthColor(colors, health.status),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts.s18.merge(
                              const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(height: 2),
                          // 版本号和源 key 都只作识别用，小一号、单行省略，
                          // 别让它们把标题挤成两行。
                          Text(
                            "v${source.version} · ${source.key}",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts.s10.withColor(colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom + 24,
                  ),
                  children: [
                    // 四块内容的间距按「同类紧、异类松」排：健康卡和操作按钮
                    // 是同一件事的两个面，贴得近；能力项是另一个维度；设置项
                    // 又要更多留白——间距本身就是分组信息。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: _buildHealthCard(context),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      child: _buildActions(context),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                      child: _buildCapabilities(context),
                    ),
                    // 没有设置项也没有账号时不留一个空的「设置」标题
                    if (settings.isNotEmpty || account.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 2, bottom: 8),
                              child: Text(
                                "Settings".tl,
                                style: ts.s12
                                    .merge(const TextStyle(
                                        fontWeight: FontWeight.w600))
                                    .withColor(colors.onSurfaceVariant),
                              ),
                            ),
                            _buildTilesGroup([...settings, ...account]),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 把源自己的设置项与账号信息收进一张卡里。
  ///
  /// 这些条目原来直接铺在 ListView 上：ListTile 自带 16px 内边距，而上面的
  /// 健康卡、能力 chips 都按 20px 外边距排，左边对不齐、右边还差 4px，滚动
  /// 时像两块拼起来的页面。收进卡片并把 contentPadding 统一到 14，整列就
  /// 站直了；分隔线用 14 的缩进跟着走。
  Widget _buildTilesGroup(List<Widget> children) {
    final colors = context.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(
          listTileTheme: const ListTileThemeData(
            dense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 14),
          ),
        ),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 0.7,
                  thickness: 0.7,
                  indent: 14,
                  endIndent: 14,
                  color: colors.outlineVariant.withValues(alpha: 0.4),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }

  /// 健康卡：一枚环形读数 + 三段文字（标题、等级、耗时/时间）。
  ///
  /// 原来没有标题，一进来就是「优秀 · 20 results」，看不出这块在说健康状态，
  /// 也不知道右上角那个刷新键是干嘛的。补一行小标题做锚点，整块的分工就清
  /// 楚了：左边读数、中间结论、右边重测。
  Widget _buildHealthCard(BuildContext context) {
    final colors = context.colorScheme;
    final statusColor = _sourceHealthColor(colors, health.status);
    final latency = health.latency;
    final checkedAt = health.checkedAt;
    final testing = health.status == SourceHealthStatus.testing;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HealthRing(health: health, color: statusColor, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Source health".tl,
                  style: ts.s10.withColor(
                    colors.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 3),
                // 等级和状态合成一段富文本，交给单个 Text 自己省略。
                // 之前是两个 Text 并排，没有任何弹性约束，等级词一长就整行溢出。
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: health.gradeText ?? health.statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (health.gradeText != null)
                        TextSpan(
                          text: " · ${health.statusText}",
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts.s14,
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (latency != null) "${latency}ms",
                    if (checkedAt != null) _formatTime(checkedAt),
                  ].join("  ·  "),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts.s10.withColor(colors.onSurfaceVariant),
                ),
                if (health.message != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    health.message!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s10.withColor(colors.error),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: "Test again".tl,
            style: IconButton.styleFrom(
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  )
                : const Icon(Icons.refresh_rounded, size: 20),
            onPressed: testing ? null : () => _health.testOne(health),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return "Just now".tl;
    if (diff.inMinutes < 60) {
      return "@a min ago".tlParams({"a": diff.inMinutes});
    }
    if (diff.inHours < 24) return "@a h ago".tlParams({"a": diff.inHours});
    return "@a d ago".tlParams({"a": diff.inDays});
  }

  Widget _buildActions(BuildContext context) {
    final colors = context.colorScheme;
    final newVersion = ComicSourceManager().availableUpdates[source.key];
    final canUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);
    return Row(
      children: [
        Expanded(
          child: _ActionTile(
            icon: Icons.system_update_alt_rounded,
            label: canUpdate ? "Update".tl : "Reinstall".tl,
            tint: colors.primary,
            onTap: () {
              Navigator.of(context).pop();
              widget.onUpdate(source);
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ActionTile(
            icon: Icons.edit_note_rounded,
            label: "Edit".tl,
            tint: colors.onSurface,
            onTap: () {
              Navigator.of(context).pop();
              widget.onEdit(source);
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ActionTile(
            icon: Icons.delete_outline_rounded,
            label: "Delete".tl,
            tint: colors.error,
            onTap: () {
              Navigator.of(context).pop();
              widget.onDelete(source);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCapabilities(BuildContext context) {
    final colors = context.colorScheme;
    final items = <(IconData, String)>[
      if (source.explorePages.isNotEmpty)
        (
          Icons.explore_outlined,
          "${"Explore".tl} ${source.explorePages.length}"
        ),
      if (source.categoryData != null) (Icons.category_outlined, "Category".tl),
      if (source.categoryComicsData != null)
        (Icons.sell_outlined, "Category comics".tl),
      if (source.searchPageData != null) (Icons.search_rounded, "Search".tl),
      if (source.favoriteData != null) (Icons.favorite_border, "Favorites".tl),
      if (source.commentsLoader != null) (Icons.forum_outlined, "Comments".tl),
      if (source.enableTagsSuggestions) (Icons.tag, "Tag suggestions".tl),
    ];
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        for (final item in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: colors.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.$1, size: 12, color: colors.onSurfaceVariant),
                const SizedBox(width: 5),
                Text(
                  item.$2,
                  style: ts.s10.withColor(colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key];
          if (current == null) {
            var d = item.value['default'];
            for (var option in item.value['options']) {
              if (option['value'] == d) {
                current = option['text'] ?? option['value'];
                break;
              }
            }
          } else {
            current = item.value['options'].firstWhere(
                  (e) => e['value'] == current,
                )['text'] ??
                current;
          }
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Select(
              current: (current as String).ts(source.key),
              values: (item.value['options'] as List)
                  .map<String>(
                    (e) => ((e['text'] ?? e['value']) as String).ts(source.key),
                  )
                  .toList(),
              onTap: (i) {
                source.data['settings'][key] =
                    item.value['options'][i]['value'];
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

/// 详情面板里的操作按钮（更新 / 编辑 / 删除）
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;

  final String label;

  final Color tint;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Material(
      color: tint.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: tint),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s12.withColor(
                  tint == colors.onSurface ? colors.onSurface : tint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.onAdd);

  final Future<void> Function(String) onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  List? json;
  bool changed = false;
  var controller = TextEditingController();

  void load() async {
    if (json != null) {
      setState(() {
        json = null;
      });
    }
    if (controller.text.isEmpty) {
      setState(() {
        json = [];
      });
      return;
    }
    var dio = AppDio();
    try {
      var res = await dio.get<String>(controller.text);
      if (res.statusCode != 200) {
        throw "error";
      }
      if (mounted) {
        setState(() {
          json = jsonDecode(res.data!);
        });
      }
    } catch (e) {
      context.showMessage(message: "Network error".tl);
      if (mounted) {
        setState(() {
          json = [];
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    controller.text = appdata.settings['comicSourceListUrl'];
    load();
  }

  @override
  void dispose() {
    super.dispose();
    if (changed) {
      appdata.settings['comicSourceListUrl'] = controller.text;
      appdata.saveData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(title: "Comic Source".tl, body: buildBody());
  }

  Widget buildBody() {
    var currentKey = ComicSource.all().map((e) => e.key).toList();

    return ListView.builder(
      itemCount: (json?.length ?? 1) + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.6,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: Icon(Icons.source_outlined),
                  title: Text("Repo URL".tl),
                ),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "URL",
                    border: const UnderlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onChanged: (value) {
                    changed = true;
                  },
                ).paddingHorizontal(16).paddingBottom(8),
                Text(
                  "The URL should point to a 'index.json' file".tl,
                ).paddingLeft(16),
                Text(
                  "Do not report any issues related to sources to App repo.".tl,
                ).paddingLeft(16),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        context.to(() => const ComicSourceHelpPage());
                      },
                      child: Text("Help".tl),
                    ),
                    FilledButton.tonal(
                      onPressed: load,
                      child: Text("Refresh".tl),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        }

        if (index == 1 && json == null) {
          return Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ).fixWidth(24).fixHeight(24),
          );
        }

        index--;

        var key = json![index]["key"];
        var action = currentKey.contains(key)
            ? const Icon(Icons.check, size: 20).paddingRight(8)
            : Button.filled(
                child: Text("Add".tl),
                onPressed: () async {
                  var fileName = json![index]["fileName"];
                  var url = json![index]["url"];
                  if (url == null || !(url.toString()).isURL) {
                    var listUrl =
                        appdata.settings['comicSourceListUrl'] as String;
                    if (listUrl
                        .replaceFirst("https://", "")
                        .replaceFirst("http://", "")
                        .contains("/")) {
                      url = listUrl.substring(0, listUrl.lastIndexOf("/") + 1) +
                          fileName;
                    } else {
                      url = '$listUrl/$fileName';
                    }
                  }
                  await widget.onAdd(url);
                  setState(() {});
                },
              ).fixHeight(32);

        var description = json![index]["version"];
        if (json![index]["description"] != null) {
          description = "$description\n${json![index]["description"]}";
        }

        return ListTile(
          title: Text(json![index]["name"]),
          subtitle: Text(description),
          trailing: action,
        );
      },
    );
  }
}

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings['explore_pages'];
  var categoryPages = appdata.settings['categories'];
  var networkFavorites = appdata.settings['favorites'];
  var searchPages = appdata.settings['searchSources'];

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveData();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「检查更新」的入口按钮做成了对话框，避免和卡片里的其它按钮混在一起。
class _CheckUpdatesDialog extends StatefulWidget {
  const _CheckUpdatesDialog();

  @override
  State<_CheckUpdatesDialog> createState() => _CheckUpdatesDialogState();
}

class _CheckUpdatesDialogState extends State<_CheckUpdatesDialog> {
  bool isLoading = true;

  String? message;

  /// 检查完发现的可更新项
  Map<String, String> updates = {};

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final count = await ComicSourcePage.checkComicSourceUpdate();
    if (!mounted) return;
    if (count == -1) {
      setState(() {
        isLoading = false;
        message = "Network error".tl;
      });
    } else if (count == 0) {
      setState(() {
        isLoading = false;
        message = "No updates".tl;
      });
    } else {
      setState(() {
        isLoading = false;
        updates = ComicSourceManager().availableUpdates;
      });
    }
  }

  Future<void> _doUpdate() async {
    final keys = updates.keys.toList();
    final loading = showLoadingDialog(
      context,
      message: "Updating".tl,
      withProgress: true,
    );
    try {
      for (var i = 0; i < keys.length; i++) {
        final source = ComicSource.find(keys[i]);
        if (source != null) {
          await ComicSourcePage.update(source, false);
        }
        loading.setProgress((i + 1) / keys.length);
      }
    } catch (e) {
      context.showMessage(message: e.toString());
    }
    loading.close();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return ContentDialog(
      title: "Check updates".tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : message != null
                ? Text(message!, style: ts.s14)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "@a sources has new version"
                            .tlParams({"a": updates.length}),
                        style: ts.s14,
                      ),
                      const SizedBox(height: 8),
                      for (final entry in updates.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            "${ComicSource.find(entry.key)?.name ?? entry.key}"
                            "  →  ${entry.value}",
                            style: ts.s12.withColor(colors.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
      ),
      actions: [
        if (updates.isNotEmpty)
          FilledButton(onPressed: _doUpdate, child: Text("Update".tl)),
      ],
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies =
          widget.config.cookieFields!.map((e) => _cookies[e] ?? '').toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success) {
        widget.source.data['account'] = 'ok';
        widget.source.saveData();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
