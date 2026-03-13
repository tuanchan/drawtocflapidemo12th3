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
const String kTableEmbeddings = 'char_embeddings';
const String kTablePrototypes = 'char_prototypes';
const int kTopK = 10;
const int kDbVersion = 3;

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

enum MatchSource { proto, ocr, none }

class RecResult {
  final List<VocabEntry> matches;
  final List<String> raw;
  final String? error;
  final MatchSource matchSource;

  const RecResult({
    this.matches = const [],
    this.raw = const [],
    this.error,
    this.matchSource = MatchSource.none,
  });
}

// ── Toast Message ─────────────────────────────────────────────────────────────

enum ToastStatus { saved, savedFallback, noModel, dbError }

class ToastMessage {
  final String char;
  final int embeddingCount;
  final ToastStatus status;
  final bool protoUpdated;
  final bool matchedByProto;

  const ToastMessage({
    required this.char,
    required this.embeddingCount,
    required this.status,
    this.protoUpdated = false,
    this.matchedByProto = false,
  });

  String get statusLabel {
    final matchTag = matchedByProto ? '原型匹配' : 'OCR';
    switch (status) {
      case ToastStatus.saved:
        return '$matchTag · 嵌入已儲存${protoUpdated ? ' · ✓' : ''}';
      case ToastStatus.savedFallback:
        return '$matchTag · rule-based 儲存';
      case ToastStatus.noModel:
        return '$matchTag · 未載入模型';
      case ToastStatus.dbError:
        return 'DB 寫入失敗';
    }
  }
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

// ── Check Result ──────────────────────────────────────────────────────────────

enum CheckSaveStatus { savedModel, savedFallback, noModel, dbError }

class CheckResult {
  final CheckSaveStatus saveStatus;
  final bool protoUpdated;
  final int embeddingCount;
  final double? similarity;
  final String? errorMsg;

  const CheckResult({
    required this.saveStatus,
    required this.protoUpdated,
    required this.embeddingCount,
    this.similarity,
    this.errorMsg,
  });

  bool get isDbError => saveStatus == CheckSaveStatus.dbError;

  String get feedbackText {
    if (isDbError) return 'DB 寫入失敗: ${errorMsg ?? ''}';
    if (saveStatus == CheckSaveStatus.noModel) return '未載入模型 · rule-based 儲存';
    final sim = similarity;
    if (sim == null) return protoUpdated ? '嵌入已儲存 · prototype 已更新' : '嵌入已儲存';
    if (sim >= 0.85) return '一致性優秀 ${(sim * 100).round()}%';
    if (sim >= 0.70) return '寫法穩定 ${(sim * 100).round()}%';
    if (sim >= 0.55) return '略有差異 ${(sim * 100).round()}%';
    return '筆法不同 ${(sim * 100).round()}% — 再試試';
  }

  SimilarityResult? get similarityResult => similarity == null
      ? null
      : SimilarityResult(
          score: similarity!,
          samplesCompared: embeddingCount,
          feedback: feedbackText,
        );

  ToastStatus get toastStatus {
    switch (saveStatus) {
      case CheckSaveStatus.savedModel:
        return ToastStatus.saved;
      case CheckSaveStatus.savedFallback:
        return ToastStatus.savedFallback;
      case CheckSaveStatus.noModel:
        return ToastStatus.noModel;
      case CheckSaveStatus.dbError:
        return ToastStatus.dbError;
    }
  }
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
      // practice_count may not exist in bundled DB — always wrap
      for (final sql in [
        'ALTER TABLE $kTable ADD COLUMN practice_count INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE $kTable ADD COLUMN last_practiced_at TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {}
      }
    }
    // v3: new embedding + prototype tables (idempotent via IF NOT EXISTS)
    await _createTables(db);
  }

  static Future<void> _createTables(Database db) async {
    // Legacy sample table (kept for OCR accuracy tracking)
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
    // Raw embeddings (one row per check)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $kTableEmbeddings (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        vocabulary    TEXT    NOT NULL,
        embedding_json TEXT   NOT NULL,
        is_fallback   INTEGER NOT NULL DEFAULT 0,
        created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    // EMA prototype per character
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $kTablePrototypes (
        vocabulary    TEXT    PRIMARY KEY,
        prototype_json TEXT   NOT NULL,
        count         INTEGER NOT NULL DEFAULT 1,
        updated_at    TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    for (final sql in [
      'CREATE INDEX IF NOT EXISTS idx_samples_vocab    ON $kTableSamples(vocabulary)',
      'CREATE INDEX IF NOT EXISTS idx_samples_created  ON $kTableSamples(vocabulary, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_emb_vocab        ON $kTableEmbeddings(vocabulary)',
    ]) {
      try {
        await db.execute(sql);
      } catch (_) {}
    }
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

  // ── Practice count (safe — reads from embedding table, not vocab_clean) ──────

  static Future<void> incrementPracticeCount(String vocabulary) async {
    // No-op: count is now derived from kTableEmbeddings.
  }

  static Future<int> getPracticeCount(String vocabulary) async {
    return getEmbeddingCount(vocabulary);
  }

  // ── Embeddings ────────────────────────────────────────────────────────────

  static Future<void> saveEmbedding({
    required String vocabulary,
    required String embJson,
    required bool isFallback,
  }) async {
    await db.insert(kTableEmbeddings, {
      'vocabulary': vocabulary,
      'embedding_json': embJson,
      'is_fallback': isFallback ? 1 : 0,
    });
  }

  static Future<int> getEmbeddingCount(String vocabulary) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $kTableEmbeddings WHERE vocabulary = ?',
      [vocabulary],
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  // ── Prototypes ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> getPrototype(String vocabulary) async {
    final rows = await db.rawQuery(
      'SELECT prototype_json, count FROM $kTablePrototypes WHERE vocabulary = ?',
      [vocabulary],
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> upsertPrototype({
    required String vocabulary,
    required String protoJson,
    required int count,
  }) async {
    await db.execute('''
      INSERT INTO $kTablePrototypes (vocabulary, prototype_json, count, updated_at)
      VALUES (?, ?, ?, datetime('now'))
      ON CONFLICT(vocabulary) DO UPDATE SET
        prototype_json = excluded.prototype_json,
        count          = excluded.count,
        updated_at     = excluded.updated_at
    ''', [vocabulary, protoJson, count]);
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
      SELECT ocr_matched, created_at
      FROM $kTableSamples
      WHERE vocabulary = ?
      ORDER BY created_at DESC LIMIT ?
      ''',
      [vocabulary, limit],
    );
  }

  static Future<Map<String, dynamic>> getVocabStats(String vocabulary) async {
    final embCount = await getEmbeddingCount(vocabulary);
    // OCR accuracy: tử số và mẫu số cùng từ handwriting_samples
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total, SUM(ocr_matched) AS matched FROM $kTableSamples WHERE vocabulary = ?',
      [vocabulary],
    );
    final total = (rows.first['total'] as int?) ?? 0;
    final matched = (rows.first['matched'] as int?) ?? 0;
    return {
      'embedding_count': embCount,
      'ocr_accuracy': total > 0 ? matched / total : 0.0,
    };
  }
}

// ── Embedding Encoder ─────────────────────────────────────────────────────────
// Interface for on-device encoder.  Swap in a real TFLite model by implementing
// the body of [encode].  Until then every call returns null → fallback is used.

class EmbeddingEncoder {
  static const int dim = 64;

  /// Run TFLite encoder inference.  Returns null when model is not loaded.
  static Future<List<double>?> encode(Uint8List pngBytes) async {
    // TODO: uncomment when model asset is added to pubspec + assets/:
    //
    // try {
    //   final interpreter = await tfl.Interpreter.fromAsset(
    //     'assets/models/encoder.tflite',
    //     options: tfl.InterpreterOptions()..threads = 2,
    //   );
    //   final input  = _preprocess(pngBytes); // [1, 64, 64, 1] float32
    //   final output = List.filled(dim, 0.0).reshape([1, dim]);
    //   interpreter.run(input, output);
    //   interpreter.close();
    //   return (output[0] as List).map((e) => (e as num).toDouble()).toList();
    // } catch (e) {
    //   debugPrint('[EmbeddingEncoder] $e');
    //   return null;
    // }

    return null; // ← model not available yet
  }

  /// Rule-based fallback: tile 12-dim StrokeFeatures up to [dim] dimensions.
  static List<double> fallback(List<StrokeData> strokes) {
    final base = StrokeFeatures.fromStrokes(strokes).values;
    final out = <double>[];
    while (out.length < dim) {
      for (final v in base) {
        if (out.length >= dim) break;
        out.add(v);
      }
    }
    return out;
  }
}

// ── Prototype Service ─────────────────────────────────────────────────────────

enum SaveEmbeddingStatus { ok, okFallback, dbError }

class SaveEmbeddingResult {
  final SaveEmbeddingStatus status;
  final int count;
  final String? errorMsg;

  const SaveEmbeddingResult._({
    required this.status,
    this.count = 0,
    this.errorMsg,
  });

  factory SaveEmbeddingResult.ok(int count) =>
      SaveEmbeddingResult._(status: SaveEmbeddingStatus.ok, count: count);
  factory SaveEmbeddingResult.okFallback(int count) => SaveEmbeddingResult._(
      status: SaveEmbeddingStatus.okFallback, count: count);
  factory SaveEmbeddingResult.dbError(String msg) =>
      SaveEmbeddingResult._(status: SaveEmbeddingStatus.dbError, errorMsg: msg);
}

class PrototypeService {
  /// EMA learning rate — new sample contributes 20 % to prototype.
  static const double _alpha = 0.20;

  /// Save embedding, update EMA prototype, return result with current count.
  static Future<SaveEmbeddingResult> saveAndUpdate({
    required String vocabulary,
    required List<double> embedding,
    required bool isFallback,
  }) async {
    try {
      await DbService.saveEmbedding(
        vocabulary: vocabulary,
        embJson: jsonEncode(embedding),
        isFallback: isFallback,
      );
    } catch (e) {
      return SaveEmbeddingResult.dbError(e.toString());
    }

    try {
      final proto = await DbService.getPrototype(vocabulary);
      final List<double> newProto;
      final int newCount;

      if (proto == null) {
        newProto = embedding;
        newCount = 1;
      } else {
        newCount = (proto['count'] as int) + 1;
        final old = (jsonDecode(proto['prototype_json'] as String) as List)
            .map((e) => (e as num).toDouble())
            .toList();
        // EMA: proto = (1-α)*old + α*new
        newProto = List.generate(
          embedding.length,
          (i) => old[i] * (1 - _alpha) + embedding[i] * _alpha,
        );
      }

      await DbService.upsertPrototype(
        vocabulary: vocabulary,
        protoJson: jsonEncode(newProto),
        count: newCount,
      );

      final count = await DbService.getEmbeddingCount(vocabulary);
      return isFallback
          ? SaveEmbeddingResult.okFallback(count)
          : SaveEmbeddingResult.ok(count);
    } catch (e) {
      return SaveEmbeddingResult.dbError(e.toString());
    }
  }

  /// Compute similarity against current prototype WITHOUT updating it.
  /// Call this BEFORE saveAndUpdate to avoid self-bias.
  static Future<double?> computeSimilarity({
    required String vocabulary,
    required List<double> embedding,
  }) async {
    final proto = await DbService.getPrototype(vocabulary);
    if (proto == null) return null;
    final protoVec = (jsonDecode(proto['prototype_json'] as String) as List)
        .map((e) => (e as num).toDouble())
        .toList();
    return _cosine(embedding, protoVec);
  }

  /// Cosine similarity between [embedding] and stored prototype. Null if no prototype yet.
  static Future<double?> similarityToPrototype({
    required String vocabulary,
    required List<double> embedding,
  }) async {
    final proto = await DbService.getPrototype(vocabulary);
    if (proto == null) return null;
    final protoVec = (jsonDecode(proto['prototype_json'] as String) as List)
        .map((e) => (e as num).toDouble())
        .toList();
    return _cosine(embedding, protoVec);
  }

  static double _cosine(List<double> a, List<double> b) {
    double dot = 0, nA = 0, nB = 0;
    final len = math.min(a.length, b.length);
    for (var i = 0; i < len; i++) {
      dot += a[i] * b[i];
      nA += a[i] * a[i];
      nB += b[i] * b[i];
    }
    final d = math.sqrt(nA) * math.sqrt(nB);
    return d < 1e-10 ? 0.0 : (dot / d).clamp(0.0, 1.0);
  }
}

// ── Local Learning Service ────────────────────────────────────────────────────

class LocalLearningService {
  /// Caller must pre-compute [embedding] and [isFallback] (encode once outside).
  static Future<CheckResult> onCheck({
    required String vocabulary,
    required List<String> ocrRaw,
    required double strokeWidth,
    required List<StrokeData> strokes,
    required List<double> embedding,
    required bool isFallback,
  }) async {
    if (vocabulary.isEmpty) {
      return CheckResult(
        saveStatus: CheckSaveStatus.dbError,
        protoUpdated: false,
        embeddingCount: 0,
        errorMsg: 'vocabulary empty',
      );
    }

    // 1. Compute similarity vs OLD prototype BEFORE updating (avoid self-bias)
    final simBefore = await PrototypeService.computeSimilarity(
      vocabulary: vocabulary,
      embedding: embedding,
    );

    // 2. Save embedding + update prototype
    final saveResult = await PrototypeService.saveAndUpdate(
      vocabulary: vocabulary,
      embedding: embedding,
      isFallback: isFallback,
    );

    if (saveResult.status == SaveEmbeddingStatus.dbError) {
      return CheckResult(
        saveStatus: CheckSaveStatus.dbError,
        protoUpdated: false,
        embeddingCount: 0,
        errorMsg: saveResult.errorMsg,
      );
    }

    // 3. Write to legacy samples table for OCR accuracy tracking
    final ocrMatched = ocrRaw.contains(vocabulary) ||
        ocrRaw.any((r) => r.contains(vocabulary));
    try {
      await DbService.saveSample(
        vocabulary: vocabulary,
        strokeJson: StrokeSerializer.toJson(strokes),
        pngBase64: null,
        strokeCount: strokes.length,
        strokeWidth: strokeWidth,
        ocrRaw: ocrRaw,
        ocrMatched: ocrMatched,
        featureJson: null,
      );
    } catch (_) {}

    final checkSaveStatus =
        isFallback ? CheckSaveStatus.noModel : CheckSaveStatus.savedModel;

    return CheckResult(
      saveStatus: checkSaveStatus,
      protoUpdated: true,
      embeddingCount: saveResult.count,
      similarity: simBefore,
    );
  }

  static Future<Map<String, double>> getBoostScores(
      List<String> vocabularies) async {
    final scores = <String, double>{};
    for (final v in vocabularies) {
      final count = await DbService.getEmbeddingCount(v);
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
  MatchSource _matchSource = MatchSource.none;

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
  MatchSource get matchSource => _matchSource;

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
    _matchSource = MatchSource.none;
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

    _busy = true;
    _result = null;
    _similarityResult = null;
    _matchSource = MatchSource.none;
    notifyListeners();

    try {
      // ── Step 1: Render PNG ───────────────────────────────────────────────
      final pngBytes = await CanvasRenderService.renderPngBytes(
        _canvas.strokes,
        strokeWidth: _strokeWidth,
      );

      // ── Step 2: Encode ONCE ──────────────────────────────────────────────
      final List<double>? tflEmb = await EmbeddingEncoder.encode(pngBytes);
      final bool isFallback = tflEmb == null;
      final List<double> embedding =
          tflEmb ?? EmbeddingEncoder.fallback(_canvas.strokes);

      // ── Step 3: Proto-first decision ─────────────────────────────────────
      bool matchedByProto = false;
      List<String> raw = const [];
      List<VocabEntry> matches = const [];

      if (_showPinnedTemplate && _pinnedEntry != null) {
        final count =
            await DbService.getEmbeddingCount(_pinnedEntry!.vocabulary);
        final simBefore = await PrototypeService.computeSimilarity(
          vocabulary: _pinnedEntry!.vocabulary,
          embedding: embedding,
        );

        // Count-adaptive threshold: more samples → lower bar
        final protoThresh = count >= 10
            ? 0.58
            : count >= 5
                ? 0.65
                : 0.75;

        if (simBefore != null && simBefore >= protoThresh) {
          // ── PROTO MATCH: skip OCR ───────────────────────────────────────
          matchedByProto = true;
          matches = [_pinnedEntry!];
          _matchSource = MatchSource.proto;
        }
      }

      if (!matchedByProto) {
        // ── FALLBACK: call OCR ──────────────────────────────────────────────
        if (!_isIOS) {
          _result = const RecResult(
            error: 'Vision OCR chỉ chạy trên iPhone/iOS.',
            matchSource: MatchSource.none,
          );
          return;
        }

        raw = await VisionOcrService.recognizeCanvasPng(
          pngBytes,
          maxCandidates: kTopK,
        );

        // Soft-inject pinned entry if OCR missed it but sim is close
        VocabEntry? softInjected;
        if (_showPinnedTemplate && _pinnedEntry != null && raw.isNotEmpty) {
          final sim = await PrototypeService.computeSimilarity(
            vocabulary: _pinnedEntry!.vocabulary,
            embedding: embedding,
          );
          final count =
              await DbService.getEmbeddingCount(_pinnedEntry!.vocabulary);
          final injectThresh = count >= 7 ? 0.50 : 0.55;
          if (sim != null &&
              sim >= injectThresh &&
              !raw.contains(_pinnedEntry!.vocabulary)) {
            softInjected = _pinnedEntry;
          }
        }

        if (raw.isEmpty && softInjected == null) {
          _result = const RecResult(
            raw: [],
            matchSource: MatchSource.ocr,
          );
          return;
        }

        final tokens = _buildLookupTokens(raw);
        final ocrMatches = await DbService.findByVocabularyTokens(tokens);
        final vocabs = ocrMatches.map((e) => e.vocabulary).toList();
        final boosts = await LocalLearningService.getBoostScores(vocabs);

        if (softInjected != null &&
            !ocrMatches.any((e) => e.vocabulary == softInjected!.vocabulary)) {
          final sortedTail =
              _sortMatchesByCandidateOrder(ocrMatches, raw, boosts);
          matches = [softInjected!, ...sortedTail];
        } else {
          matches = _sortMatchesByCandidateOrder(ocrMatches, raw, boosts);
        }
        _matchSource = MatchSource.ocr;
      }

      _result = RecResult(
        matches: matches,
        raw: raw,
        matchSource: _matchSource,
      );

      // ── Step 4: Save embedding + update prototype (always, after result) ──
      if (_showPinnedTemplate && _pinnedEntry != null) {
        final checkResult = await LocalLearningService.onCheck(
          vocabulary: _pinnedEntry!.vocabulary,
          ocrRaw: raw,
          strokeWidth: _strokeWidth,
          strokes: _canvas.strokes,
          embedding: embedding,
          isFallback: isFallback,
        );

        _similarityResult = checkResult.similarityResult;
        _pendingToast = ToastMessage(
          char: _pinnedEntry!.vocabulary,
          embeddingCount: checkResult.embeddingCount,
          status: checkResult.toastStatus,
          protoUpdated: checkResult.protoUpdated,
          matchedByProto: matchedByProto,
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
