// app.dart
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'logic.dart';

// ── Colors ──
const kBg = Color(0xFF0A0A0A);
const kSurface = Color(0xFF141414);
const kBorder = Color(0xFF242424);
const kAccent = Color(0xFFE8D5B0);
const kAccentDim = Color(0x44E8D5B0);
const kTextPrimary = Color(0xFFEEE8DC);
const kTextSecondary = Color(0xFF888070);
const kTextMuted = Color(0xFF444038);
const kSuccess = Color(0xFF6FCF6F);
const kWarn = Color(0xFFE8A84A);
const kError = Color(0xFFCF6F6F);

class WriterApp extends StatelessWidget {
  const WriterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kSurface,
        ),
        fontFamily: 'monospace',
      ),
      home: const _MainScreen(),
    );
  }
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
            child: Text(
              state.initError!,
              style: const TextStyle(
                  color: kError, fontSize: 12, fontFamily: 'monospace'),
              textAlign: TextAlign.center,
            ),
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
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: kAccentDim,
            ),
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
    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 600;
      if (isWide) {
        return const Row(
          children: [
            Expanded(flex: 5, child: _CanvasArea()),
            SizedBox(width: 1, child: ColoredBox(color: kBorder)),
            Expanded(flex: 4, child: _InfoArea()),
          ],
        );
      }
      return const Column(
        children: [
          Expanded(flex: 5, child: _CanvasArea()),
          SizedBox(height: 1, child: ColoredBox(color: kBorder)),
          Expanded(flex: 4, child: _InfoArea()),
        ],
      );
    });
  }
}

// ── Canvas ──────────────────────────────────────────────────────────────────

class _CanvasArea extends StatelessWidget {
  const _CanvasArea();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        Expanded(child: _DrawCanvas()),
        _CanvasControls(),
      ],
    );
  }
}

class _DrawCanvas extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return LayoutBuilder(builder: (context, constraints) {
      final sz = min(constraints.maxWidth, constraints.maxHeight);
      return Center(
        child: SizedBox(
          width: sz,
          height: sz,
          child: GestureDetector(
            onPanStart: (d) {
              final s = kLogicalSize / sz;
              context
                  .read<AppState>()
                  .strokeStart(d.localPosition.dx * s, d.localPosition.dy * s);
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

    // grid
    final gridPaint = Paint()
      ..color = kBorder
      ..strokeWidth = 0.5;
    c.drawLine(
        Offset(sz.width / 2, 0), Offset(sz.width / 2, sz.height), gridPaint);
    c.drawLine(
        Offset(0, sz.height / 2), Offset(sz.width, sz.height / 2), gridPaint);
    c.drawLine(Offset(0, 0), Offset(sz.width, sz.height),
        gridPaint..color = kBorder.withOpacity(0.4));
    c.drawLine(Offset(sz.width, 0), Offset(0, sz.height),
        gridPaint..color = kBorder.withOpacity(0.4));
    c.drawRect(
      Rect.fromLTWH(1, 1, sz.width - 2, sz.height - 2),
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

    void drawStroke(StrokeData s) {
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
      for (final p in s.points.skip(1)) {
        path.lineTo(p.x * scale, p.y * scale);
      }
      c.drawPath(path, ink);
    }

    for (final s in canvas.strokes) drawStroke(s);
    if (canvas.active != null) drawStroke(canvas.active!);
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Btn(
            label: 'undo',
            enabled: state.canvas.canUndo,
            onTap: () => context.read<AppState>().undo(),
          ),
          const SizedBox(width: 8),
          _Btn(
            label: 'clear',
            enabled: state.canvas.hasStrokes,
            onTap: () => context.read<AppState>().clear(),
          ),
          const SizedBox(width: 8),
          _Btn(
            label: state.busy ? '…' : 'check',
            enabled: state.canCheck,
            accent: true,
            onTap: () => context.read<AppState>().recognize(),
          ),
        ],
      ),
    );
  }
}

// ── Info area ────────────────────────────────────────────────────────────────

class _InfoArea extends StatelessWidget {
  const _InfoArea();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          _ModelStatus(),
          SizedBox(height: 20),
          _ResultArea(),
        ],
      ),
    );
  }
}

class _ModelStatus extends StatelessWidget {
  const _ModelStatus();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    Color dot;
    String label;
    if (state.modelDownloading) {
      dot = kWarn;
      label = 'downloading…';
    } else if (state.modelReady) {
      dot = kSuccess;
      label = 'model ready';
    } else {
      dot = kTextMuted;
      label = 'model not downloaded';
    }

    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
              color: kTextSecondary, fontSize: 11, letterSpacing: 0.5),
        ),
        const Spacer(),
        if (!state.modelReady && !state.modelDownloading)
          GestureDetector(
            onTap: () => context.read<AppState>().downloadModel(),
            child: const Text(
              'download',
              style:
                  TextStyle(color: kAccent, fontSize: 11, letterSpacing: 0.5),
            ),
          ),
      ],
    );
  }
}

class _ResultArea extends StatelessWidget {
  const _ResultArea();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.busy) {
      return const Text(
        '辨識中…',
        style: TextStyle(color: kTextSecondary, fontSize: 12),
      );
    }

    final r = state.result;
    if (r == null) {
      return const Text(
        '畫字後按 check',
        style: TextStyle(color: kTextMuted, fontSize: 12, letterSpacing: 1),
      );
    }

    if (r.error != null) {
      return Text(
        r.error!,
        style: const TextStyle(
            color: kError, fontSize: 11, fontFamily: 'monospace'),
      );
    }

    final top = r.candidates.take(8).toList();
    if (top.isEmpty) {
      return const Text('沒有結果',
          style: TextStyle(color: kTextMuted, fontSize: 12));
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: top.asMap().entries.map((e) {
        final i = e.key;
        final c = e.value;
        return _Candidate(text: c.text, score: c.score, rank: i);
      }).toList(),
    );
  }
}

class _Candidate extends StatelessWidget {
  final String text;
  final double? score;
  final int rank;

  const _Candidate({required this.text, this.score, required this.rank});

  @override
  Widget build(BuildContext context) {
    final isTop = rank == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isTop ? kAccent.withOpacity(0.08) : kSurface,
        border: Border.all(
          color: isTop ? kAccent.withOpacity(0.5) : kBorder,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
              color: isTop ? kAccent : kTextPrimary,
              fontSize: isTop ? 32 : 24,
              fontWeight: FontWeight.w300,
              height: 1,
            ),
          ),
          if (score != null) ...[
            const SizedBox(height: 4),
            Text(
              score!.toStringAsFixed(2),
              style: TextStyle(
                color: isTop ? kAccent.withOpacity(0.6) : kTextMuted,
                fontSize: 9,
                fontFamily: 'monospace',
              ),
            ),
          ]
        ],
      ),
    );
  }
}

// ── Shared button ────────────────────────────────────────────────────────────

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
        enabled ? (accent ? kAccent : kBorder) : kBorder.withOpacity(0.5);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: 11,
            fontFamily: 'monospace',
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}
