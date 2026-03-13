// logic.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
const String kTableSamples = 'handwriting_samples';
const int kTopK = 10;
const int kDbVersion = 2;

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
    final nx = _c(x), ny = _c(y);
    final pts = active!.points;
    if (pts.isNotEmpty) {
      final last = pts.last;
      if ((last.x - nx).abs() < 0.35 && (last.y - ny).abs() < 0.35) return this;
    }
    return CanvasData(
      strokes: strokes,
      redo: redo,
      active: StrokeData([...pts, StrokePoint(nx, ny, _now())]),
    );
  }

  CanvasData endStroke() {
    if (active == null || active!.isEmpty) {
      return CanvasData(strokes: strokes, redo: redo);
    }
    return CanvasData(strokes: [...strokes, active!], redo: redo);
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
    return (s == null || s.isEmpty) ? null : s;
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

// ── Toast Message ─────────────────────────────────────────────────────────────

/// Carries a one-shot toast payload.  UI calls [consume] after showing it.
class ToastMessage {
  final String char;
  final int embeddingCount;

  const ToastMessage({required this.char, required this.embeddingCount});

  /// E.g.  "學 · 嵌入 #7"
  String get label => '$char · 嵌入 #$embeddingCount';
}

// ── Stroke Serializer ─────────────────────────────────────────────────────────

class StrokeSerializer {
  static String toJson(List<StrokeData> strokes) {
    final data = strokes
        .map((s) => {
              'points':
                  s.points.map((p) => {'x': p.x, 'y': p.y, 't': p.t}).toList(),
            })
        .toList();
    return jsonEncode(data);
  }

  static List<StrokeData> fromJson(String json) {
    final List<dynamic> data = jsonDecode(json);
    return data.map((s) {
      final pts = (s['points'] as List)
          .map((p) => StrokePoint(
                (p['x'] as num).toDouble(),
                (p['y'] as num).toDouble(),
                p['t'] as int,
              ))
          .toList();
      return StrokeData(pts);
    }).toList();
  }
}

// ── Stroke Features ───────────────────────────────────────────────────────────

class StrokeFeatures {
  final List<double> values;
  const StrokeFeatures(this.values);
  static const int dimension = 12;

  factory StrokeFeatures.fromStrokes(List<StrokeData> strokes) {
    if (strokes.isEmpty) return StrokeFeatures(List.filled(dimension, 0.0));

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    int totalPoints = 0;
    int dirR = 0, dirD = 0, dirL = 0, dirU = 0, dirTotal = 0;
    double totalLength = 0;

    for (final s in strokes) {
      for (final pt in s.points) {
        if (pt.x < minX) minX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y > maxY) maxY = pt.y;
        totalPoints++;
      }
      for (var i = 1; i < s.points.length; i++) {
        final dx = s.points[i].x - s.points[i - 1].x;
        final dy = s.points[i].y - s.points[i - 1].y;
        final len = math.sqrt(dx * dx + dy * dy);
        totalLength += len;
        if (len < 0.5) continue;
        dirTotal++;
        final angle = math.atan2(dy, dx);
        if (angle >= -math.pi / 4 && angle < math.pi / 4)
          dirR++;
        else if (angle >= math.pi / 4 && angle < 3 * math.pi / 4)
          dirD++;
        else if (angle >= 3 * math.pi / 4 || angle < -3 * math.pi / 4)
          dirL++;
        else
          dirU++;
      }
    }

    final bboxW = (maxX - minX).clamp(0.0, kLogicalSize) / kLogicalSize;
    final bboxH = (maxY - minY).clamp(0.0, kLogicalSize) / kLogicalSize;
    final aspect = bboxH > 0 ? bboxW / bboxH : 1.0;
    final dt = dirTotal > 0 ? dirTotal.toDouble() : 1.0;

    return StrokeFeatures([
      strokes.length / 20.0,
      totalPoints / 500.0,
      (totalPoints / strokes.length) / 50.0,
      bboxW,
      bboxH,
      aspect.clamp(0.0, 3.0) / 3.0,
      bboxW * bboxH,
      dirR / dt,
      dirD / dt,
      dirL / dt,
      dirU / dt,
      (totalLength / totalPoints.clamp(1, 99999)) / kLogicalSize,
    ]);
  }

  double cosineSimilarity(StrokeFeatures other) {
    double dot = 0, normA = 0, normB = 0;
    for (var i = 0; i < dimension; i++) {
      dot += values[i] * other.values[i];
      normA += values[i] * values[i];
      normB += other.values[i] * other.values[i];
    }
    final denom = math.sqrt(normA) * math.sqrt(normB);
    if (denom < 1e-10) return 0.0;
    return (dot / denom).clamp(0.0, 1.0);
  }

  static StrokeFeatures average(List<StrokeFeatures> list) {
    if (list.isEmpty) return StrokeFeatures(List.filled(dimension, 0.0));
    final avg = List.filled(dimension, 0.0);
    for (final f in list) {
      for (var i = 0; i < dimension; i++) avg[i] += f.values[i];
    }
    return StrokeFeatures(avg.map((v) => v / list.length).toList());
  }

  String toJson() => jsonEncode(values);

  factory StrokeFeatures.fromJson(String json) {
    final list =
        (jsonDecode(json) as List).map((e) => (e as num).toDouble()).toList();
    return StrokeFeatures(list);
  }
}

// ── Similarity Result ─────────────────────────────────────────────────────────

class SimilarityResult {
  final double score;
  final int samplesCompared;
  final String feedback;

  const SimilarityResult({
    required this.score,
    required this.samplesCompared,
    required this.feedback,
  });

  bool get isConsistent => score >= 0.80;
  bool get isGood => score >= 0.65;
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

    _db = await openDatabase(
      path,
      version: kDbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await _createTables(db);
  }

  static Future<void> _onUpgrade(Database db, int old, int newV) async {
    if (old < 2) {
      for (final sql in [
        'ALTER TABLE $kTable ADD COLUMN practice_count INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE $kTable ADD COLUMN last_practiced_at TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {}
      }
      await _createTables(db);
    }
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $kTableSamples (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        vocabulary    TEXT    NOT NULL,
        stroke_json   TEXT    NOT NULL,
        png_base64    TEXT,
        feature_json  TEXT,
        stroke_count  INTEGER NOT NULL DEFAULT 0,
        stroke_width  REAL    NOT NULL DEFAULT 10.0,
        ocr_raw       TEXT,
        ocr_matched   INTEGER NOT NULL DEFAULT 0,
        created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_samples_vocab   ON $kTableSamples(vocabulary)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_samples_created ON $kTableSamples(vocabulary, created_at DESC)',
    );
  }

  static Database get db => _db!;

  // ── Vocab ─────────────────────────────────────────────────────────────────

  static Future<List<VocabEntry>> search(String q) async {
    final s = q.trim();
    if (s.isEmpty) return [];
    final rows = await db.rawQuery(
      '''
      SELECT * FROM $kTable
      WHERE vocabulary LIKE ? OR pinyin LIKE ?
         OR bopomofo LIKE ? OR variant_group LIKE ?
      LIMIT 20
      ''',
      ['%$s%', '%$s%', '%$s%', '%$s%'],
    );
    return rows.map(VocabEntry.fromMap).toList();
  }

  static Future<List<VocabEntry>> findByVocabularyTokens(
      List<String> tokens) async {
    final clean =
        tokens.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    if (clean.isEmpty) return [];
    final ph = List.filled(clean.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM $kTable WHERE vocabulary IN ($ph) LIMIT 50',
      clean,
    );
    return rows.map(VocabEntry.fromMap).toList();
  }

  // ── Practice count ────────────────────────────────────────────────────────

  static Future<void> incrementPracticeCount(String vocabulary) async {
    await db.execute(
      '''
      UPDATE $kTable
      SET practice_count    = practice_count + 1,
          last_practiced_at = datetime('now')
      WHERE vocabulary = ?
      ''',
      [vocabulary],
    );
  }

  static Future<int> getPracticeCount(String vocabulary) async {
    final rows = await db.rawQuery(
      'SELECT practice_count FROM $kTable WHERE vocabulary = ? LIMIT 1',
      [vocabulary],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['practice_count'] as int?) ?? 0;
  }

  // ── Samples ───────────────────────────────────────────────────────────────

  static Future<int> saveSample({
    required String vocabulary,
    required String strokeJson,
    required String? pngBase64,
    required int strokeCount,
    required double strokeWidth,
    required List<String> ocrRaw,
    required bool ocrMatched,
    String? featureJson,
  }) async {
    return db.insert(kTableSamples, {
      'vocabulary': vocabulary,
      'stroke_json': strokeJson,
      'png_base64': pngBase64,
      'feature_json': featureJson,
      'stroke_count': strokeCount,
      'stroke_width': strokeWidth,
      'ocr_raw': ocrRaw.isNotEmpty ? ocrRaw.join('|') : null,
      'ocr_matched': ocrMatched ? 1 : 0,
    });
  }

  static Future<int> getSampleCount(String vocabulary) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $kTableSamples WHERE vocabulary = ?',
      [vocabulary],
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  static Future<List<Map<String, dynamic>>> getRecentSamples(String vocabulary,
      {int limit = 10}) async {
    return db.rawQuery(
      '''
      SELECT feature_json, ocr_matched, created_at
      FROM $kTableSamples
      WHERE vocabulary = ? AND feature_json IS NOT NULL
      ORDER BY created_at DESC LIMIT ?
      ''',
      [vocabulary, limit],
    );
  }

  static Future<Map<String, dynamic>> getVocabStats(String vocabulary) async {
    final rows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS total, SUM(ocr_matched) AS matched, MAX(created_at) AS last_at
      FROM $kTableSamples WHERE vocabulary = ?
      ''',
      [vocabulary],
    );
    final practice = await getPracticeCount(vocabulary);
    final row = rows.first;
    final total = (row['total'] as int?) ?? 0;
    final matched = (row['matched'] as int?) ?? 0;
    return {
      'practice_count': practice,
      'sample_count': total,
      'ocr_accuracy': total > 0 ? matched / total : 0.0,
      'last_practiced': row['last_at'],
    };
  }
}

// ── Local Learning Service ────────────────────────────────────────────────────

class LocalLearningService {
  static Future<SimilarityResult?> onCheck({
    required List<StrokeData> strokes,
    required String vocabulary,
    required List<String> ocrRaw,
    required double strokeWidth,
  }) async {
    if (strokes.isEmpty || vocabulary.isEmpty) return null;

    final features = StrokeFeatures.fromStrokes(strokes);
    final strokeJson = StrokeSerializer.toJson(strokes);
    final ocrMatched = ocrRaw.contains(vocabulary) ||
        ocrRaw.any((r) => r.contains(vocabulary));

    await DbService.saveSample(
      vocabulary: vocabulary,
      strokeJson: strokeJson,
      pngBase64: null,
      strokeCount: strokes.length,
      strokeWidth: strokeWidth,
      ocrRaw: ocrRaw,
      ocrMatched: ocrMatched,
      featureJson: features.toJson(),
    );

    await DbService.incrementPracticeCount(vocabulary);

    return _compare(strokes: strokes, vocabulary: vocabulary);
  }

  static Future<SimilarityResult?> _compare({
    required List<StrokeData> strokes,
    required String vocabulary,
  }) async {
    final rows = await DbService.getRecentSamples(vocabulary, limit: 10);
    if (rows.length < 2) return null;

    final stored = <StrokeFeatures>[];
    for (final row in rows) {
      final fJson = row['feature_json'] as String?;
      if (fJson != null && fJson.isNotEmpty) {
        try {
          stored.add(StrokeFeatures.fromJson(fJson));
        } catch (_) {}
      }
    }
    if (stored.isEmpty) return null;

    final current = StrokeFeatures.fromStrokes(strokes);
    final avg = StrokeFeatures.average(stored);
    final score = current.cosineSimilarity(avg);

    final feedback = score >= 0.85
        ? '一致性優秀 ${(score * 100).round()}%'
        : score >= 0.70
            ? '寫法穩定 ${(score * 100).round()}%'
            : score >= 0.55
                ? '略有差異 ${(score * 100).round()}%'
                : '筆法不同 ${(score * 100).round()}% — 再試試';

    return SimilarityResult(
      score: score,
      samplesCompared: stored.length,
      feedback: feedback,
    );
  }

  static Future<Map<String, double>> getBoostScores(
      List<String> vocabularies) async {
    final scores = <String, double>{};
    for (final v in vocabularies) {
      final count = await DbService.getPracticeCount(v);
      scores[v] = math.min(count / 5.0 * 0.1, 0.5);
    }
    return scores;
  }
}

// ── Canvas Render Service ─────────────────────────────────────────────────────

class CanvasRenderService {
  static const double kOcrStrokeBoost = 1.5;
  static const double kPaddingRatio = 0.20;

  static Future<Uint8List> renderPngBytes(
    List<StrokeData> strokes, {
    required double strokeWidth,
    int imageSize = 512,
  }) async {
    if (strokes.isEmpty) throw Exception('Không có nét vẽ để render.');

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final s in strokes) {
      for (final pt in s.points) {
        if (pt.x < minX) minX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y > maxY) maxY = pt.y;
      }
    }

    final rawW = (maxX - minX).clamp(1.0, double.infinity);
    final rawH = (maxY - minY).clamp(1.0, double.infinity);
    final padX = rawW * kPaddingRatio;
    final padY = rawH * kPaddingRatio;

    final cropX = (minX - padX).clamp(0.0, kLogicalSize);
    final cropY = (minY - padY).clamp(0.0, kLogicalSize);
    final cropMaxX = (maxX + padX).clamp(0.0, kLogicalSize);
    final cropMaxY = (maxY + padY).clamp(0.0, kLogicalSize);
    final cropW = (cropMaxX - cropX).clamp(1.0, kLogicalSize);
    final cropH = (cropMaxY - cropY).clamp(1.0, kLogicalSize);

    final cropSide = cropW > cropH ? cropW : cropH;
    final scale = imageSize / cropSide;
    final offsetX = (imageSize - cropW * scale) / 2 - cropX * scale;
    final offsetY = (imageSize - cropH * scale) / 2 - cropY * scale;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, imageSize.toDouble(), imageSize.toDouble()),
      Paint()..color = Colors.white,
    );

    final boosted = strokeWidth * kOcrStrokeBoost;
    final ink = Paint()
      ..color = Colors.black
      ..strokeWidth = boosted * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final s in strokes) {
      if (s.points.isEmpty) continue;
      if (s.points.length == 1) {
        canvas.drawCircle(
          Offset(s.points.first.x * scale + offsetX,
              s.points.first.y * scale + offsetY),
          (boosted * 0.5 + 1.0) * scale,
          ink,
        );
        continue;
      }
      final path = Path()
        ..moveTo(s.points.first.x * scale + offsetX,
            s.points.first.y * scale + offsetY);
      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x * scale + offsetX, pt.y * scale + offsetY);
      }
      canvas.drawPath(path, ink);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(imageSize, imageSize);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null)
      throw Exception('Không render được canvas thành PNG.');
    return byteData.buffer.asUint8List();
  }
}

// ── Vision OCR Service ────────────────────────────────────────────────────────

class VisionOcrService {
  static Future<List<String>> recognizeCanvasPng(
    Uint8List pngBytes, {
    int maxCandidates = kTopK,
  }) async {
    if (!_isIOS) throw Exception('Vision OCR bridge hiện chỉ hỗ trợ iOS.');

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

  SimilarityResult? _similarityResult;

  /// One-shot toast fired after an embedding is saved.
  /// UI should read and then call [consumeToast].
  ToastMessage? _pendingToast;

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
  SimilarityResult? get similarityResult => _similarityResult;
  ToastMessage? get pendingToast => _pendingToast;

  /// Called by the UI after it has displayed the toast.
  void consumeToast() {
    if (_pendingToast == null) return;
    _pendingToast = null;
    // No notifyListeners — avoids rebuild loop.
  }

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
    _similarityResult = null;
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
    _similarityResult = null;
    notifyListeners();
  }

  Future<void> recognize() async {
    if (_busy || _canvas.strokes.isEmpty) return;

    if (!_isIOS) {
      _result = const RecResult(
          error: 'Bản Vision OCR này chỉ chạy trên iPhone/iOS.');
      notifyListeners();
      return;
    }

    _busy = true;
    _result = null;
    _similarityResult = null;
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

      // ── Feature-based fallback when OCR misses the pinned character ────────
      // If tmpl is active and we have ≥3 embeddings, compute cosine similarity.
      // If the score clears the threshold, inject the pinned entry as top match
      // regardless of what OCR said (or didn't say).
      VocabEntry? featureInjected;
      if (_showPinnedTemplate && _pinnedEntry != null) {
        final sampleRows = await DbService.getRecentSamples(
            _pinnedEntry!.vocabulary,
            limit: 10);
        if (sampleRows.length >= 3) {
          final stored = <StrokeFeatures>[];
          for (final row in sampleRows) {
            final fj = row['feature_json'] as String?;
            if (fj != null && fj.isNotEmpty) {
              try {
                stored.add(StrokeFeatures.fromJson(fj));
              } catch (_) {}
            }
          }
          if (stored.isNotEmpty) {
            final cur = StrokeFeatures.fromStrokes(_canvas.strokes);
            final sim = cur.cosineSimilarity(StrokeFeatures.average(stored));
            // Threshold: ≥0.60 → inject; more samples → lower threshold.
            final thresh = stored.length >= 7 ? 0.55 : 0.60;
            if (sim >= thresh) {
              featureInjected = _pinnedEntry;
            }
          }
        }
      }

      if (raw.isEmpty && featureInjected == null) {
        _result = const RecResult(raw: []);
        return;
      }

      final tokens = _buildLookupTokens(raw);
      var matches = await DbService.findByVocabularyTokens(tokens);

      // Inject feature-matched pinned entry at top if not already present.
      if (featureInjected != null &&
          !matches.any((e) => e.vocabulary == featureInjected!.vocabulary)) {
        matches = [featureInjected!, ...matches];
      }

      final vocabs = matches.map((e) => e.vocabulary).toList();
      final boosts = await LocalLearningService.getBoostScores(vocabs);
      // When feature-injected, keep it pinned at top regardless of sort.
      final sortedTail = featureInjected != null
          ? _sortMatchesByCandidateOrder(matches.skip(1).toList(), raw, boosts)
          : _sortMatchesByCandidateOrder(matches, raw, boosts);
      matches = featureInjected != null
          ? [featureInjected!, ...sortedTail]
          : sortedTail;

      _result = RecResult(matches: matches, raw: raw);

      // ── Local learning: save embedding + similarity + toast ──────────────
      if (_showPinnedTemplate && _pinnedEntry != null) {
        _similarityResult = await LocalLearningService.onCheck(
          strokes: _canvas.strokes,
          vocabulary: _pinnedEntry!.vocabulary,
          ocrRaw: raw,
          strokeWidth: _strokeWidth,
        );

        // Count total embeddings saved for this character and fire toast.
        final count = await DbService.getSampleCount(_pinnedEntry!.vocabulary);
        _pendingToast = ToastMessage(
          char: _pinnedEntry!.vocabulary,
          embeddingCount: count,
        );
      }
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
    Map<String, double> boosts,
  ) {
    final exactOrder = <String, int>{};
    for (var i = 0; i < raw.length; i++)
      exactOrder.putIfAbsent(raw[i], () => i);

    double score(VocabEntry e) {
      double base;
      if (exactOrder.containsKey(e.vocabulary)) {
        base = exactOrder[e.vocabulary]!.toDouble();
      } else {
        var best = 9999.0;
        for (final rune in e.vocabulary.runes) {
          final ch = String.fromCharCode(rune);
          final idx = raw.indexOf(ch);
          if (idx >= 0 && idx + 100.0 < best) best = idx + 100.0;
        }
        base = best;
      }
      return base - (boosts[e.vocabulary] ?? 0.0) * 100;
    }

    final list = [...entries];
    list.sort((a, b) {
      final diff = score(a).compareTo(score(b));
      if (diff != 0) return diff;
      if (a.vocabulary.length != b.vocabulary.length) {
        return a.vocabulary.compareTo(b.vocabulary);
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
