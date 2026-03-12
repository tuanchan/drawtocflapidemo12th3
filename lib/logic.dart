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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const double kLogicalSize = 360.0;
const String kDbAsset = 'assets/db/tocfl_vocab_clean.db';
const String kDbFile = 'tocfl_vocab_clean.db';
const String kTable = 'vocab_clean';
final kVisionChannel = MethodChannel('tocfl/vision');

// ── Stroke / Canvas models ────────────────────────────────────────────────────

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
        redo: [],
        active: StrokeData([StrokePoint(_c(x), _c(y), _now())]),
      );

  CanvasData addPoint(double x, double y) {
    if (active == null) return this;
    return CanvasData(
      strokes: strokes,
      redo: redo,
      active:
          StrokeData([...active!.points, StrokePoint(_c(x), _c(y), _now())]),
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
        vocabulary: m['vocabulary'] as String,
        pinyin: m['pinyin'] as String?,
        levelCode: m['level_code'] as String?,
        context: m['context'] as String?,
        partOfSpeech: m['part_of_speech'] as String?,
        bopomofo: m['bopomofo'] as String?,
        variantGroup: m['variant_group'] as String?,
      );
}

class RecResult {
  final List<VocabEntry> matches;
  final List<String> raw;
  final String? error;
  const RecResult({this.matches = const [], this.raw = const [], this.error});
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
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      await File(path).writeAsBytes(bytes, flush: true);
    }
    _db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
  }

  static Database get db => _db!;

  static Future<List<VocabEntry>> findByChars(List<String> chars) async {
    if (chars.isEmpty) return [];
    final placeholders = chars.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM $kTable WHERE vocabulary IN ($placeholders) LIMIT 20',
      chars,
    );
    return rows.map(VocabEntry.fromMap).toList();
  }
}

// ── Render canvas → PNG ───────────────────────────────────────────────────────

Future<Uint8List> renderStrokes(List<StrokeData> strokes) async {
  const int sz = 480;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final scale = sz / kLogicalSize;

  canvas.drawRect(
    Rect.fromLTWH(0, 0, sz.toDouble(), sz.toDouble()),
    Paint()..color = Colors.black,
  );

  final ink = Paint()
    ..color = Colors.white
    ..strokeWidth = 12 * scale
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;

  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    if (s.points.length == 1) {
      canvas.drawCircle(
        Offset(s.points.first.x * scale, s.points.first.y * scale),
        6 * scale,
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
  final image = await picture.toImage(sz, sz);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

// ── App State ─────────────────────────────────────────────────────────────────

class AppState extends ChangeNotifier {
  bool _ready = false;
  String? _initError;
  bool _busy = false;
  CanvasData _canvas = const CanvasData();
  RecResult? _result;

  bool get ready => _ready;
  String? get initError => _initError;
  bool get busy => _busy;
  CanvasData get canvas => _canvas;
  RecResult? get result => _result;
  bool get canCheck => _canvas.strokes.isNotEmpty && !_busy;

  Future<void> init() async {
    try {
      await DbService.init();
    } catch (e, st) {
      debugPrint('[AppState] init error: $e\n$st');
      _initError = e.toString();
      _ready = true;
      notifyListeners();
      return;
    }
    _ready = true;
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

  Future<void> recognize() async {
    if (_busy || _canvas.strokes.isEmpty) return;
    _busy = true;
    _result = null;
    notifyListeners();

    try {
      final imgBytes = await renderStrokes(_canvas.strokes);

      final List<dynamic> raw = await kVisionChannel.invokeMethod('recognize', {
        'image': imgBytes,
      });

      final rawStrings = raw.cast<String>();

      // Extract chars + full words to lookup
      final lookup = <String>{};
      for (final s in rawStrings) {
        final trimmed = s.trim();
        if (trimmed.isEmpty) continue;
        lookup.add(trimmed);
        for (int i = 0; i < trimmed.length; i++) {
          final ch = trimmed[i];
          if (ch.trim().isNotEmpty) lookup.add(ch);
        }
      }

      final matches = await DbService.findByChars(lookup.toList());
      _result = RecResult(matches: matches, raw: rawStrings);
    } catch (e) {
      debugPrint('[recognize] $e');
      _result = RecResult(error: e.toString());
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
