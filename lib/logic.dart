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
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:archive/archive_io.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import 'package:uuid/uuid.dart';

// ── Proto Match Candidate ─────────────────────────────────────────────────────

class ProtoMatchCandidate {
  final String vocabulary;
  final double score;
  final int count;
  const ProtoMatchCandidate({
    required this.vocabulary,
    required this.score,
    required this.count,
  });
}

// ── Constants ─────────────────────────────────────────────────────────────────

const double kLogicalSize = 360.0;
const String kDbAsset = 'assets/db/tocfl_vocab_clean.db';
const String kDbFile = 'tocfl_vocab_clean.db';
const String kTable = 'vocab_clean';
const String kTableSamples = 'handwriting_samples';
const String kTableEmbeddings = 'char_embeddings';
const String kTablePrototypes = 'char_prototypes';
const String kTableExportSamples = 'export_samples';
const int kTopK = 10;
const int kDbVersion = 4;

const MethodChannel _visionChannel = MethodChannel('tocfl_writer/vision_ocr');

// ── URL helpers ───────────────────────────────────────────────────────────────

/// Strip trailing slashes from a base URL.
String _normalizeBase(String url) {
  var s = url.trim();
  while (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
}

/// Join base URL + possibly-relative path, no double slashes.
String _buildAbsoluteUrl(String baseUrl, String path) {
  final base = _normalizeBase(baseUrl);
  final rel = path.startsWith('/') ? path : '/$path';
  return '$base$rel';
}

/// Auth headers: x-api-key only (not Authorization Bearer).
Map<String, String> _authHeaders(String apiKey) => {
      if (apiKey.isNotEmpty) 'x-api-key': apiKey,
    };

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

// ── App Settings Model ────────────────────────────────────────────────────────

class AppSettings {
  final String serverUrl;
  final String apiKey;
  final String batchName;
  final String modelImportUrl;
  final bool autoDeleteAfterUpload;
  final String? lastUploadBatchId;
  final String? lastImportedModelVersion;
  final DateTime? lastImportedAt;

  const AppSettings({
    this.serverUrl = '',
    this.apiKey = '',
    this.batchName = 'batch_001',
    this.modelImportUrl = '',
    this.autoDeleteAfterUpload = false,
    this.lastUploadBatchId,
    this.lastImportedModelVersion,
    this.lastImportedAt,
  });

  AppSettings copyWith({
    String? serverUrl,
    String? apiKey,
    String? batchName,
    String? modelImportUrl,
    bool? autoDeleteAfterUpload,
    String? lastUploadBatchId,
    String? lastImportedModelVersion,
    DateTime? lastImportedAt,
  }) =>
      AppSettings(
        serverUrl: serverUrl ?? this.serverUrl,
        apiKey: apiKey ?? this.apiKey,
        batchName: batchName ?? this.batchName,
        modelImportUrl: modelImportUrl ?? this.modelImportUrl,
        autoDeleteAfterUpload:
            autoDeleteAfterUpload ?? this.autoDeleteAfterUpload,
        lastUploadBatchId: lastUploadBatchId ?? this.lastUploadBatchId,
        lastImportedModelVersion:
            lastImportedModelVersion ?? this.lastImportedModelVersion,
        lastImportedAt: lastImportedAt ?? this.lastImportedAt,
      );
}

// ── Settings Service ──────────────────────────────────────────────────────────

class SettingsService {
  static const _kServerUrl = 'ds_server_url';
  static const _kApiKey = 'ds_api_key';
  static const _kBatchName = 'ds_batch_name';
  static const _kModelImportUrl = 'ds_model_import_url';
  static const _kAutoDelete = 'ds_auto_delete_after_upload';
  static const _kLastBatchId = 'ds_last_upload_batch_id';
  static const _kLastModelVersion = 'ds_last_imported_model_version';
  static const _kLastImportedAt = 'ds_last_imported_at';
  // Persistent local model file paths (survive restart)
  static const _kLocalModelPath = 'ds_local_model_path';
  static const _kLocalLabelsPath = 'ds_local_labels_path';
  static const _kLocalMetadataPath = 'ds_local_metadata_path';

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final lastImportedAtStr = prefs.getString(_kLastImportedAt);
    return AppSettings(
      serverUrl: prefs.getString(_kServerUrl) ?? '',
      apiKey: prefs.getString(_kApiKey) ?? '',
      batchName: prefs.getString(_kBatchName) ?? 'batch_001',
      modelImportUrl: prefs.getString(_kModelImportUrl) ?? '',
      autoDeleteAfterUpload: prefs.getBool(_kAutoDelete) ?? false,
      lastUploadBatchId: prefs.getString(_kLastBatchId),
      lastImportedModelVersion: prefs.getString(_kLastModelVersion),
      lastImportedAt: lastImportedAtStr != null
          ? DateTime.tryParse(lastImportedAtStr)
          : null,
    );
  }

  static Future<void> save(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerUrl, s.serverUrl);
    await prefs.setString(_kApiKey, s.apiKey);
    await prefs.setString(_kBatchName, s.batchName);
    await prefs.setString(_kModelImportUrl, s.modelImportUrl);
    await prefs.setBool(_kAutoDelete, s.autoDeleteAfterUpload);
    if (s.lastUploadBatchId != null)
      await prefs.setString(_kLastBatchId, s.lastUploadBatchId!);
    if (s.lastImportedModelVersion != null)
      await prefs.setString(_kLastModelVersion, s.lastImportedModelVersion!);
    if (s.lastImportedAt != null)
      await prefs.setString(
          _kLastImportedAt, s.lastImportedAt!.toIso8601String());
  }

  /// Persist local model file paths after a successful import.
  static Future<void> saveModelPaths({
    required String modelPath,
    String? labelsPath,
    String? metadataPath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocalModelPath, modelPath);
    if (labelsPath != null)
      await prefs.setString(_kLocalLabelsPath, labelsPath);
    if (metadataPath != null)
      await prefs.setString(_kLocalMetadataPath, metadataPath);
  }

  /// Load saved model paths. Returns null values when not set.
  static Future<({String? modelPath, String? labelsPath, String? metadataPath})>
      loadModelPaths() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      modelPath: prefs.getString(_kLocalModelPath),
      labelsPath: prefs.getString(_kLocalLabelsPath),
      metadataPath: prefs.getString(_kLocalMetadataPath),
    );
  }

  /// Clear saved model paths (e.g. when files are missing).
  static Future<void> clearModelPaths() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLocalModelPath);
    await prefs.remove(_kLocalLabelsPath);
    await prefs.remove(_kLocalMetadataPath);
  }
}

// ── Export Sample Model ───────────────────────────────────────────────────────

class ExportSample {
  final String id;
  final String vocabulary;
  final String? pngBase64;
  final String strokeJson;
  final double strokeWidth;
  final DateTime createdAt;
  final String? exportedBatchId;
  final bool uploaded;
  final bool deleted;
  final String source;

  const ExportSample({
    required this.id,
    required this.vocabulary,
    this.pngBase64,
    required this.strokeJson,
    required this.strokeWidth,
    required this.createdAt,
    this.exportedBatchId,
    this.uploaded = false,
    this.deleted = false,
    this.source = 'manual_draw',
  });

  factory ExportSample.fromMap(Map<String, dynamic> m) => ExportSample(
        id: m['id'] as String,
        vocabulary: m['vocabulary'] as String,
        pngBase64: m['png_base64'] as String?,
        strokeJson: m['stroke_json'] as String,
        strokeWidth: (m['stroke_width'] as num).toDouble(),
        createdAt: DateTime.parse(m['created_at'] as String),
        exportedBatchId: m['exported_batch_id'] as String?,
        uploaded: (m['uploaded'] as int?) == 1,
        deleted: (m['deleted'] as int?) == 1,
        source: (m['source'] as String?) ?? 'manual_draw',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'vocabulary': vocabulary,
        'png_base64': pngBase64,
        'stroke_json': strokeJson,
        'stroke_width': strokeWidth,
        'created_at': createdAt.toIso8601String(),
        'exported_batch_id': exportedBatchId,
        'uploaded': uploaded ? 1 : 0,
        'deleted': deleted ? 1 : 0,
        'source': source,
      };
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
    }
    await _createTables(db);
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
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $kTableEmbeddings (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        vocabulary    TEXT    NOT NULL,
        embedding_json TEXT   NOT NULL,
        is_fallback   INTEGER NOT NULL DEFAULT 0,
        created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $kTablePrototypes (
        vocabulary    TEXT    PRIMARY KEY,
        prototype_json TEXT   NOT NULL,
        count         INTEGER NOT NULL DEFAULT 1,
        updated_at    TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    // v4: export samples table (separate from handwriting_samples)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $kTableExportSamples (
        id                TEXT    PRIMARY KEY,
        vocabulary        TEXT    NOT NULL,
        png_base64        TEXT,
        stroke_json       TEXT    NOT NULL,
        stroke_width      REAL    NOT NULL DEFAULT 10.0,
        created_at        TEXT    NOT NULL,
        exported_batch_id TEXT,
        uploaded          INTEGER NOT NULL DEFAULT 0,
        deleted           INTEGER NOT NULL DEFAULT 0,
        source            TEXT    NOT NULL DEFAULT 'manual_draw'
      )
    ''');
    for (final sql in [
      'CREATE INDEX IF NOT EXISTS idx_samples_vocab    ON $kTableSamples(vocabulary)',
      'CREATE INDEX IF NOT EXISTS idx_samples_created  ON $kTableSamples(vocabulary, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_emb_vocab        ON $kTableEmbeddings(vocabulary)',
      'CREATE INDEX IF NOT EXISTS idx_export_vocab     ON $kTableExportSamples(vocabulary)',
      'CREATE INDEX IF NOT EXISTS idx_export_uploaded  ON $kTableExportSamples(uploaded)',
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

  static Future<VocabEntry?> findExactByVocabulary(String vocabulary) async {
    final rows = await db.rawQuery(
      'SELECT * FROM $kTable WHERE vocabulary = ? LIMIT 1',
      [vocabulary],
    );
    if (rows.isEmpty) return null;
    return VocabEntry.fromMap(rows.first);
  }

  // ── Practice count ────────────────────────────────────────────────────────

  static Future<void> incrementPracticeCount(String vocabulary) async {}

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

  // ── Samples (legacy OCR tracking) ────────────────────────────────────────

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

  // ── Export Samples ────────────────────────────────────────────────────────

  static Future<String> saveExportSample({
    required String vocabulary,
    required String strokeJson,
    required double strokeWidth,
    String? pngBase64,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toIso8601String();
    await db.insert(kTableExportSamples, {
      'id': id,
      'vocabulary': vocabulary,
      'png_base64': pngBase64,
      'stroke_json': strokeJson,
      'stroke_width': strokeWidth,
      'created_at': now,
      'exported_batch_id': null,
      'uploaded': 0,
      'deleted': 0,
      'source': 'manual_draw',
    });
    return id;
  }

  static Future<List<ExportSample>> getPendingExportSamples() async {
    final rows = await db.rawQuery(
      'SELECT * FROM $kTableExportSamples WHERE uploaded = 0 AND deleted = 0 ORDER BY created_at ASC',
    );
    return rows.map(ExportSample.fromMap).toList();
  }

  static Future<int> getPendingExportCount() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $kTableExportSamples WHERE uploaded = 0 AND deleted = 0',
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  static Future<int> getExportSampleCountByVocab(String vocabulary) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $kTableExportSamples WHERE vocabulary = ? AND deleted = 0',
      [vocabulary],
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  static Future<void> markExportSamplesUploaded(
      List<String> ids, String batchId) async {
    if (ids.isEmpty) return;
    final ph = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE $kTableExportSamples SET uploaded = 1, exported_batch_id = ? WHERE id IN ($ph)',
      [batchId, ...ids],
    );
  }

  static Future<void> deleteExportSamplesByBatch(String batchId) async {
    await db.rawUpdate(
      'UPDATE $kTableExportSamples SET deleted = 1 WHERE exported_batch_id = ?',
      [batchId],
    );
  }

  static Future<void> deleteAllLocalExportSamples() async {
    await db.rawUpdate(
      'UPDATE $kTableExportSamples SET deleted = 1 WHERE uploaded = 0',
    );
  }

  /// Returns all rows from char_prototypes as raw maps.
  static Future<List<Map<String, dynamic>>> getAllPrototypes() async {
    return db.rawQuery(
      'SELECT vocabulary, prototype_json, count FROM $kTablePrototypes ORDER BY count DESC',
    );
  }
}

// ── Embedding Encoder ─────────────────────────────────────────────────────────

class EmbeddingEncoder {
  static const int dim = 128;

  // ── Imported model metadata (populated by ModelImportService) ─────────────
  static String? _localModelPath;
  static String? _localLabelsPath;
  static String? _importedVersion;
  static DateTime? _importedAt;

  /// Returns the labels list from labels.json if available, else empty.
  static List<String> get importedLabels {
    if (_localLabelsPath == null) return const [];
    try {
      final f = File(_localLabelsPath!);
      if (!f.existsSync()) return const [];
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is List) return raw.map((e) => e.toString()).toList();
      if (raw is Map && raw.containsKey('labels')) {
        return (raw['labels'] as List).map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Returns true if a locally-imported model file is present.
  static bool hasImportedModel() =>
      _localModelPath != null && File(_localModelPath!).existsSync();

  /// Path to the local imported model (null if not yet imported).
  static String? getLocalModelPath() => _localModelPath;

  /// Metadata of the imported model.
  static Map<String, dynamic> loadImportedModelMetadata() => {
        'path': _localModelPath,
        'version': _importedVersion,
        'importedAt': _importedAt?.toIso8601String(),
      };

  /// Called by [ModelImportService] after a successful import.
  static void setLocalModel({
    required String path,
    String? labelsPath,
    String? version,
    DateTime? importedAt,
  }) {
    _localModelPath = path;
    _localLabelsPath = labelsPath;
    _importedVersion = version;
    _importedAt = importedAt;
    // Thêm 3 dòng này:
    _interpreter?.close();
    _interpreter = null;
    _loadedModelPath = null;
  }

  // Cached interpreter — reused across calls until model path changes.
  static tfl.Interpreter? _interpreter;
  static String? _loadedModelPath;

  /// Run TFLite encoder inference.
  /// Input: PNG bytes (any size, white background black strokes).
  /// Output: List<double> of length [dim], or null on error / no model.
  static Future<List<double>?> encode(Uint8List pngBytes) async {
    if (!hasImportedModel()) return null;
    try {
      // Re-load interpreter only when model path changed.
      if (_interpreter == null || _loadedModelPath != _localModelPath) {
        _interpreter?.close();
        _interpreter = tfl.Interpreter.fromFile(
          File(_localModelPath!),
          options: tfl.InterpreterOptions()..threads = 2,
        );
        _loadedModelPath = _localModelPath;
      }

      // ── Preprocess: decode PNG → grayscale 64×64 float32 ─────────────────
      final codec = await ui.instantiateImageCodec(
        pngBytes,
        targetWidth: 64,
        targetHeight: 64,
      );
      final frame = await codec.getNextFrame();
      final byteData =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      if (byteData == null) return null;

      // RGBA → grayscale float32, normalize to [0, 1].
      // The canvas is white-background / black-stroke, so we invert so that
      // ink = 1.0 and background = 0.0 (typical for handwriting models).
      final rgba = byteData.buffer.asUint8List();
      final input = List.generate(
        64 * 64,
        (i) {
          final r = rgba[i * 4];
          final g = rgba[i * 4 + 1];
          final b = rgba[i * 4 + 2];
          final gray = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
          return gray; // giữ đúng như train.py: nền trắng=1, nét đen=0
        },
      );

      // Shape: [1, 64, 64, 1]
      final inputTensor = [
        List.generate(
            64, (row) => List.generate(64, (col) => [input[row * 64 + col]]))
      ];

      // Output: [1, dim]
      final outputTensor = List.generate(1, (_) => List.filled(dim, 0.0));

      _interpreter!.run(inputTensor, outputTensor);

      return List<double>.from(outputTensor[0]);
    } catch (e) {
      debugPrint('[EmbeddingEncoder.encode] $e');
      // Invalidate cached interpreter so next call retries a fresh load.
      _interpreter?.close();
      _interpreter = null;
      _loadedModelPath = null;
      return null;
    }
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

// ── Model Import Service ──────────────────────────────────────────────────────

enum ModelImportStatus { idle, loading, success, failed }

class ModelImportResult {
  final ModelImportStatus status;
  final String? version;
  final String? errorMsg;

  const ModelImportResult({
    required this.status,
    this.version,
    this.errorMsg,
  });
}

class ModelImportService {
  /// Import encoder from FastAPI server.
  ///
  /// Flow:
  ///   GET {serverUrl}/api/model/latest
  ///   → { ok, encoderUrl, labelsUrl, metadataUrl, encoderExists, ... }
  ///   Download each file; persist paths to SharedPreferences.
  static Future<ModelImportResult> importEncoder({
    required String importUrl,
    required String apiKey,
    required AppSettings currentSettings,
  }) async {
    final baseUrl = _normalizeBase(
      importUrl.isNotEmpty ? importUrl : currentSettings.serverUrl,
    );
    if (baseUrl.isEmpty) {
      return const ModelImportResult(
          status: ModelImportStatus.failed, errorMsg: 'server URL is empty');
    }

    // Keep old paths so we can restore on failure
    final oldPaths = await SettingsService.loadModelPaths();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory(p.join(dir.path, 'models'));
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final headers = _authHeaders(apiKey);

      // Step 1: fetch model metadata
      final latestUrl = _buildAbsoluteUrl(baseUrl, '/api/model/latest');
      final metaResp = await http
          .get(Uri.parse(latestUrl), headers: headers)
          .timeout(const Duration(seconds: 30));

      if (metaResp.statusCode != 200) {
        return ModelImportResult(
          status: ModelImportStatus.failed,
          errorMsg: 'server ${metaResp.statusCode}',
        );
      }

      final meta = jsonDecode(metaResp.body) as Map<String, dynamic>;
      if (meta['ok'] != true) {
        return ModelImportResult(
          status: ModelImportStatus.failed,
          errorMsg: 'server ok=false',
        );
      }

      final encoderExists = meta['encoderExists'] == true;
      if (!encoderExists) {
        return const ModelImportResult(
          status: ModelImportStatus.failed,
          errorMsg: 'no encoder on server',
        );
      }

      // Resolve relative paths → absolute URLs
      final encoderPath = meta['encoderUrl'] as String? ?? '/api/model/encoder';
      final labelsPath = meta['labelsUrl'] as String?;
      final metadataPath = meta['metadataUrl'] as String?;
      final labelsExists = meta['labelsExists'] == true;
      final metadataExists = meta['metadataExists'] == true;

      final encoderUrl = _buildAbsoluteUrl(baseUrl, encoderPath);
      final labelsUrl = (labelsExists && labelsPath != null)
          ? _buildAbsoluteUrl(baseUrl, labelsPath)
          : null;
      final metadataUrl = (metadataExists && metadataPath != null)
          ? _buildAbsoluteUrl(baseUrl, metadataPath)
          : null;

      // Step 2: download encoder.tflite
      final tfliteDest = p.join(modelsDir.path, 'encoder.tflite');
      await _downloadFile(
          url: encoderUrl, destPath: tfliteDest, headers: headers);

      // Step 3: optionally download labels.json
      String? labelsDest;
      if (labelsUrl != null) {
        labelsDest = p.join(modelsDir.path, 'labels.json');
        await _downloadFile(
            url: labelsUrl, destPath: labelsDest, headers: headers);
      }

      // Step 4: optionally download metadata.json
      String? metadataDest;
      if (metadataUrl != null) {
        metadataDest = p.join(modelsDir.path, 'metadata.json');
        await _downloadFile(
            url: metadataUrl, destPath: metadataDest, headers: headers);
      }

      // Step 5: optionally download prototypes.json and seed local DB
      // prototypes.json format: [{"vocabulary":"字","prototype":[...],"count":N}, ...]
      final prototypesPath = meta['prototypesUrl'] as String?;

      if (prototypesPath != null && prototypesPath.trim().isNotEmpty) {
        try {
          final prototypesUrl = _buildAbsoluteUrl(baseUrl, prototypesPath);
          final protoDest = p.join(modelsDir.path, 'prototypes.json');
          await _downloadFile(
              url: prototypesUrl, destPath: protoDest, headers: headers);
          await _seedPrototypesToDb(protoDest);
        } catch (e) {
          debugPrint('[ModelImportService] prototypes seed skipped: $e');
          // Non-fatal: encoder still works without seeded prototypes.
        }
      }

      // Derive version from metadata.json if available
      String version = 'unknown';
      if (metadataDest != null && File(metadataDest).existsSync()) {
        try {
          final raw = jsonDecode(File(metadataDest).readAsStringSync())
              as Map<String, dynamic>;
          version = (raw['version'] as String?) ?? 'unknown';
        } catch (_) {}
      }

      final importedAt = DateTime.now();

      // Activate in RAM
      EmbeddingEncoder.setLocalModel(
        path: tfliteDest,
        labelsPath: labelsDest,
        version: version,
        importedAt: importedAt,
      );

      // Persist paths + settings
      await SettingsService.saveModelPaths(
        modelPath: tfliteDest,
        labelsPath: labelsDest,
        metadataPath: metadataDest,
      );
      final updated = currentSettings.copyWith(
        lastImportedModelVersion: version,
        lastImportedAt: importedAt,
      );
      await SettingsService.save(updated);

      return ModelImportResult(
          status: ModelImportStatus.success, version: version);
    } catch (e) {
      debugPrint('[ModelImportService] $e');
      // Restore old model if it still exists
      if (oldPaths.modelPath != null &&
          File(oldPaths.modelPath!).existsSync()) {
        EmbeddingEncoder.setLocalModel(
          path: oldPaths.modelPath!,
          labelsPath: oldPaths.labelsPath,
          version: currentSettings.lastImportedModelVersion,
        );
      }
      return ModelImportResult(
          status: ModelImportStatus.failed, errorMsg: e.toString());
    }
  }

  /// Seed server-side prototypes into local char_prototypes table.
  /// Only inserts rows that don't yet exist locally (does not overwrite
  /// prototypes the user has built via Check, because those are more recent).
  static Future<void> _seedPrototypesToDb(String jsonPath) async {
    await DbService.db.delete(kTablePrototypes);
    final raw = jsonDecode(File(jsonPath).readAsStringSync());

    if (raw is Map<String, dynamic>) {
      for (final entry in raw.entries) {
        try {
          final vocab = entry.key;
          final data = entry.value as Map<String, dynamic>;
          final protoVec = (data['prototype'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
          final count = (data['count'] as num?)?.toInt() ?? 1;

          await DbService.upsertPrototype(
            vocabulary: vocab,
            protoJson: jsonEncode(protoVec),
            count: count,
          );
        } catch (_) {}
      }
      return;
    }

    if (raw is List) {
      for (final item in raw) {
        try {
          final vocab = item['vocabulary'] as String;
          final protoVec = (item['prototype'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
          final count = (item['count'] as num?)?.toInt() ?? 1;

          final existing = await DbService.getPrototype(vocab);
          if (existing == null) {
            await DbService.upsertPrototype(
              vocabulary: vocab,
              protoJson: jsonEncode(protoVec),
              count: count,
            );
          }
        } catch (_) {}
      }
    }
  }

  static Future<void> _downloadFile({
    required String url,
    required String destPath,
    required Map<String, String> headers,
  }) async {
    final resp = await http
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw Exception('download $url → ${resp.statusCode}');
    }
    await File(destPath).writeAsBytes(resp.bodyBytes, flush: true);
  }
}

// ── Export Service ────────────────────────────────────────────────────────────

enum ExportStatus { idle, exporting, success, failed }

class ExportResult {
  final ExportStatus status;
  final int uploadedCount;
  final String? batchId;
  final String? errorMsg;

  const ExportResult({
    required this.status,
    this.uploadedCount = 0,
    this.batchId,
    this.errorMsg,
  });
}

class DatasetExportService {
  static String generateBatchId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'batch_${ts}_${const Uuid().v4().substring(0, 8)}';
  }

  static Future<ExportResult> exportDataset({
    required AppSettings settings,
  }) async {
    if (settings.serverUrl.trim().isEmpty) {
      return const ExportResult(
          status: ExportStatus.failed, errorMsg: 'server URL is empty');
    }

    final pending = await DbService.getPendingExportSamples();
    if (pending.isEmpty) {
      return const ExportResult(
          status: ExportStatus.failed, errorMsg: 'no pending samples');
    }

    final batchId = generateBatchId();
    final now = DateTime.now().toIso8601String();
    Directory? tmpDir;

    try {
      // ── Step 1: write PNG files into a temp folder tree ──────────────────
      tmpDir = await Directory(
        p.join((await getTemporaryDirectory()).path, 'export_batch', batchId),
      ).create(recursive: true);

      final groupedCounts = <String, int>{};
      final sampleIds = <String>[];

      for (final s in pending) {
        if (s.pngBase64 == null || s.pngBase64!.isEmpty) continue;
        final vocabDir = await Directory(p.join(tmpDir.path, s.vocabulary))
            .create(recursive: true);
        final pngBytes = base64Decode(s.pngBase64!);
        await File(p.join(vocabDir.path, '${s.id}.png'))
            .writeAsBytes(pngBytes, flush: true);
        groupedCounts[s.vocabulary] = (groupedCounts[s.vocabulary] ?? 0) + 1;
        sampleIds.add(s.id);
      }

      if (sampleIds.isEmpty) {
        return const ExportResult(
            status: ExportStatus.failed, errorMsg: 'no samples with PNG data');
      }

      // ── Step 2: zip the temp folder ──────────────────────────────────────
      final zipPath =
          p.join((await getTemporaryDirectory()).path, '$batchId.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      await encoder.addDirectory(tmpDir, includeDirName: false);
      encoder.close();
      final zipBytes = await File(zipPath).readAsBytes();

      // ── Step 3: build metadataJson ───────────────────────────────────────
      final metadataJson = jsonEncode({
        'totalSamples': sampleIds.length,
        'exportedAt': now,
        'sampleIds': sampleIds,
        'groupedCounts': groupedCounts,
      });

      // ── Step 4: multipart POST ───────────────────────────────────────────
      final uploadUrl = _buildAbsoluteUrl(
          _normalizeBase(settings.serverUrl), '/api/dataset/upload');

      final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
      request.headers.addAll(_authHeaders(settings.apiKey));
      request.fields['batchName'] = settings.batchName;
      request.fields['batchId'] = batchId;
      request.fields['createdAt'] = now;
      request.fields['metadataJson'] = metadataJson;
      request.files.add(
        http.MultipartFile.fromBytes(
          'datasetZip',
          zipBytes,
          filename: '$batchId.zip',
        ),
      );

      final streamed =
          await request.send().timeout(const Duration(seconds: 180));
      final resp = await http.Response.fromStream(streamed);

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return ExportResult(
          status: ExportStatus.failed,
          errorMsg:
              'server ${resp.statusCode}: ${resp.body.substring(0, math.min(120, resp.body.length))}',
        );
      }

      // ── Step 5: mark uploaded ────────────────────────────────────────────
      await DbService.markExportSamplesUploaded(sampleIds, batchId);

      if (settings.autoDeleteAfterUpload) {
        await DbService.deleteExportSamplesByBatch(batchId);
      }

      final updatedSettings = settings.copyWith(lastUploadBatchId: batchId);
      await SettingsService.save(updatedSettings);

      return ExportResult(
        status: ExportStatus.success,
        uploadedCount: sampleIds.length,
        batchId: batchId,
      );
    } catch (e) {
      debugPrint('[DatasetExportService] $e');
      return ExportResult(status: ExportStatus.failed, errorMsg: e.toString());
    } finally {
      // Clean up temp files regardless of outcome
      try {
        tmpDir?.deleteSync(recursive: true);
      } catch (_) {}
      try {
        final zipPath =
            p.join((await getTemporaryDirectory()).path, '$batchId.zip');
        final zf = File(zipPath);
        if (zf.existsSync()) zf.deleteSync();
      } catch (_) {}
    }
  }

  /// Test connectivity: GET {baseUrl}/api/health → { "ok": true }
  static Future<bool> testConnection(String url, String apiKey) async {
    if (url.trim().isEmpty) return false;
    try {
      final healthUrl = _buildAbsoluteUrl(_normalizeBase(url), '/api/health');
      final resp = await http
          .get(Uri.parse(healthUrl), headers: _authHeaders(apiKey))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return false;
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return body['ok'] == true;
      } catch (_) {
        return true; // 200 OK is good enough
      }
    } catch (_) {
      return false;
    }
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
  static const double _alpha = 0.20;

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

  static Future<double?> computeSimilarity({
    required String vocabulary,
    required List<double> embedding,
  }) async {
    final proto = await DbService.getPrototype(vocabulary);
    if (proto == null) return null;

    final protoVec = (jsonDecode(proto['prototype_json'] as String) as List)
        .map((e) => (e as num).toDouble())
        .toList();

    return cosine01(embedding, protoVec);
  }

  static Future<double?> similarityToPrototype({
    required String vocabulary,
    required List<double> embedding,
  }) async {
    return computeSimilarity(vocabulary: vocabulary, embedding: embedding);
  }

  static double rawCosine(List<double> a, List<double> b) {
    double dot = 0, nA = 0, nB = 0;
    final len = math.min(a.length, b.length);

    for (var i = 0; i < len; i++) {
      dot += a[i] * b[i];
      nA += a[i] * a[i];
      nB += b[i] * b[i];
    }

    final d = math.sqrt(nA) * math.sqrt(nB);
    if (d < 1e-10) return 0.0;

    return dot / d; // giữ nguyên [-1..1], KHÔNG clamp 0..1
  }

  static double cosine01(List<double> a, List<double> b) {
    final raw = rawCosine(a, b);
    return ((raw + 1.0) / 2.0).clamp(0.0, 1.0); // map sang % hiển thị
  }

  static double cosine(List<double> a, List<double> b) =>
      rawCosine(a, b).clamp(0.0, 1.0);
}

// ── Local Learning Service ────────────────────────────────────────────────────

class LocalLearningService {
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

    final simBefore = await PrototypeService.computeSimilarity(
      vocabulary: vocabulary,
      embedding: embedding,
    );

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

  ToastMessage? _pendingToast;

  // ── Settings ──────────────────────────────────────────────────────────────
  AppSettings _settings = const AppSettings();

  // ── Dataset / Export state ────────────────────────────────────────────────
  int _pendingUploadCount = 0;
  int _localSampleCountForPinned = 0;

  // ── Realtime proto-match state ────────────────────────────────────────────
  List<ProtoMatchCandidate> _realtimeCandidates = const [];
  bool _realtimeBusy = false;
  bool _realtimePending = false;
  Timer? _realtimeDebounce;
  // 'proto' | 'labels_fallback' | 'none'
  String _realtimeSource = 'none';

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
  AppSettings get settings => _settings;
  int get pendingUploadCount => _pendingUploadCount;
  int get localSampleCountForPinned => _localSampleCountForPinned;
  List<ProtoMatchCandidate> get realtimeCandidates => _realtimeCandidates;
  bool get realtimeBusy => _realtimeBusy;
  String get realtimeSource => _realtimeSource;

  void consumeToast() {
    if (_pendingToast == null) return;
    _pendingToast = null;
  }

  Future<void> init() async {
    try {
      await DbService.init();
      _settings = await SettingsService.load();
      _pendingUploadCount = await DbService.getPendingExportCount();
      // Restore imported model paths that survived a restart
      await _restoreLocalModel();
    } catch (e, st) {
      debugPrint('[AppState.init] $e');
      debugPrint(st.toString());
      _initError = e.toString();
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  Future<String?> exportPrototypesToTemp() async {
    try {
      return await PrototypeBackupService.exportToTemp();
    } catch (e) {
      debugPrint('[exportPrototypes] $e');
      return null;
    }
  }

  Future<PrototypeImportResult?> importPrototypesFromFile(
      String filePath) async {
    try {
      final result = await PrototypeBackupService.importFromFile(filePath);
      notifyListeners();
      return result;
    } catch (e) {
      debugPrint('[importPrototypes] $e');
      return null;
    }
  }

  /// Re-activates EmbeddingEncoder from persisted paths if files still exist.
  Future<void> _restoreLocalModel() async {
    final paths = await SettingsService.loadModelPaths();
    if (paths.modelPath == null) return;
    if (File(paths.modelPath!).existsSync()) {
      EmbeddingEncoder.setLocalModel(
        path: paths.modelPath!,
        labelsPath: paths.labelsPath,
        version: _settings.lastImportedModelVersion,
        importedAt: _settings.lastImportedAt,
      );
    } else {
      // File was removed; clean up stale prefs
      await SettingsService.clearModelPaths();
    }
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> updateSettings(AppSettings s) async {
    _settings = s;
    await SettingsService.save(s);
    notifyListeners();
  }

  // ── Canvas ────────────────────────────────────────────────────────────────

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
    // Debounced realtime compare while drawing
    _realtimeDebounce?.cancel();
    _realtimeDebounce = Timer(const Duration(milliseconds: 180), () {
      _runRealtimeCompare();
    });
  }

  void strokeEnd() {
    _canvas = _canvas.endStroke();
    notifyListeners();
    // Immediate compare on stroke end (cancel any pending debounce first)
    _realtimeDebounce?.cancel();
    _runRealtimeCompare();
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
    _realtimeCandidates = const [];
    _realtimeSource = 'none';
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
    _refreshPinnedSampleCount();
    notifyListeners();
  }

  void resetPinned() {
    _pinnedEntry = null;
    _showPinnedTemplate = false;
    _similarityResult = null;
    _localSampleCountForPinned = 0;
    notifyListeners();
  }

  Future<void> _refreshPinnedSampleCount() async {
    if (_pinnedEntry == null) return;
    _localSampleCountForPinned =
        await DbService.getExportSampleCountByVocab(_pinnedEntry!.vocabulary);
    _pendingUploadCount = await DbService.getPendingExportCount();
    notifyListeners();
  }

  // ── Save Sample ───────────────────────────────────────────────────────────

  Future<bool> saveSample() async {
    if (_pinnedEntry == null) return false;
    if (_canvas.strokes.isEmpty) return false;

    try {
      final pngBytes = await CanvasRenderService.renderPngBytes(
        _canvas.strokes,
        strokeWidth: _strokeWidth,
      );
      final pngBase64 = base64Encode(pngBytes);
      final strokeJson = StrokeSerializer.toJson(_canvas.strokes);

      await DbService.saveExportSample(
        vocabulary: _pinnedEntry!.vocabulary,
        strokeJson: strokeJson,
        strokeWidth: _strokeWidth,
        pngBase64: pngBase64,
      );

      await _refreshPinnedSampleCount();
      return true;
    } catch (e) {
      debugPrint('[saveSample] $e');
      return false;
    }
  }

  // ── Save + Clear (pinned mode) ────────────────────────────────────────────
  // Renders current strokes, encodes embedding, saves prototype + export
  // sample, then clears the canvas. Returns false (and does NOT clear) if
  // anything fails so the user never loses their drawing.

  Future<bool> saveAndClearPinned() async {
    if (_pinnedEntry == null) return false;
    if (_canvas.strokes.isEmpty) return false;
    if (_busy) return false;

    _busy = true;
    notifyListeners();

    try {
      final pngBytes = await CanvasRenderService.renderPngBytes(
        _canvas.strokes,
        strokeWidth: _strokeWidth,
      );

      // Encode embedding (model or fallback)
      final tflEmb = await EmbeddingEncoder.encode(pngBytes);
      final isFallback = tflEmb == null;
      final embedding = tflEmb ?? EmbeddingEncoder.fallback(_canvas.strokes);

      // Save prototype/embedding — same flow as recognize()
      final checkResult = await LocalLearningService.onCheck(
        vocabulary: _pinnedEntry!.vocabulary,
        ocrRaw: const [],
        strokeWidth: _strokeWidth,
        strokes: _canvas.strokes,
        embedding: embedding,
        isFallback: isFallback,
      );

      if (checkResult.isDbError) {
        // Don't clear canvas on DB error
        _busy = false;
        notifyListeners();
        return false;
      }

      // Save export sample (PNG for dataset)
      final pngBase64 = base64Encode(pngBytes);
      final strokeJson = StrokeSerializer.toJson(_canvas.strokes);
      await DbService.saveExportSample(
        vocabulary: _pinnedEntry!.vocabulary,
        strokeJson: strokeJson,
        strokeWidth: _strokeWidth,
        pngBase64: pngBase64,
      );

      // Set feedback state
      _similarityResult = checkResult.similarityResult;
      _pendingToast = ToastMessage(
        char: _pinnedEntry!.vocabulary,
        embeddingCount: checkResult.embeddingCount,
        status: checkResult.toastStatus,
        protoUpdated: checkResult.protoUpdated,
        matchedByProto: true,
      );

      // Clear canvas after successful save
      _canvas = _canvas.clear();
      _result = null;
      _realtimeCandidates = const [];
      _realtimeSource = 'none';

      await _refreshPinnedSampleCount();
      return true;
    } catch (e) {
      debugPrint('[saveAndClearPinned] $e');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── Realtime proto compare ────────────────────────────────────────────────

  Future<void> _runRealtimeCompare() async {
    if (_realtimeBusy) {
      _realtimePending = true;
      return;
    }
    _realtimePending = false;
    _realtimeBusy = true;
    try {
      if (_canvas.strokes.isEmpty) return;
      final protos = await DbService.getAllPrototypes();
      if (protos.isNotEmpty) {
        final pngBytes = await CanvasRenderService.renderPngBytes(
          _canvas.strokes,
          strokeWidth: _strokeWidth,
        );
        final tflEmb = await EmbeddingEncoder.encode(pngBytes);
        final embedding = tflEmb ?? EmbeddingEncoder.fallback(_canvas.strokes);
        final candidates = <ProtoMatchCandidate>[];
        for (final row in protos) {
          try {
            final vocab = row['vocabulary'] as String;
            final protoVec =
                (jsonDecode(row['prototype_json'] as String) as List)
                    .map((e) => (e as num).toDouble())
                    .toList();
            final count = (row['count'] as int?) ?? 0;
            final score = PrototypeService.cosine01(embedding, protoVec);
            candidates.add(ProtoMatchCandidate(
                vocabulary: vocab, score: score, count: count));
          } catch (_) {}
        }
        candidates.sort((a, b) => b.score.compareTo(a.score));
        _realtimeCandidates = candidates.take(5).toList();
        _realtimeSource = 'proto';
      } else {
        _realtimeCandidates = const [];
        _realtimeSource = EmbeddingEncoder.hasImportedModel()
            ? 'model_no_prototypes'
            : 'none';
      }
    } catch (e) {
      debugPrint('[_runRealtimeCompare] $e');
    } finally {
      _realtimeBusy = false;
      notifyListeners();
      if (_realtimePending) {
        _realtimePending = false;
        _runRealtimeCompare();
      }
    }
  }

  // ── Recognize (OCR bypassed — proto/model only) ───────────────────────────

  Future<void> recognize() async {
    if (_busy || _canvas.strokes.isEmpty) return;

    _busy = true;
    _result = null;
    _similarityResult = null;
    _matchSource = MatchSource.none;
    notifyListeners();

    try {
      final pngBytes = await CanvasRenderService.renderPngBytes(
        _canvas.strokes,
        strokeWidth: _strokeWidth,
      );

      final List<double>? tflEmb = await EmbeddingEncoder.encode(pngBytes);
      final bool isFallback = tflEmb == null;
      final List<double> embedding =
          tflEmb ?? EmbeddingEncoder.fallback(_canvas.strokes);

      // ── OCR BYPASSED — testing model/prototype only ───────────────────────
      // All OCR / VisionOcrService calls removed for this mode.
      // Match against ALL prototypes (same logic as realtime compare).
      final protos = await DbService.getAllPrototypes();
      List<VocabEntry> matches = const [];

      if (protos.isNotEmpty) {
        final scored = <MapEntry<String, double>>[];
        for (final row in protos) {
          try {
            final vocab = row['vocabulary'] as String;
            final protoVec =
                (jsonDecode(row['prototype_json'] as String) as List)
                    .map((e) => (e as num).toDouble())
                    .toList();
            scored.add(MapEntry(
                vocab, PrototypeService.cosine01(embedding, protoVec)));
          } catch (_) {}
        }
        scored.sort((a, b) => b.value.compareTo(a.value));
        final topVocabs = scored.take(kTopK).map((e) => e.key).toList();
        matches = await DbService.findByVocabularyTokens(topVocabs);
        // Re-sort matches to follow proto score order
        final orderMap = {
          for (var i = 0; i < topVocabs.length; i++) topVocabs[i]: i
        };
        matches.sort((a, b) => (orderMap[a.vocabulary] ?? 99)
            .compareTo(orderMap[b.vocabulary] ?? 99));
      }

      _matchSource = MatchSource.proto;
      _result = RecResult(
        matches: matches,
        raw: const [],
        matchSource: MatchSource.proto,
      );

      // Save embedding + update prototype for pinned entry
      if (_showPinnedTemplate && _pinnedEntry != null) {
        final checkResult = await LocalLearningService.onCheck(
          vocabulary: _pinnedEntry!.vocabulary,
          ocrRaw: const [],
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
          matchedByProto: true,
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
    _realtimeDebounce?.cancel();
    super.dispose();
  }
}
// ── Prototype Backup Service ──────────────────────────────────────────────────

class PrototypeImportResult {
  final bool success;
  final int mergedPrototypes;
  final int addedEmbeddings;
  final String? errorMsg;

  const PrototypeImportResult({
    required this.success,
    this.mergedPrototypes = 0,
    this.addedEmbeddings = 0,
    this.errorMsg,
  });
}

class PrototypeBackupService {
  static Future<String> exportToTemp() async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = p.join(dir.path, 'prototypes_$ts.json');

    final protos = await DbService.getAllPrototypes();
    final embRows = await DbService.db.rawQuery(
      'SELECT vocabulary, embedding_json, is_fallback, created_at '
      'FROM $kTableEmbeddings ORDER BY created_at ASC',
    );

    final protoMap = <String, dynamic>{};
    for (final row in protos) {
      protoMap[row['vocabulary'] as String] = {
        'prototype': jsonDecode(row['prototype_json'] as String),
        'count': row['count'],
      };
    }

    final data = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'prototypes': protoMap,
      'embeddings': embRows
          .map((r) => {
                'vocabulary': r['vocabulary'],
                'embeddingJson': r['embedding_json'],
                'isFallback': r['is_fallback'],
                'createdAt': r['created_at'],
              })
          .toList(),
    };

    await File(path).writeAsString(jsonEncode(data), flush: true);
    return path;
  }

  static Future<PrototypeImportResult> importFromFile(String filePath) async {
    final raw = await File(filePath).readAsString();
    final data = jsonDecode(raw) as Map<String, dynamic>;

    if ((data['version'] as int?) != 1) {
      return const PrototypeImportResult(
          success: false, errorMsg: 'unsupported version');
    }

    int mergedProtos = 0;
    int addedEmbeddings = 0;

    final protos = data['prototypes'] as Map<String, dynamic>? ?? {};
    for (final entry in protos.entries) {
      final vocab = entry.key;
      final incoming = entry.value as Map<String, dynamic>;
      final incomingCount = (incoming['count'] as num).toInt();
      final incomingProto = (incoming['prototype'] as List)
          .map((e) => (e as num).toDouble())
          .toList();

      final existing = await DbService.getPrototype(vocab);

      if (existing == null) {
        await DbService.upsertPrototype(
          vocabulary: vocab,
          protoJson: jsonEncode(incomingProto),
          count: incomingCount,
        );
      } else {
        final existingCount = existing['count'] as int;
        final existingVec =
            (jsonDecode(existing['prototype_json'] as String) as List)
                .map((e) => (e as num).toDouble())
                .toList();
        final totalCount = existingCount + incomingCount;
        final merged = List.generate(
          incomingProto.length,
          (i) =>
              (existingVec[i] * existingCount +
                  incomingProto[i] * incomingCount) /
              totalCount,
        );
        await DbService.upsertPrototype(
          vocabulary: vocab,
          protoJson: jsonEncode(merged),
          count: totalCount,
        );
      }
      mergedProtos++;
    }

    final embeddings = data['embeddings'] as List<dynamic>? ?? [];
    for (final emb in embeddings) {
      try {
        await DbService.db.insert(kTableEmbeddings, {
          'vocabulary': emb['vocabulary'],
          'embedding_json': emb['embeddingJson'],
          'is_fallback': emb['isFallback'] ?? 0,
          'created_at': emb['createdAt'],
        });
        addedEmbeddings++;
      } catch (_) {}
    }

    return PrototypeImportResult(
      success: true,
      mergedPrototypes: mergedProtos,
      addedEmbeddings: addedEmbeddings,
    );
  }
}
