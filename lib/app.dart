// app.dart
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logic.dart';

const kBg = Color(0xFF0A0A0A);
const kSurface = Color(0xFF141414);
const kBorder = Color(0xFF242424);
const kAccent = Color(0xFFE8D5B0);
const kAccentDim = Color(0x44E8D5B0);
const kTextPrimary = Color(0xFFEEE8DC);
const kTextSecondary = Color(0xFF888070);
const kTextMuted = Color(0xFF444038);
const kSuccess = Color(0xFF6FCF6F);
const kError = Color(0xFFCF6F6F);

class WriterApp extends StatelessWidget {
  const WriterApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          fontFamily: 'monospace',
        ),
        home: const _MainScreen(),
      );
}

class _MainScreen extends StatefulWidget {
  const _MainScreen();
  @override
  State<_MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<_MainScreen> {
  OverlayEntry? _toastEntry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().init();
      // Listen for toast signals after the first frame.
      context.read<AppState>().addListener(_onStateChange);
    });
  }

  @override
  void dispose() {
    context.read<AppState>().removeListener(_onStateChange);
    _toastEntry?.remove();
    super.dispose();
  }

  void _onStateChange() {
    final state = context.read<AppState>();
    final toast = state.pendingToast;
    if (toast == null) return;
    state.consumeToast();
    _showEmbeddingToast(toast);
  }

  void _showEmbeddingToast(ToastMessage toast) {
    _toastEntry?.remove();
    _toastEntry = null;

    final entry = OverlayEntry(
      builder: (_) => _EmbeddingToast(
        message: toast,
        onDone: () {
          _toastEntry?.remove();
          _toastEntry = null;
        },
      ),
    );

    _toastEntry = entry;
    Overlay.of(context).insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.initError != null) {
      return Scaffold(
        backgroundColor: kBg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(state.initError!,
                style: const TextStyle(color: kError, fontSize: 11),
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (!state.ready) {
      return const Scaffold(
        backgroundColor: kBg,
        body: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child:
                CircularProgressIndicator(strokeWidth: 1.5, color: kAccentDim),
          ),
        ),
      );
    }
    return const Scaffold(
      backgroundColor: kBg,
      body: SafeArea(child: _Body()),
    );
  }
}

// ── Embedding Toast Overlay ───────────────────────────────────────────────────

class _EmbeddingToast extends StatefulWidget {
  final ToastMessage message;
  final VoidCallback onDone;

  const _EmbeddingToast({required this.message, required this.onDone});

  @override
  State<_EmbeddingToast> createState() => _EmbeddingToastState();
}

class _EmbeddingToastState extends State<_EmbeddingToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );

    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

    _ctrl.forward();

    // Auto-dismiss after 2.4 s
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) {
        _ctrl.reverse().then((_) => widget.onDone());
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 16,
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(
          position: _slide,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: kSurface,
                border: Border.all(color: kAccentDim, width: 1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Character glyph + count below
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.message.char,
                        style: const TextStyle(
                          color: kAccent,
                          fontSize: 22,
                          fontWeight: FontWeight.w200,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '#${widget.message.embeddingCount}',
                        style: const TextStyle(
                          color: kTextMuted,
                          fontSize: 9,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.message.statusLabel,
                    style: TextStyle(
                      color: widget.message.status == ToastStatus.dbError
                          ? kError
                          : widget.message.status == ToastStatus.savedFallback
                              ? kTextSecondary
                              : kSuccess,
                      fontSize: 9,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Layout ────────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  const _Body();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final isWide = c.maxWidth > 600;
      if (isWide) {
        return Row(children: [
          Expanded(
            flex: 5,
            child: Column(children: [
              const _TopPanel(),
              const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
              const Expanded(child: _CanvasArea()),
            ]),
          ),
          const SizedBox(width: 1, child: ColoredBox(color: kBorder)),
          Expanded(flex: 4, child: _InfoArea()),
        ]);
      }
      return Column(children: [
        const _TopPanel(),
        const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
        const Expanded(flex: 5, child: _CanvasArea()),
        const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
        Expanded(flex: 4, child: _InfoArea()),
      ]);
    });
  }
}

// ── Top panel ─────────────────────────────────────────────────────────────────

class _TopPanel extends StatelessWidget {
  const _TopPanel();
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SearchBar(),
          const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
          _CanvasControls(),
        ],
      );
}

// ── Canvas area ───────────────────────────────────────────────────────────────

class _CanvasArea extends StatelessWidget {
  const _CanvasArea();
  @override
  Widget build(BuildContext context) => const Column(children: [
        Expanded(child: _DrawCanvas()),
        _LearningFeedback(),
      ]);
}

// ── Draw canvas ───────────────────────────────────────────────────────────────

class _DrawCanvas extends StatelessWidget {
  const _DrawCanvas();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return LayoutBuilder(builder: (ctx, c) {
      final sz = min(c.maxWidth, c.maxHeight);
      return Center(
        child: SizedBox(
          width: sz,
          height: sz,
          child: ClipRect(
            child: GestureDetector(
              onPanStart: (d) {
                final s = kLogicalSize / sz;
                context.read<AppState>().strokeStart(
                    d.localPosition.dx * s, d.localPosition.dy * s);
              },
              onPanUpdate: (d) {
                final s = kLogicalSize / sz;
                context
                    .read<AppState>()
                    .strokeAdd(d.localPosition.dx * s, d.localPosition.dy * s);
              },
              onPanEnd: (_) => context.read<AppState>().strokeEnd(),
              onPanCancel: () => context.read<AppState>().strokeEnd(),
              child: CustomPaint(
                size: Size(sz, sz),
                painter: _CanvasPainter(
                  state.canvas,
                  state.pinnedEntry?.vocabulary,
                  state.strokeWidth,
                  state.showPinnedTemplate,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _CanvasPainter extends CustomPainter {
  final CanvasData canvas;
  final String? hint;
  final double strokeWidth;
  final bool showPinnedTemplate;

  _CanvasPainter(
      this.canvas, this.hint, this.strokeWidth, this.showPinnedTemplate);

  @override
  void paint(Canvas c, Size sz) {
    final scale = sz.width / kLogicalSize;

    c.drawRect(Offset.zero & sz, Paint()..color = kSurface);

    final g = Paint()
      ..color = kBorder
      ..strokeWidth = 0.5;
    c.drawLine(Offset(sz.width / 2, 0), Offset(sz.width / 2, sz.height), g);
    c.drawLine(Offset(0, sz.height / 2), Offset(sz.width, sz.height / 2), g);
    final gd = Paint()
      ..color = kBorder.withOpacity(0.35)
      ..strokeWidth = 0.5;
    c.drawLine(Offset(0, 0), Offset(sz.width, sz.height), gd);
    c.drawLine(Offset(sz.width, 0), Offset(0, sz.height), gd);
    c.drawRect(
      Rect.fromLTWH(0.5, 0.5, sz.width - 1, sz.height - 1),
      Paint()
        ..color = kBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    if (hint != null && (showPinnedTemplate || !canvas.hasStrokes)) {
      final tp = TextPainter(
        text: TextSpan(
          text: hint,
          style: TextStyle(
            color: kAccent.withOpacity(showPinnedTemplate ? 0.18 : 0.12),
            fontSize: sz.width * 0.55,
            fontWeight: FontWeight.w200,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          c, Offset((sz.width - tp.width) / 2, (sz.height - tp.height) / 2));
    }

    final ink = Paint()
      ..color = kAccent
      ..strokeWidth = strokeWidth * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    void draw(StrokeData s) {
      if (s.points.isEmpty) return;
      if (s.points.length == 1) {
        c.drawCircle(
          Offset(s.points.first.x * scale, s.points.first.y * scale),
          5 * scale,
          ink,
        );
        return;
      }
      final path = Path()
        ..moveTo(s.points.first.x * scale, s.points.first.y * scale);
      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x * scale, pt.y * scale);
      }
      c.drawPath(path, ink);
    }

    for (final s in canvas.strokes) draw(s);
    if (canvas.active != null) draw(canvas.active!);
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.canvas != canvas ||
      old.hint != hint ||
      old.strokeWidth != strokeWidth ||
      old.showPinnedTemplate != showPinnedTemplate;
}

// ── Canvas Controls ───────────────────────────────────────────────────────────

class _CanvasControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(children: [
        _Btn(
          label: 'undo',
          enabled: state.canvas.canUndo,
          onTap: () => context.read<AppState>().undo(),
        ),
        const SizedBox(width: 6),
        _Btn(
          label: 'clear',
          enabled: state.canvas.hasStrokes,
          onTap: () => context.read<AppState>().clear(),
        ),
        const SizedBox(width: 6),
        _Btn(
          label: state.showPinnedTemplate ? 'tmpl ●' : 'tmpl',
          enabled: state.pinnedEntry != null,
          onTap: () => context.read<AppState>().togglePinnedTemplate(),
        ),
        const SizedBox(width: 6),
        _Btn(
          label: state.busy ? '…' : 'check',
          enabled: state.canCheck,
          accent: true,
          onTap: () => context.read<AppState>().recognize(),
        ),
        const SizedBox(width: 10),
        const Text('─', style: TextStyle(color: kTextMuted, fontSize: 10)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: kAccent.withOpacity(0.6),
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              trackHeight: 1.5,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: state.strokeWidth,
              min: 4.0,
              max: 24.0,
              onChanged: (v) => context.read<AppState>().setStrokeWidth(v),
            ),
          ),
        ),
        const Text('━', style: TextStyle(color: kTextMuted, fontSize: 14)),
      ]),
    );
  }
}

// ── Learning Feedback ─────────────────────────────────────────────────────────

class _LearningFeedback extends StatelessWidget {
  const _LearningFeedback();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.showPinnedTemplate || state.pinnedEntry == null) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<Map<String, dynamic>>(
      future: DbService.getVocabStats(state.pinnedEntry!.vocabulary),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final stats = snap.data!;
        final embCount = stats['embedding_count'] as int;
        final accuracy = stats['ocr_accuracy'] as double;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(children: [
            _StatChip(
              label: '嵌入',
              value: '$embCount',
              highlight: embCount >= 10,
            ),
            const SizedBox(width: 6),
            if (embCount >= 3)
              _StatChip(
                label: 'OCR',
                value: '${(accuracy * 100).round()}%',
                highlight: accuracy >= 0.8,
                isWarning: accuracy < 0.5,
              ),
            const Spacer(),
            if (state.matchSource != MatchSource.none)
              _MatchSourceBadge(source: state.matchSource),
            const SizedBox(width: 6),
            if (state.similarityResult != null)
              _SimilarityBadge(result: state.similarityResult!),
          ]),
        );
      },
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label, value;
  final bool highlight, isWarning;

  const _StatChip({
    required this.label,
    required this.value,
    this.highlight = false,
    this.isWarning = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isWarning
        ? kError
        : highlight
            ? kSuccess
            : kTextMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: RichText(
        text: TextSpan(children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(
                color: kTextMuted, fontSize: 9, letterSpacing: 0.5),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
        ]),
      ),
    );
  }
}

class _MatchSourceBadge extends StatelessWidget {
  final MatchSource source;
  const _MatchSourceBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final isProto = source == MatchSource.proto;
    final label = isProto ? '原型' : 'OCR';
    final color = isProto ? kSuccess : kTextSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 9, letterSpacing: 0.5)),
    );
  }
}

class _SimilarityBadge extends StatelessWidget {
  final SimilarityResult result;
  const _SimilarityBadge({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.isConsistent
        ? kSuccess
        : result.isGood
            ? kAccent
            : kError;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        result.feedback,
        style: TextStyle(color: color, fontSize: 9, letterSpacing: 0.3),
      ),
    );
  }
}

// ── Search bar ────────────────────────────────────────────────────────────────

class _SearchBar extends StatefulWidget {
  const _SearchBar();
  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _ctrl = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _dismissKeyboard() {
    _focusNode.unfocus();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: _focusNode,
                style: const TextStyle(color: kTextPrimary, fontSize: 13),
                cursorColor: kAccent,
                decoration: InputDecoration(
                  hintText: '搜尋 pinyin / 漢字…',
                  hintStyle: const TextStyle(color: kTextMuted, fontSize: 12),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  filled: true,
                  fillColor: kSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kAccent, width: 1),
                  ),
                  suffixIcon: _ctrl.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _ctrl.clear();
                            context.read<AppState>().setSearchQuery('');
                          },
                          child: const Icon(Icons.close,
                              color: kTextMuted, size: 14),
                        )
                      : null,
                ),
                onChanged: (v) => context.read<AppState>().setSearchQuery(v),
              ),
            ),
            if (state.pinnedEntry != null) ...[
              const SizedBox(width: 8),
              _Btn(
                label: 'reset',
                enabled: true,
                onTap: () => context.read<AppState>().resetPinned(),
              ),
            ],
          ]),
        ),
        if (state.searchSuggestions.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            decoration: BoxDecoration(
              color: kSurface,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: state.searchSuggestions.length,
              itemBuilder: (ctx, i) {
                final e = state.searchSuggestions[i];
                return GestureDetector(
                  onTap: () {
                    _dismissKeyboard();
                    _ctrl.clear();
                    context.read<AppState>().selectSuggestion(e);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(color: kBorder.withOpacity(0.5))),
                    ),
                    child: Row(children: [
                      Text(e.vocabulary,
                          style: const TextStyle(
                              color: kAccent,
                              fontSize: 20,
                              fontWeight: FontWeight.w200)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (e.pinyin != null)
                              Text(e.pinyin!,
                                  style: const TextStyle(
                                      color: kTextPrimary, fontSize: 12)),
                            if (e.levelCode != null)
                              Text(e.levelCode!,
                                  style: const TextStyle(
                                      color: kTextMuted, fontSize: 10)),
                          ],
                        ),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ── Info area ─────────────────────────────────────────────────────────────────

class _InfoArea extends StatelessWidget {
  const _InfoArea();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.pinnedEntry != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _EntryCard(
              entry: state.pinnedEntry!,
              showStrokeOrder: true,
              showEmbeddingCount: true,
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: const _ResultArea(),
    );
  }
}

class _ResultArea extends StatelessWidget {
  const _ResultArea();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.busy) {
      return const Text('辨識中…',
          style: TextStyle(color: kTextSecondary, fontSize: 12));
    }
    final r = state.result;
    if (r == null) {
      return const Text('畫字後按 check',
          style: TextStyle(color: kTextMuted, fontSize: 12, letterSpacing: 1));
    }
    if (r.error != null) {
      return Text(r.error!,
          style: const TextStyle(color: kError, fontSize: 11));
    }
    if (r.matches.isEmpty) {
      if (r.raw.isEmpty) {
        return const Text('沒有辨識結果',
            style: TextStyle(color: kTextMuted, fontSize: 12));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Vision 輸出（不在詞庫中）',
            style:
                TextStyle(color: kTextMuted, fontSize: 10, letterSpacing: 1)),
        const SizedBox(height: 8),
        Text(r.raw.join('  '),
            style: const TextStyle(color: kTextSecondary, fontSize: 20)),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: r.matches
          .map((e) => _EntryCard(entry: e, showStrokeOrder: true))
          .toList(),
    );
  }
}

// ── Entry card ────────────────────────────────────────────────────────────────

class _EntryCard extends StatelessWidget {
  final VocabEntry entry;
  final bool showStrokeOrder;
  final bool showEmbeddingCount;
  const _EntryCard({
    required this.entry,
    this.showStrokeOrder = false,
    this.showEmbeddingCount = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(entry.vocabulary,
                  style: const TextStyle(
                      color: kAccent,
                      fontSize: 48,
                      fontWeight: FontWeight.w200,
                      height: 1)),
              if (showEmbeddingCount)
                _EmbeddingCountBadge(vocabulary: entry.vocabulary),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.pinyin != null)
                  Text(entry.pinyin!,
                      style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 16,
                          letterSpacing: 0.5)),
                if (entry.bopomofo != null)
                  Text(entry.bopomofo!,
                      style:
                          const TextStyle(color: kTextSecondary, fontSize: 13)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  if (entry.levelCode != null) _Tag(entry.levelCode!),
                  if (entry.context != null) _Tag(entry.context!),
                  if (entry.partOfSpeech != null) _Tag(entry.partOfSpeech!),
                ]),
                if (entry.variantGroup != null) ...[
                  const SizedBox(height: 4),
                  Text('異體字 ${entry.variantGroup!}',
                      style: const TextStyle(color: kTextMuted, fontSize: 10)),
                ],
              ],
            ),
          ),
        ]),
        if (showStrokeOrder) ...[
          const SizedBox(height: 8),
          _StrokeOrderBtn(char: entry.vocabulary),
        ],
        const SizedBox(height: 4),
        const Divider(color: kBorder, height: 1),
      ]),
    );
  }
}

// ── Embedding Count Badge ─────────────────────────────────────────────────────

class _EmbeddingCountBadge extends StatelessWidget {
  final String vocabulary;
  const _EmbeddingCountBadge({required this.vocabulary});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: DbService.getSampleCount(vocabulary),
      builder: (ctx, snap) {
        final count = snap.data ?? 0;
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(
                color: count > 0 ? kAccentDim : kBorder,
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            child: RichText(
              text: TextSpan(children: [
                TextSpan(
                  text: '嵌入 ',
                  style: const TextStyle(
                      color: kTextMuted, fontSize: 8, letterSpacing: 0.5),
                ),
                TextSpan(
                  text: '$count',
                  style: TextStyle(
                    color: count > 0 ? kAccent : kTextMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// ── Stroke order button ───────────────────────────────────────────────────────

class _StrokeOrderBtn extends StatelessWidget {
  final String char;
  const _StrokeOrderBtn({required this.char});

  @override
  Widget build(BuildContext context) {
    final c = char.isNotEmpty ? char.characters.first : char;
    final url =
        'https://stroke-order.learningweb.moe.edu.tw/charactersQueryResult.do?words=$c';
    return GestureDetector(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('筆順',
              style: TextStyle(
                  color: kTextSecondary, fontSize: 11, letterSpacing: 1)),
          const SizedBox(width: 6),
          Text(c, style: const TextStyle(color: kAccent, fontSize: 13)),
        ]),
      ),
    );
  }
}

// ── Tag ───────────────────────────────────────────────────────────────────────

class _Tag extends StatelessWidget {
  final String label;
  const _Tag(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style: const TextStyle(
                color: kTextMuted, fontSize: 9, letterSpacing: 0.5)),
      );
}

// ── Button ────────────────────────────────────────────────────────────────────

class _Btn extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool accent;
  final VoidCallback onTap;

  const _Btn({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? (accent ? kBg : kTextSecondary) : kTextMuted;
    final bg = accent && enabled ? kAccent : Colors.transparent;
    final border =
        enabled ? (accent ? kAccent : kBorder) : kBorder.withOpacity(0.4);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(color: fg, fontSize: 11, letterSpacing: 1)),
      ),
    );
  }
}
