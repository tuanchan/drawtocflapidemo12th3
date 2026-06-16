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
const kTextSecondary = Color(0xFFB0A898);
const kTextMuted = Color(0xFF666058);
const kSuccess = Color(0xFF6FCF6F);
const kError = Color(0xFFCF6F6F);

extension AccentX on BuildContext {
  Color get accent => watch<AppState>().accentColor;
  Color get accentRead => read<AppState>().accentColor;
}

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

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        side: BorderSide(color: kBorder),
      ),
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AppState>(),
        child: const _SettingsSheet(),
      ),
    );
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
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Stack(
          children: [
            const _Body(),
            Positioned(
              top: 8,
              right: 12,
              child: GestureDetector(
                onTap: _openSettings,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: kBg,
                    border: Border.all(color: kBorder),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.settings, color: kTextMuted, size: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings Sheet ────────────────────────────────────────────────────────────

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Settings', style: TextStyle(color: kTextSecondary, fontSize: 11, letterSpacing: 1.2)),
            const Spacer(),
            GestureDetector(onTap: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: kTextMuted, fontSize: 10, letterSpacing: 0.8))),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            const Text('stroke width', style: TextStyle(color: kTextMuted, fontSize: 9, letterSpacing: 0.8)),
            Expanded(child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: kAccent.withOpacity(0.6), inactiveTrackColor: kBorder,
                thumbColor: kAccent, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 1.5, overlayShape: SliderComponentShape.noOverlay),
              child: Slider(value: appState.strokeWidth, min: 4.0, max: 24.0, onChanged: (v) => appState.setStrokeWidth(v)),
            )),
          ]),
          const SizedBox(height: 12),
          const Text('recognition language', style: TextStyle(color: kTextMuted, fontSize: 9, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          Row(children: [
            _LangChip(label: '繁體中文', selected: appState.languageCode == 'zh-Hant', onTap: () => appState.setLanguageCode('zh-Hant')),
            const SizedBox(width: 8),
            _LangChip(label: '简体中文', selected: appState.languageCode == 'zh-Hans', onTap: () => appState.setLanguageCode('zh-Hans')),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
              color: appState.modelDownloading ? kAccent : appState.modelReady ? kSuccess : kError)),
            const SizedBox(width: 6),
            Text(appState.modelDownloading ? 'Downloading model…' : appState.modelReady ? 'Model ready' : 'Model not available',
              style: TextStyle(color: appState.modelReady ? kTextSecondary : kError, fontSize: 10, letterSpacing: 0.4)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            const Text('show realtime chips', style: TextStyle(color: kTextSecondary, fontSize: 10, letterSpacing: 0.5)),
            const Spacer(),
            GestureDetector(
              onTap: () => context.read<AppState>().setShowRealtimeChips(!context.read<AppState>().showRealtimeChips),
              child: Container(width: 36, height: 18, decoration: BoxDecoration(
                color: appState.showRealtimeChips ? kAccentDim : kBorder, borderRadius: BorderRadius.circular(9)),
                child: AnimatedAlign(duration: const Duration(milliseconds: 150),
                  alignment: appState.showRealtimeChips ? Alignment.centerRight : Alignment.centerLeft,
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Container(width: 14, height: 14, decoration: BoxDecoration(
                      color: appState.showRealtimeChips ? kAccent : kTextMuted, shape: BoxShape.circle)))))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            const Text('always show template', style: TextStyle(color: kTextSecondary, fontSize: 10, letterSpacing: 0.5)),
            const Spacer(),
            GestureDetector(
              onTap: () => context.read<AppState>().setAlwaysShowTemplate(!context.read<AppState>().alwaysShowTemplate),
              child: Container(width: 36, height: 18, decoration: BoxDecoration(
                color: appState.alwaysShowTemplate ? kAccentDim : kBorder, borderRadius: BorderRadius.circular(9)),
                child: AnimatedAlign(duration: const Duration(milliseconds: 150),
                  alignment: appState.alwaysShowTemplate ? Alignment.centerRight : Alignment.centerLeft,
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Container(width: 14, height: 14, decoration: BoxDecoration(
                      color: appState.alwaysShowTemplate ? kAccent : kTextMuted, shape: BoxShape.circle)))))),
          ]),
          const SizedBox(height: 12),
          const Text('accent color', style: TextStyle(color: kTextMuted, fontSize: 9, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            const Color(0xFFE8D5B0), const Color(0xFFFFFFFF), const Color(0xFF6FCF6F),
            const Color(0xFF7EB8F7), const Color(0xFFCFAA6F), const Color(0xFFCF6FCF), const Color(0xFFCF6F6F),
          ].map((c) {
            final isSelected = appState.accentColor == c;
            return GestureDetector(onTap: () => context.read<AppState>().setAccentColor(c),
              child: Container(width: 24, height: 24, decoration: BoxDecoration(color: c, shape: BoxShape.circle,
                border: Border.all(color: isSelected ? c : kBorder, width: isSelected ? 2.5 : 1),
                boxShadow: isSelected ? [BoxShadow(color: c.withOpacity(0.6), blurRadius: 6)] : null)));
          }).toList()),
        ]),
      ),
    );
  }
}

class _LangChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _LangChip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap,
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: selected ? kAccentDim : Colors.transparent,
        border: Border.all(color: selected ? kAccent : kBorder), borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(color: selected ? kAccent : kTextSecondary, fontSize: 12, letterSpacing: 0.5))));
}





// ── End of Settings ──

// ═══════════════════════════════════════════════════════════════════════════════
// LAYOUT
// ═══════════════════════════════════════════════════════════════════════════════
//
// KEY DESIGN:
// - _DrawCanvas is the only Expanded child in the canvas column.
// - _BottomBar sits below it as a fixed-size (mainAxisSize.min) Column.
// - This prevents the canvas from shrinking as panels grow.
// - Mobile: TopPanel → Expanded(DrawCanvas) → BottomBar → Expanded(flex:3, InfoArea)
// - Wide:   Left(TopPanel + Expanded(DrawCanvas) + BottomBar) | Right(InfoArea)
//
// ═══════════════════════════════════════════════════════════════════════════════

class _Body extends StatelessWidget {
  const _Body();

  static const double kTopInfoHeight = 108;
  static const double kBottomInfoHeight = 34;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final isWide = c.maxWidth > 600;

      Widget leftPane() {
        return Column(
          children: [
            const _SearchBar(),
            const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
            const SizedBox(
              height: kTopInfoHeight,
              child: _MobileInfoBar(),
            ),
            const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, c) {
                  final canvasSize = min(c.maxWidth, c.maxHeight);
                  return Stack(
                    children: [
                      Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: const _DrawCanvas(),
                        ),
                      ),
                      Positioned(
                        top: canvasSize + 6 + 10,
                        left: max(12.0, (c.maxWidth - canvasSize) / 2),
                        right: max(12.0, (c.maxWidth - canvasSize) / 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: context.watch<AppState>().showRealtimeChips
                                  ? const SizedBox(
                                      height: kBottomInfoHeight,
                                      child: _BottomBar(),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            const SizedBox(width: 12),
                            const _CanvasControls(),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      }

      if (isWide) {
        return Row(
          children: [
            Expanded(flex: 5, child: leftPane()),
            const SizedBox(width: 1, child: ColoredBox(color: kBorder)),
            Expanded(flex: 4, child: _InfoArea()),
          ],
        );
      }

      return leftPane();
    });
  }
}

class _MobileInfoBar extends StatelessWidget {
  const _MobileInfoBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // ── Pinned entry ──────────────────────────────────────────────────────
    if (state.pinnedEntry != null) {
      final entry = state.pinnedEntry!;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  entry.vocabulary,
                  style: const TextStyle(
                    color: kAccent,
                    fontSize: 40,
                    fontWeight: FontWeight.w200,
                    height: 1,
                  ),
                ),
                const Spacer(),
                _SearchBtn(char: entry.vocabulary),
              ],
            ),
            const SizedBox(height: 6),
            if (entry.pinyin != null && entry.pinyin!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _MiniChip(entry.pinyin!),
              ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (entry.levelCode != null) _MiniChip(entry.levelCode!),
                if (entry.context != null) _MiniChip(entry.context!),
                if (entry.partOfSpeech != null) _MiniChip(entry.partOfSpeech!),
              ],
            ),
          ],
        ),
      );
    }

    // ── Realtime top candidate (no pinned) ────────────────────────────────
    if (state.realtimeCandidates.isNotEmpty) {
      final top = state.realtimeCandidates.first;

      return FutureBuilder<VocabEntry?>(
        future: DbService.findExactByVocabulary(top.text),
        builder: (ctx, snap) {
          final entry = snap.data;

          return Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      top.text,
                      style: const TextStyle(
                        color: kAccent,
                        fontSize: 40,
                        fontWeight: FontWeight.w200,
                        height: 1,
                  ),
                ),
                    const Spacer(),
                    _SearchBtn(char: top.text),
                  ],
                ),
                const SizedBox(height: 6),
                if (entry?.pinyin != null && entry!.pinyin!.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _MiniChip(entry.pinyin!),
                  ),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (entry?.levelCode != null) _MiniChip(entry!.levelCode!),
                    if (entry?.context != null) _MiniChip(entry!.context!),
                    if (entry?.partOfSpeech != null)
                      _MiniChip(entry!.partOfSpeech!),
                  ],
                ),
              ],
            ),
          );
        },
      );
    }

    return const SizedBox.expand();
  }
}
class _BottomBar extends StatelessWidget {
  const _BottomBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final candidates = state.realtimeCandidates;

    if (candidates.isEmpty) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.zero,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _BestMatchGlyph(candidate: candidates.first),
            const SizedBox(width: 10),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: candidates.skip(1).map((c) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _CandidateChip(candidate: c),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BestMatchGlyph extends StatelessWidget {
  final RealtimeCandidate candidate;
  const _BestMatchGlyph({required this.candidate});

  @override
  Widget build(BuildContext context) {
    return Text(
      candidate.text,
      style: const TextStyle(
        color: kAccent,
        fontSize: 26,
        fontWeight: FontWeight.w200,
        height: 1,
      ),
    );
  }
}

class _CandidateChip extends StatelessWidget {
  final RealtimeCandidate candidate;
  const _CandidateChip({required this.candidate});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        candidate.text,
        style: const TextStyle(
          color: kTextSecondary,
          fontSize: 14,
          fontWeight: FontWeight.w200,
          height: 1,
        ),
      ),
    );
  }
}

// ── Draw canvas ───────────────────────────────────────────────────────────────

class _DrawCanvas extends StatelessWidget {
  const _DrawCanvas();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return LayoutBuilder(builder: (ctx, c) {
      final sz = min(c.maxWidth, c.maxHeight);
      return SizedBox(
        width: sz,
        height: sz,
        child: ClipRect(
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
              painter: _CanvasPainter(
                state.canvas,
                state.pinnedEntry?.vocabulary,
                state.strokeWidth,
                state.accentColor,
                state.alwaysShowTemplate,
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
  final Color accentColor;
  final bool alwaysShowTemplate;

  _CanvasPainter(this.canvas, this.hint, this.strokeWidth, this.accentColor,
      this.alwaysShowTemplate);

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
    c.drawLine(const Offset(0, 0), Offset(sz.width, sz.height), gd);
    c.drawLine(Offset(sz.width, 0), Offset(0, sz.height), gd);
    c.drawRect(
      Rect.fromLTWH(0.5, 0.5, sz.width - 1, sz.height - 1),
      Paint()
        ..color = kBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    if (hint != null && (alwaysShowTemplate || !canvas.hasStrokes)) {
      final tp = TextPainter(
        text: TextSpan(
            text: hint,
            style: TextStyle(
                color: accentColor.withOpacity(0.12),
                fontSize: sz.width * 0.55,
                fontWeight: FontWeight.w200,
                height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          c, Offset((sz.width - tp.width) / 2, (sz.height - tp.height) / 2));
    }

    final ink = Paint()
      ..color = accentColor
      ..strokeWidth = strokeWidth * scale
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
  bool shouldRepaint(_CanvasPainter old) =>
      old.canvas != canvas ||
      old.hint != hint ||
      old.strokeWidth != strokeWidth ||
      old.accentColor != accentColor ||
      old.alwaysShowTemplate != alwaysShowTemplate;
}

// ── Canvas Controls ───────────────────────────────────────────────────────────

class _CanvasControls extends StatelessWidget {
  const _CanvasControls();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Btn(
            label: 'Undo',
            enabled: state.canvas.canUndo,
            onTap: () => context.read<AppState>().undo()),
        const SizedBox(width: 6),
        _Btn(
          label: 'Clear',
          enabled: state.canvas.hasStrokes,
          onTap: () => context.read<AppState>().clear(),
        ),
      ],
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
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 80, 6),
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
                    borderSide: const BorderSide(color: kBorder)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kBorder)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kAccent, width: 1)),
                suffixIcon: _ctrl.text.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _ctrl.clear();
                          context.read<AppState>().setSearchQuery('');
                        },
                        child: const Icon(Icons.close,
                            color: kTextMuted, size: 14))
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
                onTap: () => context.read<AppState>().resetPinned()),
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
              borderRadius: BorderRadius.circular(4)),
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
                          bottom: BorderSide(color: kBorder.withOpacity(0.5)))),
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
                        ])),
                  ]),
                ),
              );
            },
          ),
        ),
    ]);
  }
}

// ── Info area ─────────────────────────────────────────────────────────────────

class _InfoArea extends StatelessWidget {
  const _InfoArea();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.pinnedEntry != null) {
      final entry = state.pinnedEntry!;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(entry.vocabulary,
              style: const TextStyle(
                  color: kAccent,
                  fontSize: 72,
                  fontWeight: FontWeight.w200,
                  height: 1)),
          const SizedBox(height: 8),
          if (state.realtimeCandidates.isNotEmpty)
            _TopCandidateChips(candidates: state.realtimeCandidates),
          const SizedBox(height: 8),
          if (entry.pinyin != null)
            Text(entry.pinyin!,
                style: const TextStyle(
                    color: kTextPrimary, fontSize: 16, letterSpacing: 0.5)),
          if (entry.bopomofo != null)
            Text(entry.bopomofo!,
                style: const TextStyle(color: kTextSecondary, fontSize: 13)),
          const SizedBox(height: 6),
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
          const SizedBox(height: 10),
          _SearchBtn(char: entry.vocabulary),
          const SizedBox(height: 10),
          const Divider(color: kBorder, height: 1),
        ]),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: const _ResultArea(),
    );
  }
}

class _TopCandidateChips extends StatelessWidget {
  final List<RealtimeCandidate> candidates;
  const _TopCandidateChips({required this.candidates});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: candidates.take(4).map((c) {
        final isTop = c == candidates.first;
        final color = isTop ? kAccent : kTextMuted;
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                border:
                    Border.all(color: isTop ? color.withOpacity(0.5) : kBorder),
                borderRadius: BorderRadius.circular(3)),
            child: Text(
              c.text,
              style: TextStyle(
                  color: isTop ? color : kTextMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w200),
            ),
          ),
        );
      }).toList(),
    );
  }
}
// ── Result area ───────────────────────────────────────────────────────────────

class _ResultArea extends StatelessWidget {
  const _ResultArea();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.busy)
      return const Text('Saving…',
          style: TextStyle(color: kTextSecondary, fontSize: 12));

    final r = state.result;
    if (r == null)
      return const Text('Pin chữ rồi vẽ để realtime compare',
          style: TextStyle(color: kTextMuted, fontSize: 12, letterSpacing: 1));
    if (r.error != null)
      return Text(r.error!,
          style: const TextStyle(color: kError, fontSize: 11));
    if (r.matches.isEmpty)
      return const Text('No proto match',
          style: TextStyle(color: kTextMuted, fontSize: 12));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 10),
        child: Divider(color: kBorder, height: 1, thickness: 1),
      ),
      ...r.matches
          .map((e) => _EntryCard(entry: e, showStrokeOrder: true))
          .toList(),
    ]);
  }
}

// ── Entry card ────────────────────────────────────────────────────────────────

class _EntryCard extends StatelessWidget {
  final VocabEntry entry;
  final bool showStrokeOrder;
  const _EntryCard(
      {required this.entry,
      this.showStrokeOrder = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text(entry.vocabulary,
                style: const TextStyle(
                    color: kAccent,
                    fontSize: 48,
                    fontWeight: FontWeight.w200,
                    height: 1)),
          ]),
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
              ])),
        ]),
        if (showStrokeOrder) ...[
          const SizedBox(height: 8),
          _SearchBtn(char: entry.vocabulary)
        ],
        const SizedBox(height: 4),
        const Divider(color: kBorder, height: 1),
      ]),
    );
  }
}

// ── Stroke order button ───────────────────────────────────────────────────────

class _SearchBtn extends StatelessWidget {
  final String char;
  const _SearchBtn({required this.char});

  @override
  Widget build(BuildContext context) {
    final c = char.isNotEmpty ? char.characters.first : char;
    final encoded = Uri.encodeComponent(c);
    final url = 'https://hanzii.net/search/word/$encoded?hl=vi';
    return GestureDetector(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri))
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Search',
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
            borderRadius: BorderRadius.circular(3)),
        child: Text(label,
            style: const TextStyle(
                color: kTextMuted, fontSize: 9, letterSpacing: 0.5)),
      );
}

// ── Button ────────────────────────────────────────────────────────────────────
class _MiniChip extends StatelessWidget {
  final String label;
  const _MiniChip(this.label);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: kTextMuted,
            fontSize: 9,
            letterSpacing: 0.4,
          ),
        ),
      );
}

class _Btn extends StatelessWidget {
  final String label;
  final bool enabled, accent;
  final VoidCallback onTap;
  const _Btn(
      {required this.label,
      required this.enabled,
      required this.onTap,
      this.accent = false});

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
            borderRadius: BorderRadius.circular(4)),
        child: Text(label,
            style: TextStyle(color: fg, fontSize: 11, letterSpacing: 1)),
      ),
    );
  }
}
