import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/random_pick.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/translations.dart';

const _folderSettingKey = 'randomPickFolder';
const _scopeSettingKey = 'randomPickScope';

/// 抽一本：从收藏夹里等概率抽一本，本轮不重复。
///
/// 返回抽中的那本（用户点「读这本」时），由调用方负责打开详情页——这个
/// 弹窗不应该知道详情页怎么跳，否则它会被绑死在导航上。
Future<FavoriteItem?> showRandomPickDialog(BuildContext context) {
  return showDialog<FavoriteItem>(
    context: context,
    builder: (_) => const RandomPickDialog(),
  );
}

class RandomPickDialog extends StatefulWidget {
  const RandomPickDialog({super.key});

  @override
  State<RandomPickDialog> createState() => _RandomPickDialogState();
}

class _RandomPickDialogState extends State<RandomPickDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;

  /// 本轮已经抽到过的书，用来保证「这一轮不重复」
  final Set<String> _drawn = {};

  List<FavoriteItem> _loaded = const [];

  List<FavoriteItem> _candidates = const [];

  List<String> _folders = const [];

  String? _folder;

  RandomPickScope _scope = RandomPickScope.all;

  FavoriteItem? _picked;

  bool _loading = true;

  bool _preparing = false;

  /// 切换筛选时自增，丢弃晚到的加载结果
  int _generation = 0;

  bool get _busy => _preparing || _reveal.isAnimating;

  @override
  void initState() {
    super.initState();
    _restoreSelection();
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          // 翻牌落地时给一下触感，比纯视觉更容易感知到「抽完了」
          HapticFeedback.mediumImpact();
          setState(() {});
        }
      });
    _load();
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  void _restoreSelection() {
    final folder = appdata.implicitData[_folderSettingKey];
    _folder = folder is String && folder.isNotEmpty ? folder : null;
    _scope = randomPickScopeFromName(appdata.implicitData[_scopeSettingKey]);
  }

  void _persistSelection() {
    appdata.implicitData[_folderSettingKey] = _folder;
    appdata.implicitData[_scopeSettingKey] = _scope.name;
    appdata.writeImplicitData();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final manager = LocalFavoritesManager();
    // 收藏库还没初始化时不要炸：首启或数据库异常的情况下，弹窗应该退化成
    // 「没有可抽的书」，而不是把整个页面带崩。
    List<String> folders;
    try {
      folders = manager.folderNames;
    } catch (_) {
      folders = const [];
    }
    // 存下来的文件夹可能已经被删掉了，回落到「全部」
    if (_folder != null && !folders.contains(_folder)) {
      _folder = null;
      _persistSelection();
    }
    setState(() {
      _folders = folders;
      _loading = true;
      _picked = null;
      _drawn.clear();
      _reveal.reset();
    });
    List<FavoriteItem> comics;
    try {
      comics = _folder == null
          ? await manager.getAllComicsAsync()
          : await manager.getFolderComicsAsync(_folder!);
    } catch (_) {
      comics = const [];
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _loaded = comics;
      _loading = false;
      _applyScope(resetDraw: false);
    });
  }

  void _applyScope({bool resetDraw = true}) {
    _candidates = [
      for (final comic in _loaded)
        if (randomPickMatchesScope(_scope, _historyOf(comic))) comic,
    ];
    if (resetDraw) {
      _picked = null;
      _drawn.clear();
      _reveal.reset();
    }
  }

  History? _historyOf(FavoriteItem comic) {
    try {
      return HistoryManager().find(comic.id, comic.type);
    } catch (_) {
      return null;
    }
  }

  Future<void> _draw() async {
    if (_loading || _busy || _candidates.isEmpty) return;
    var comic = pickRandomComic(_candidates, excluded: _drawn);
    if (comic == null) {
      // 全抽过一遍了：清空记录，开始新的一轮，并告诉用户
      _drawn.clear();
      if (mounted) {
        context.showMessage(message: "A new draw round has started".tl);
      }
      comic = pickRandomComic(_candidates);
    }
    if (comic == null) return;

    HapticFeedback.selectionClick();

    final firstDraw = _picked == null;
    setState(() {
      _preparing = true;
      _picked = null;
      _reveal.reset();
    });

    // 先把封面解码好再翻牌：否则牌翻开的那一瞬间是一块空白，几毫秒后
    // 图片才跳出来。180ms 是「洗牌」的最短可观感时长。
    final provider = findImageProvider(comic);
    await Future.wait<void>([
      Future<void>.delayed(const Duration(milliseconds: 180)),
      if (provider != null)
        precacheImage(provider, context)
            .timeout(const Duration(seconds: 2))
            .catchError((_) {}),
    ]);
    if (!mounted) return;

    _drawn.add(randomPickIdentity(comic));
    _reveal.duration = Duration(milliseconds: firstDraw ? 900 : 550);
    setState(() {
      _picked = comic;
      _preparing = false;
    });
    if (MediaQuery.of(context).disableAnimations) {
      _reveal.value = 1;
    } else {
      _reveal.forward();
    }
  }

  void _onCardTap() {
    if (_picked == null) {
      _draw();
    } else if (_reveal.isAnimating) {
      _reveal.value = 1;
    }
  }

  String _scopeLabel(RandomPickScope scope) => switch (scope) {
        RandomPickScope.all => "All".tl,
        RandomPickScope.notStarted => "Not started".tl,
        RandomPickScope.inProgress => "In progress".tl,
        RandomPickScope.completed => "Completed".tl,
      };

  String _progressText(FavoriteItem comic) {
    final history = _historyOf(comic);
    if (history == null) return "Not started".tl;
    if (randomPickMatchesScope(RandomPickScope.completed, history)) {
      return "Completed".tl;
    }
    if (history.maxPage != null && history.maxPage! > 0) {
      return "Page @page of @total".tlParams({
        'page': history.page,
        'total': history.maxPage!,
      });
    }
    return "In progress".tl;
  }

  @override
  Widget build(BuildContext context) {
    final revealed =
        _picked != null && !_preparing && _reveal.value == 1;
    return ContentDialog(
      title: "Draw a comic".tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildScopeControls(context),
            const SizedBox(height: 12),
            _buildChanceHint(context),
            const SizedBox(height: 10),
            GestureDetector(onTap: _onCardTap, child: _buildAnimatedCard(context)),
            const SizedBox(height: 10),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              child: revealed
                  ? _buildResultDetails(context, _picked!)
                  : _buildDrawHint(context),
            ),
            const SizedBox(height: 14),
            _buildActions(context, revealed),
            const SizedBox(height: 8),
          ],
        ),
      ),
      actions: const [],
    );
  }

  Widget _buildScopeControls(BuildContext context) {
    final colors = context.colorScheme;
    final disabled = _loading || _busy;
    Widget box<T>({
      required T value,
      required List<DropdownMenuItem<T>> items,
      required String hint,
      required ValueChanged<T?> onChanged,
    }) {
      return Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant, width: 0.8),
          borderRadius: BorderRadius.circular(13),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            isDense: true,
            borderRadius: BorderRadius.circular(13),
            hint: Text(hint, style: ts.s12),
            icon: const Icon(Icons.expand_more_rounded, size: 18),
            style: ts.s12.withColor(colors.onSurface),
            items: items,
            onChanged: disabled ? null : onChanged,
          ),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          child: box<String?>(
            value: _folder,
            hint: "All favorites".tl,
            items: [
              for (final folder in _folders)
                DropdownMenuItem(
                  value: folder,
                  child: Text(folder, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (folder) {
              if (folder == _folder) return;
              _folder = folder;
              _persistSelection();
              _load();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: box<RandomPickScope>(
            value: _scope,
            hint: _scopeLabel(RandomPickScope.all),
            items: [
              for (final scope in RandomPickScope.values)
                DropdownMenuItem(
                  value: scope,
                  child: Text(
                    _scopeLabel(scope),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (scope) {
              if (scope == null || scope == _scope) return;
              setState(() {
                _scope = scope;
                _applyScope();
              });
              _persistSelection();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildChanceHint(BuildContext context) {
    final colors = context.colorScheme;
    if (_loading) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.balance_outlined, size: 14, color: colors.outline),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            "@count comics · Equal chance · No repeats this round".tlParams({
              'count': _candidates.length,
            }),
            textAlign: TextAlign.center,
            style: ts.s10.withColor(colors.outline),
          ),
        ),
      ],
    );
  }

  /// 牌面 170x238：手机屏留出两侧边距后仍能完整放下，桌面端也不至于空旷。
  static const _cardWidth = 170.0;
  static const _cardHeight = 238.0;

  Widget _buildAnimatedCard(BuildContext context) {
    final colors = context.colorScheme;
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, _) {
        final value = _reveal.value;
        // 前 28% 是「摇牌」，之后才是翻转：先有点期待，再揭晓
        final flip = Curves.easeInOutCubic.transform(
          ((value - 0.28) / 0.72).clamp(0.0, 1.0),
        );
        final angle = flip * math.pi;
        final showFront = angle > math.pi / 2 && _picked != null;
        final pulse = value < 0.28
            ? 1 + math.sin(value * math.pi * 8) * 0.018
            : 1.0;
        final shake = value < 0.28
            ? math.sin(value * math.pi * 18) * (1 - value / 0.28) * 0.022
            : 0.0;
        final transform = Matrix4.identity()
          ..setEntry(3, 2, 0.0014)
          ..scaleByDouble(pulse, pulse, 1, 1)
          ..rotateZ(shake)
          ..rotateY(angle);
        return SizedBox(
          width: _cardWidth + 44,
          height: _cardHeight + 44,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RevealEffectsPainter(
                      progress: value,
                      primary: colors.primary,
                      secondary: colors.tertiary,
                    ),
                  ),
                ),
              ),
              Transform(
                alignment: Alignment.center,
                transform: transform,
                child: SizedBox(
                  width: _cardWidth,
                  height: _cardHeight,
                  child: showFront
                      ? Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()..rotateY(math.pi),
                          child: _buildCardFront(context, _picked!),
                        )
                      : _buildCardBack(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCardBack(BuildContext context) {
    final colors = context.colorScheme;
    return Semantics(
      label: (_picked == null ? "Tap to draw" : "Comic card back").tl,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colors.primaryContainer, colors.tertiaryContainer],
          ),
          border: Border.all(
            color: colors.primary.withValues(alpha: 0.65),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.primary.withValues(alpha: 0.22),
              blurRadius: 22,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 14,
              left: 14,
              child: Icon(
                Icons.auto_awesome,
                size: 18,
                color: colors.onPrimaryContainer.withValues(alpha: 0.5),
              ),
            ),
            Positioned(
              right: 14,
              bottom: 14,
              child: Icon(
                Icons.auto_awesome,
                size: 18,
                color: colors.onTertiaryContainer.withValues(alpha: 0.5),
              ),
            ),
            Container(
              width: 104,
              height: 156,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(52),
                border: Border.all(
                  color: colors.onPrimaryContainer.withValues(alpha: 0.32),
                  width: 2,
                ),
              ),
              child: Icon(
                _preparing ? Icons.hourglass_top_rounded : Icons.style_rounded,
                size: 50,
                color: colors.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardFront(BuildContext context, FavoriteItem comic) {
    final colors = context.colorScheme;
    final provider = findImageProvider(comic);
    return Semantics(
      label: comic.title,
      image: true,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: colors.surfaceContainerHighest,
          border: Border.all(
            color: colors.primary.withValues(alpha: 0.7),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.primary.withValues(alpha: 0.26),
              blurRadius: 24,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (provider != null)
              Image(
                image: provider,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _buildMissingCover(context),
              )
            else
              _buildMissingCover(context),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 24, 10, 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Text(
                  comic.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMissingCover(BuildContext context) {
    final colors = context.colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Icon(
        Icons.menu_book_rounded,
        size: 56,
        color: colors.outline,
      ),
    );
  }

  Widget _buildDrawHint(BuildContext context) {
    final colors = context.colorScheme;
    final String text;
    if (_loading) {
      text = "Loading favorites...".tl;
    } else if (_candidates.isEmpty) {
      text = "No favorite comics in this selection".tl;
    } else if (_preparing) {
      text = "Preparing your draw...".tl;
    } else if (_reveal.isAnimating) {
      text = "Tap the card to skip".tl;
    } else {
      text = "Ready to draw".tl;
    }
    return SizedBox(
      height: 40,
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: ts.s12.withColor(colors.outline),
        ),
      ),
    );
  }

  Widget _buildResultDetails(BuildContext context, FavoriteItem comic) {
    final colors = context.colorScheme;
    final author = comic.author.trim();
    return Column(
      children: [
        Text(
          comic.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: ts.s14.merge(const TextStyle(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 4),
        Text(
          [if (author.isNotEmpty) author, _progressText(comic)].join(" · "),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: ts.s10.withColor(colors.outline),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, bool revealed) {
    if (revealed) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _draw,
            icon: const Icon(Icons.casino_outlined, size: 18),
            label: Text("Draw again".tl),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_picked),
            icon: const Icon(Icons.menu_book_rounded, size: 18),
            label: Text("Read this one".tl),
          ),
        ],
      );
    }
    return FilledButton.icon(
      onPressed: _loading || _busy || _candidates.isEmpty ? null : _draw,
      icon: const Icon(Icons.style_rounded, size: 18),
      label: Text(_busy ? "Drawing...".tl : "Draw".tl),
    );
  }
}

/// 翻牌时的光效：光环、射线、星芒与粒子。
///
/// 全部是矢量绘制，没有贴图也没有 BackdropFilter——一次翻牌跑 900ms，用
/// 位图或模糊滤镜会在中端机上掉帧，而这里画出十几条线和十几个圆点几乎不
/// 花时间。
class _RevealEffectsPainter extends CustomPainter {
  const _RevealEffectsPainter({
    required this.progress,
    required this.primary,
    required this.secondary,
  });

  final double progress;

  final Color primary;

  final Color secondary;

  /// (x 比例, y 比例, 相位, 强度)
  static const _sparkles = <(double, double, double, double)>[
    (0.12, 0.20, 0.0, 0.9),
    (0.82, 0.18, 1.6, 0.75),
    (0.08, 0.64, 2.7, 0.65),
    (0.88, 0.72, 4.2, 0.95),
    (0.25, 0.88, 5.1, 0.7),
    (0.72, 0.91, 3.5, 0.8),
    (0.30, 0.12, 2.1, 0.55),
    (0.68, 0.10, 4.8, 0.6),
    (0.04, 0.42, 5.7, 0.5),
    (0.95, 0.47, 0.9, 0.58),
    (0.39, 0.96, 3.0, 0.52),
    (0.61, 0.98, 1.2, 0.56),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final energy = Curves.easeOutCubic.transform(
      (progress / 0.78).clamp(0.0, 1.0),
    );
    final fade = progress < 0.68
        ? 1.0
        : (1.0 - ((progress - 0.68) / 0.32)).clamp(0.0, 1.0);
    if (energy <= 0 || fade <= 0) return;

    final glow = Paint()
      ..color = primary.withValues(alpha: 0.22 * fade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
    canvas.drawCircle(center, 80 + 30 * energy, glow);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = secondary.withValues(alpha: 0.7 * fade);
    for (var i = 0; i < 2; i++) {
      canvas.drawCircle(center, 54 + i * 22 + energy * 70, ringPaint);
    }

    final rayPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.2
      ..color = primary.withValues(alpha: 0.66 * fade);
    for (var i = 0; i < 18; i++) {
      final angle = math.pi * 2 * i / 18 + progress * math.pi * 1.6;
      final inner = 86 + energy * 12;
      final wave = (math.sin(progress * math.pi * 2 + i) + 1) / 2;
      final outer = inner + 8 + 25 * wave + 32 * energy;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        rayPaint,
      );
    }

    for (final sparkle in _sparkles) {
      final pulse = math.sin(progress * math.pi * 2 + sparkle.$3).abs();
      final scale = (0.35 + 0.65 * pulse) * sparkle.$4;
      final paint = Paint()
        ..color = (sparkle.$3 % 2 < 1 ? primary : secondary)
            .withValues(alpha: 0.9 * fade * scale);
      _drawSparkle(
        canvas,
        Offset(size.width * sparkle.$1, size.height * sparkle.$2),
        5 + 8 * energy * scale,
        paint,
      );
    }

    for (var i = 0; i < 12; i++) {
      final angle = math.pi * 2 * i / 12 - progress * math.pi * 1.2;
      final stagger = (i % 3) * 9.0;
      final distance = 46 + stagger + energy * (52 + i % 4 * 8);
      final point = center +
          Offset(math.cos(angle) * distance, math.sin(angle) * distance);
      final radius = 1.4 + (i % 3) * 0.7 + energy * 1.2;
      final particlePaint = Paint()
        ..color = (i.isEven ? primary : secondary)
            .withValues(alpha: (0.35 + (i % 4) * 0.1) * fade);
      canvas.drawCircle(point, radius, particlePaint);
    }
  }

  void _drawSparkle(Canvas canvas, Offset center, double radius, Paint paint) {
    final path = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..lineTo(center.dx + radius * 0.28, center.dy - radius * 0.28)
      ..lineTo(center.dx + radius, center.dy)
      ..lineTo(center.dx + radius * 0.28, center.dy + radius * 0.28)
      ..lineTo(center.dx, center.dy + radius)
      ..lineTo(center.dx - radius * 0.28, center.dy + radius * 0.28)
      ..lineTo(center.dx - radius, center.dy)
      ..lineTo(center.dx - radius * 0.28, center.dy - radius * 0.28)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _RevealEffectsPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary;
}
