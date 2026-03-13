// logic.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const double kLogicalSize = 360.0;
const String kDbAsset = 'assets/db/tocfl_vocab_clean.db';
const String kDbFile = 'tocfl_vocab_clean.db';
const String kTable = 'vocab_clean';
const String kModelAsset = 'assets/ml/handwriting.tflite';
const String kLabelsAsset = 'assets/ml/labels.json';
const int kModelInputSize = 64;
const int kTopK = 15;

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
    return CanvasData(
      strokes: strokes,
      redo: redo,
      active: StrokeData([
        ...active!.points,
        StrokePoint(_c(x), _c(y), _now()),
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

  static Future<List<VocabEntry>> findByChars(List<String> chars) async {
    if (chars.isEmpty) return [];
    final ph = chars.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM $kTable WHERE vocabulary IN ($ph) LIMIT 20',
      chars,
    );
    return rows.map(VocabEntry.fromMap).toList();
  }

  static Future<List<VocabEntry>> search(String q) async {
    if (q.trim().isEmpty) return [];
    final rows = await db.rawQuery(
      'SELECT * FROM $kTable WHERE vocabulary LIKE ? OR pinyin LIKE ? LIMIT 20',
      ['%$q%', '%$q%'],
    );
    return rows.map(VocabEntry.fromMap).toList();
  }
}

// ── TFLite Recognizer ─────────────────────────────────────────────────────────

class HwrService {
  static Interpreter? _interp;
  static List<String> _labels = [];
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;

    final raw = await rootBundle.loadString(kLabelsAsset);
    _labels = List<String>.from(jsonDecode(raw) as List);
    debugPrint('[HwrService] ${_labels.length} classes loaded');

    try {
      final buffer = await rootBundle.load(kModelAsset);
      final bytes = buffer.buffer.asUint8List(
        buffer.offsetInBytes,
        buffer.lengthInBytes,
      );

      debugPrint('[HwrService] model bytes: ${bytes.length}');
      _interp = Interpreter.fromBuffer(bytes);

      final inShape = _interp!.getInputTensor(0).shape;
      final outShape = _interp!.getOutputTensor(0).shape;
      debugPrint('[HwrService] input:$inShape output:$outShape');

      _ready = true;
    } catch (e, st) {
      debugPrint('[HwrService] init failed: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  static Future<List<String>> recognize(
    List<StrokeData> strokes, {
    int topK = kTopK,
    double strokeWidth = 10.0,
  }) async {
    if (!_ready) {
      await init();
    }

    if (strokes.isEmpty) return [];

    final input = await _prepareInput(strokes, strokeWidth: strokeWidth);
    final output = [List<double>.filled(_labels.length, 0.0)];

    _interp!.run(input, output);

    final scores = output[0];
    final indexed = List.generate(scores.length, (i) => MapEntry(i, scores[i]));
    indexed.sort((a, b) => b.value.compareTo(a.value));

    final result = indexed
        .take(topK)
        .map((e) => _labels[e.key])
        .where((ch) => ch.isNotEmpty && ch != '?')
        .toList();

    debugPrint('[HwrService] top5: ${result.take(5).join(" ")}');
    return result;
  }

  static Future<List> _prepareInput(
    List<StrokeData> strokes, {
    double strokeWidth = 10.0,
  }) async {
    const int renderSz = 256;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final scale = renderSz / kLogicalSize;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, renderSz.toDouble(), renderSz.toDouble()),
      Paint()..color = Colors.white,
    );

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
          7 * scale,
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
    final uiImage = await picture.toImage(renderSz, renderSz);
    final byteData =
        await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rgba = byteData!.buffer.asUint8List();

    final srcImg = img.Image.fromBytes(
      width: renderSz,
      height: renderSz,
      bytes: rgba.buffer,
      format: img.Format.uint8,
      numChannels: 4,
    );

    final resized = img.copyResize(
      img.grayscale(srcImg),
      width: kModelInputSize,
      height: kModelInputSize,
      interpolation: img.Interpolation.average,
    );

    return List.generate(
      1,
      (_) => List.generate(
        kModelInputSize,
        (y) => List.generate(
          kModelInputSize,
          (x) => [resized.getPixel(x, y).r / 255.0],
        ),
      ),
    );
  }

  static void close() {
    _interp?.close();
    _interp = null;
    _ready = false;
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

  void setStrokeWidth(double v) {
    _strokeWidth = v.clamp(4.0, 24.0);
    notifyListeners();
  }

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

  void setSearchQuery(String q) {
    _searchQuery = q;
    _searchDebounce?.cancel();

    if (q.trim().isEmpty) {
      _searchSuggestions = [];
      notifyListeners();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 250), () async {
      final results = await DbService.search(q);
      _searchSuggestions = results;
      notifyListeners();
    });
  }

  void selectSuggestion(VocabEntry entry) {
    _pinnedEntry = entry;
    _searchQuery = '';
    _searchSuggestions = [];
    notifyListeners();
  }

  void resetPinned() {
    _pinnedEntry = null;
    notifyListeners();
  }

  Future<void> recognize() async {
    if (_busy || _canvas.strokes.isEmpty) return;

    _busy = true;
    _result = null;
    notifyListeners();

    try {
      await HwrService.init();

      final topChars = await HwrService.recognize(
        _canvas.strokes,
        strokeWidth: _strokeWidth,
      );

      final lookup = <String>{};
      for (final ch in topChars) {
        lookup.add(ch);
        for (int i = 0; i < ch.length; i++) {
          final c = ch[i];
          if (c.trim().isNotEmpty) lookup.add(c);
        }
      }

      final matches = await DbService.findByChars(lookup.toList());
      _result = RecResult(matches: matches, raw: topChars);
    } catch (e, st) {
      debugPrint('[recognize] $e');
      debugPrint(st.toString());
      _result = RecResult(error: e.toString());
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    HwrService.close();
    super.dispose();
  }
}
