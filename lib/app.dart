// app.dart
import 'dart:math';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().init();
    });
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
        )),
      );
    }
    if (!state.ready) {
      return const Scaffold(
        backgroundColor: kBg,
        body: Center(
            child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: kAccentDim),
        )),
      );
    }
    return const Scaffold(
      backgroundColor: kBg,
      body: SafeArea(child: _Body()),
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
        return const Row(children: [
          Expanded(flex: 5, child: _CanvasArea()),
          SizedBox(width: 1, child: ColoredBox(color: kBorder)),
          Expanded(flex: 4, child: _RightPanel()),
        ]);
      }
      return const Column(children: [
        Expanded(flex: 5, child: _CanvasArea()),
        SizedBox(height: 1, child: ColoredBox(color: kBorder)),
        Expanded(flex: 4, child: _RightPanel()),
      ]);
    });
  }
}

// ── Canvas area ───────────────────────────────────────────────────────────────

class _CanvasArea extends StatelessWidget {
  const _CanvasArea();
  @override
  Widget build(BuildContext context) => Column(children: [
        const Expanded(child: _DrawCanvas()),
        _CanvasControls(),
      ]);
}

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
                painter:
                    _CanvasPainter(state.canvas, state.pinnedEntry?.vocabulary),
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
  final String? hint; // pinned entry shown as watermark

  _CanvasPainter(this.canvas, this.hint);

  @override
  void paint(Canvas c, Size sz) {
    final scale = sz.width / kLogicalSize;

    c.drawRect(Offset.zero & sz, Paint()..color = kSurface);

    // grid
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

    // watermark hint
    if (!canvas.hasStrokes && hint != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: hint,
          style: TextStyle(
            color: kAccent.withOpacity(0.12),
            fontSize: sz.width * 0.55,
            fontWeight: FontWeight.w200,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(
          c, Offset((sz.width - tp.width) / 2, (sz.height - tp.height) / 2));
    }

    // strokes
    final ink = Paint()
      ..color = kAccent
      ..strokeWidth = 10 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    void draw(StrokeData s) {
      if (s.points.isEmpty) return;
      if (s.points.length == 1) {
        c.drawCircle(Offset(s.points.first.x * scale, s.points.first.y * scale),
            5 * scale, ink);
        return;
      }
      final path = Path()
        ..moveTo(s.points.first.x * scale, s.points.first.y * scale);
      for (final pt in s.points.skip(1))
        path.lineTo(pt.x * scale, pt.y * scale);
      c.drawPath(path, ink);
    }

    for (final s in canvas.strokes) draw(s);
    if (canvas.active != null) draw(canvas.active!);
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.canvas != canvas || old.hint != hint;
}

class _CanvasControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _Btn(
            label: 'undo',
            enabled: state.canvas.canUndo,
            onTap: () => context.read<AppState>().undo()),
        const SizedBox(width: 8),
        _Btn(
            label: 'clear',
            enabled: state.canvas.hasStrokes,
            onTap: () => context.read<AppState>().clear()),
        const SizedBox(width: 8),
        _Btn(
          label: state.busy ? '…' : 'check',
          enabled: state.canCheck,
          accent: true,
          onTap: () => context.read<AppState>().recognize(),
        ),
      ]),
    );
  }
}

// ── Right panel ───────────────────────────────────────────────────────────────

class _RightPanel extends StatelessWidget {
  const _RightPanel();
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const _SearchBar(),
      const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
      const Expanded(child: _InfoArea()),
    ]);
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

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Input row
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
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
            // Reset pinned button
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
        // Suggestions dropdown
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
                      )),
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

    // If pinned entry → show its detail + stroke order button
    if (state.pinnedEntry != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _EntryCard(entry: state.pinnedEntry!, showStrokeOrder: true),
          ],
        ),
      );
    }

    // Otherwise show recognition result
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: _ResultArea(),
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
  const _EntryCard({required this.entry, this.showStrokeOrder = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(entry.vocabulary,
              style: const TextStyle(
                  color: kAccent,
                  fontSize: 48,
                  fontWeight: FontWeight.w200,
                  height: 1)),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.pinyin != null)
                Text(entry.pinyin!,
                    style: const TextStyle(
                        color: kTextPrimary, fontSize: 16, letterSpacing: 0.5)),
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
          )),
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

// ── Stroke order button ───────────────────────────────────────────────────────

class _StrokeOrderBtn extends StatelessWidget {
  final String char;
  const _StrokeOrderBtn({required this.char});

  @override
  Widget build(BuildContext context) {
    // Use only first character for stroke order lookup
    final c = char.isNotEmpty ? char.characters.first : char;
    final codepoint = c.runes.first.toRadixString(16).padLeft(5, '0');
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
