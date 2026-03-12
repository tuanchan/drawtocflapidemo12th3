// app.dart
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

class _Body extends StatelessWidget {
  const _Body();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final isWide = constraints.maxWidth > 600;
      if (isWide) {
        return const Row(children: [
          Expanded(flex: 5, child: _CanvasArea()),
          SizedBox(width: 1, child: ColoredBox(color: kBorder)),
          Expanded(flex: 4, child: _InfoArea()),
        ]);
      }
      return const Column(children: [
        Expanded(flex: 5, child: _CanvasArea()),
        SizedBox(height: 1, child: ColoredBox(color: kBorder)),
        Expanded(flex: 4, child: _InfoArea()),
      ]);
    });
  }
}

// ── Canvas ────────────────────────────────────────────────────────────────────

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
    return LayoutBuilder(builder: (ctx, constraints) {
      final sz = min(constraints.maxWidth, constraints.maxHeight);
      return Center(
        child: SizedBox(
          width: sz,
          height: sz,
          // ClipRect ensures ink never renders outside the box
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
                painter: _CanvasPainter(state.canvas),
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
  _CanvasPainter(this.canvas);

  @override
  void paint(Canvas c, Size sz) {
    final scale = sz.width / kLogicalSize;

    // bg
    c.drawRect(Offset.zero & sz, Paint()..color = kSurface);

    // grid lines
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
    // border
    c.drawRect(
      Rect.fromLTWH(0.5, 0.5, sz.width - 1, sz.height - 1),
      Paint()
        ..color = kBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

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
      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x * scale, pt.y * scale);
      }
      c.drawPath(path, ink);
    }

    for (final s in canvas.strokes) draw(s);
    if (canvas.active != null) draw(canvas.active!);
  }

  @override
  bool shouldRepaint(_CanvasPainter old) => old.canvas != canvas;
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

// ── Info area ─────────────────────────────────────────────────────────────────

class _InfoArea extends StatelessWidget {
  const _InfoArea();
  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(20),
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
      // Show raw Vision output if no DB match
      if (r.raw.isEmpty) {
        return const Text('沒有辨識結果',
            style: TextStyle(color: kTextMuted, fontSize: 12));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Vision 輸出（不在詞庫中）',
              style:
                  TextStyle(color: kTextMuted, fontSize: 10, letterSpacing: 1)),
          const SizedBox(height: 8),
          Text(r.raw.join('  '),
              style: const TextStyle(color: kTextSecondary, fontSize: 20)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: r.matches.map((e) => _EntryCard(entry: e)).toList(),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final VocabEntry entry;
  const _EntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Big character
        Text(entry.vocabulary,
            style: const TextStyle(
                color: kAccent,
                fontSize: 48,
                fontWeight: FontWeight.w200,
                height: 1)),
        const SizedBox(width: 14),
        // Meta
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
          ),
        ),
      ]),
    );
  }
}

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
