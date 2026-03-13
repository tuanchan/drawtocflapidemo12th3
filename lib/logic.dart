// logic.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const double kLogicalSize = 360.0;
const String kDbAsset = 'assets/db/tocfl_vocab_clean.db';
const String kDbFile = 'tocfl_vocab_clean.db';
const String kTable = 'vocab_clean';
const int kTopK = 10;

const MethodChannel _visionChannel = MethodChannel('tocfl_writer/vision_ocr');

// ── Platform helper ───────────────────────────────────────────────────────────

bool get _isIOS => !kIsWeb && Platform.isIOS;

// ── Stroke / Canvas ───────────────────────────────────────────────────────────

class StrokePoint {
  final double x, y;
  final int t;
  const StrokePoint(this.x, this.y, this.t);
}

class StrokeData {
  final List<StrokePoint> points;
  const StrokeData(this.points);
  bool get isEmpty => points.isEmpty;
}

class CanvasData {
  final List<StrokeData> strokes;
  final List<StrokeData> redo;
  final StrokeData? active;

  const CanvasData({
    this.strokes = const [],
    this.redo = const [],
    this.active,
  });

  bool get hasStrokes => strokes.isNotEmpty || active != null;
  bool get canUndo => strokes.isNotEmpty;

  static double _c(double v) => v.clamp(0.0, kLogicalSize);
  static int _now() => DateTime.now().millisecondsSinceEpoch;

  CanvasData startStroke(double x, double y) => CanvasData(
        strokes: strokes,
        redo: const [],
        active: StrokeData([StrokePoint(_c(x), _c(y), _now())]),
      );

  CanvasData addPoint(double x, double y) {
    if (active == null) return this;

    final nx = _c(x);
    final ny = _c(y);
    final pts = active!.points;

    if (pts.isNotEmpty) {
      final last = pts.last;
      if ((last.x - nx).abs() < 0.35 && (last.y - ny).abs() < 0.35) {
        return this;
      }
    }

    return CanvasData(
      strokes: strokes,
      redo: redo,
      active: StrokeData([
        ...pts,
        StrokePoint(nx, ny, _now()),
      ]),
    );
  }

  CanvasData endStroke() {
    if (active == null || active!.isEmpty) {
      return CanvasData(strokes: strokes, redo: redo);
    }
    return CanvasData(
      strokes: [...strokes, active!],
      redo: redo,
    );
  }

  CanvasData undo() {
    if (strokes.isEmpty) return this;
    return CanvasData(
      strokes: strokes.sublist(0, strokes.length - 1),
      redo: [...redo, strokes.last],
    );
  }

  CanvasData clear() => const CanvasData();
}

// ── Vocab model ───────────────────────────────────────────────────────────────

class VocabEntry {
  final String vocabulary;
  final String? pinyin;
  final String? levelCode;
  final String? context;
  final String? partOfSpeech;
  final String? bopomofo;
  final String? variantGroup;

  const VocabEntry({
    required this.vocabulary,
    this.pinyin,
    this.levelCode,
    this.context,
    this.partOfSpeech,
    this.bopomofo,
    this.variantGroup,
  });

  factory VocabEntry.fromMap(Map<String, dynamic> m) => VocabEntry(
        vocabulary: (m['vocabulary'] ?? '') as String,
        pinyin: _cleanNullable(m['pinyin']),
        levelCode: _cleanNullable(m['level_code']),
        context: _cleanNullable(m['context']),
        partOfSpeech: _cleanNullable(m['part_of_speech']),
        bopomofo: _cleanNullable(m['bopomofo']),
        variantGroup: _cleanNullable(m['variant_group']),
      );

  static String? _cleanNullable(dynamic v) {
    final s = (v as String?)?.trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }
}

class RecResult {
  final List<VocabEntry> matches;
  final List<String> raw;
  final String? error;

  const RecResult({
    this.matches = const [],
    this.raw = const [],
    this.error,
  });
}

// ── DB Service ────────────────────────────────────────────────────────────────

class DbService {
  static Database? _db;

  static Future<void> init() async {
    if (_db != null) return;

    Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } catch (_) {
      dir = await getTemporaryDirectory();
    }

    final path = p.join(dir.path, kDbFile);

    if (!File(path).existsSync()) {
      final data = await rootBundle.load(kDbAsset);
      final bytes = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await File(path).writeAsBytes(bytes, flush: true);
    }

    _db = await openDatabase(path, readOnly: true);
  }

  static Database get db => _db!;

  static Future<List<VocabEntry>> search(String q) async {
    final s = q.trim();
    if (s.isEmpty) return [];

    final rows = await db.rawQuery(
      '''
      SELECT *
      FROM $kTable
      WHERE vocabulary LIKE ?
         OR pinyin LIKE ?
         OR bopomofo LIKE ?
         OR variant_group LIKE ?
      LIMIT 20
      ''',
      ['%$s%', '%$s%', '%$s%', '%$s%'],
    );

    return rows.map(VocabEntry.fromMap).toList();
  }

  static Future<List<VocabEntry>> findByVocabularyTokens(
    List<String> tokens,
  ) async {
    final clean =
        tokens.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();

    if (clean.isEmpty) return [];

    final placeholders = List.filled(clean.length, '?').join(',');
    final rows = await db.rawQuery(
      '''
      SELECT *
      FROM $kTable
      WHERE vocabulary IN ($placeholders)
      LIMIT 50
      ''',
      clean,
    );

    return rows.map(VocabEntry.fromMap).toList();
  }
}

// ── Canvas Render Service ─────────────────────────────────────────────────────

class CanvasRenderService {
  static Future<Uint8List> renderPngBytes(
    List<StrokeData> strokes, {
    required double strokeWidth,
    int imageSize = 512,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final scale = imageSize / kLogicalSize;

    // nền trắng cho OCR
    canvas.drawRect(
      Rect.fromLTWH(0, 0, imageSize.toDouble(), imageSize.toDouble()),
      Paint()..color = Colors.white,
    );

    // vẽ nét đen
    final ink = Paint()
      ..color = Colors.black
      ..strokeWidth = strokeWidth * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final s in strokes) {
      if (s.points.isEmpty) continue;

      if (s.points.length == 1) {
        canvas.drawCircle(
          Offset(s.points.first.x * scale, s.points.first.y * scale),
          (strokeWidth * 0.5 + 1.0) * scale,
          ink,
        );
        continue;
      }

      final path = Path()
        ..moveTo(s.points.first.x * scale, s.points.first.y * scale);

      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x * scale, pt.y * scale);
      }
      canvas.drawPath(path, ink);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(imageSize, imageSize);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData == null) {
      throw Exception('Không render được canvas thành PNG.');
    }

    return byteData.buffer.asUint8List();
  }
}

// ── Vision OCR Service (iOS native bridge) ────────────────────────────────────

class VisionOcrService {
  static Future<List<String>> recognizeCanvasPng(
    Uint8List pngBytes, {
    int maxCandidates = kTopK,
  }) async {
    if (!_isIOS) {
      throw Exception('Vision OCR bridge hiện chỉ hỗ trợ iOS.');
    }

    final result = await _visionChannel.invokeMethod<List<dynamic>>(
      'recognizeCanvasText',
      <String, dynamic>{
        'imageBytes': pngBytes,
        'maxCandidates': maxCandidates,
        'recognitionLevel': 'accurate',
        'languages': <String>['zh-Hant', 'zh-Hans', 'en-US'],
      },
    );

    return (result ?? const [])
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }
}

// ── App State ─────────────────────────────────────────────────────────────────

class AppState extends ChangeNotifier {
  bool _ready = false;
  String? _initError;
  bool _busy = false;
  CanvasData _canvas = const CanvasData();
  RecResult? _result;
  double _strokeWidth = 10.0;

  String _searchQuery = '';
  List<VocabEntry> _searchSuggestions = [];
  VocabEntry? _pinnedEntry;
  Timer? _searchDebounce;

  bool _showPinnedTemplate = false;

  bool get ready => _ready;
  String? get initError => _initError;
  bool get busy => _busy;
  CanvasData get canvas => _canvas;
  RecResult? get result => _result;
  double get strokeWidth => _strokeWidth;
  bool get canCheck => _canvas.strokes.isNotEmpty && !_busy;
  String get searchQuery => _searchQuery;
  List<VocabEntry> get searchSuggestions => _searchSuggestions;
  VocabEntry? get pinnedEntry => _pinnedEntry;
  bool get showPinnedTemplate => _showPinnedTemplate;

  Future<void> init() async {
    try {
      await DbService.init();
    } catch (e, st) {
      debugPrint('[AppState.init] $e');
      debugPrint(st.toString());
      _initError = e.toString();
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  void setStrokeWidth(double v) {
    _strokeWidth = v.clamp(4.0, 24.0);
    notifyListeners();
  }

  void togglePinnedTemplate() {
    _showPinnedTemplate = !_showPinnedTemplate;
    notifyListeners();
  }

  void strokeStart(double x, double y) {
    _canvas = _canvas.startStroke(x, y);
    notifyListeners();
  }

  void strokeAdd(double x, double y) {
    _canvas = _canvas.addPoint(x, y);
    notifyListeners();
  }

  void strokeEnd() {
    _canvas = _canvas.endStroke();
    notifyListeners();
  }

  void undo() {
    _canvas = _canvas.undo();
    _result = null;
    notifyListeners();
  }

  void clear() {
    _canvas = _canvas.clear();
    _result = null;
    notifyListeners();
  }

  void setSearchQuery(String q) {
    _searchQuery = q;
    _searchDebounce?.cancel();

    if (q.trim().isEmpty) {
      _searchSuggestions = [];
      notifyListeners();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        _searchSuggestions = await DbService.search(q);
      } catch (_) {
        _searchSuggestions = [];
      }
      notifyListeners();
    });
  }

  void selectSuggestion(VocabEntry entry) {
    _pinnedEntry = entry;
    _showPinnedTemplate = true;
    _searchQuery = '';
    _searchSuggestions = [];
    notifyListeners();
  }

  void resetPinned() {
    _pinnedEntry = null;
    _showPinnedTemplate = false;
    notifyListeners();
  }

  Future<void> recognize() async {
    if (_busy || _canvas.strokes.isEmpty) return;

    if (!_isIOS) {
      _result = const RecResult(
        error: 'Bản Vision OCR này chỉ chạy trên iPhone/iOS.',
      );
      notifyListeners();
      return;
    }

    _busy = true;
    _result = null;
    notifyListeners();

    try {
      final pngBytes = await CanvasRenderService.renderPngBytes(
        _canvas.strokes,
        strokeWidth: _strokeWidth,
      );

      final raw = await VisionOcrService.recognizeCanvasPng(
        pngBytes,
        maxCandidates: kTopK,
      );

      if (raw.isEmpty) {
        _result = const RecResult(raw: []);
        return;
      }

      final tokens = _buildLookupTokens(raw);
      var matches = await DbService.findByVocabularyTokens(tokens);
      matches = _sortMatchesByCandidateOrder(matches, raw);

      _result = RecResult(matches: matches, raw: raw);
    } catch (e, st) {
      debugPrint('[recognize] $e');
      debugPrint(st.toString());
      _result = RecResult(error: e.toString());
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  List<String> _buildLookupTokens(List<String> raw) {
    final set = <String>{};

    for (final item in raw) {
      final s = item.trim();
      if (s.isEmpty) continue;

      set.add(s);

      for (final rune in s.runes) {
        final ch = String.fromCharCode(rune).trim();
        if (ch.isNotEmpty) set.add(ch);
      }
    }

    return set.toList();
  }

  List<VocabEntry> _sortMatchesByCandidateOrder(
    List<VocabEntry> entries,
    List<String> raw,
  ) {
    final exactOrder = <String, int>{};
    for (var i = 0; i < raw.length; i++) {
      exactOrder.putIfAbsent(raw[i], () => i);
    }

    int score(VocabEntry e) {
      if (exactOrder.containsKey(e.vocabulary)) {
        return exactOrder[e.vocabulary]!;
      }

      var best = 9999;
      for (final rune in e.vocabulary.runes) {
        final ch = String.fromCharCode(rune);
        final idx = raw.indexOf(ch);
        if (idx >= 0 && idx < best) best = idx + 100;
      }
      return best;
    }

    final list = [...entries];
    list.sort((a, b) {
      final sa = score(a);
      final sb = score(b);
      if (sa != sb) return sa.compareTo(sb);
      if (a.vocabulary.length != b.vocabulary.length) {
        return a.vocabulary.length.compareTo(b.vocabulary.length);
      }
      return a.vocabulary.compareTo(b.vocabulary);
    });
    return list;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }
}
