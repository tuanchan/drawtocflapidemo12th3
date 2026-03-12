// logic.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as di;

const double kLogicalSize = 360.0;
const String kLang = 'zh-Hant';

// ── Models ───────────────────────────────────────────────────────────────────

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

  CanvasData startStroke(double x, double y) => CanvasData(
        strokes: strokes,
        redo: [],
        active: StrokeData([StrokePoint(x, y, _now())]),
      );

  CanvasData addPoint(double x, double y) {
    if (active == null) return this;
    return CanvasData(
      strokes: strokes,
      redo: redo,
      active: StrokeData([...active!.points, StrokePoint(x, y, _now())]),
    );
  }

  CanvasData endStroke() {
    if (active == null || active!.isEmpty)
      return CanvasData(strokes: strokes, redo: redo);
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

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}

class RecCandidate {
  final String text;
  final double? score;
  const RecCandidate(this.text, this.score);
}

class RecResult {
  final List<RecCandidate> candidates;
  final String? error;
  const RecResult({this.candidates = const [], this.error});
}

// ── Recognition service ───────────────────────────────────────────────────────

class RecService {
  final _mgr = di.DigitalInkRecognizerModelManager();
  di.DigitalInkRecognizer? _rec;

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<bool> isReady() async {
    if (!_supported) return false;
    try {
      return await _mgr.isModelDownloaded(kLang);
    } catch (_) {
      return false;
    }
  }

  Future<void> download() async {
    if (!_supported) throw Exception('Only Android/iOS supported');
    if (await isReady()) return;
    await _mgr.downloadModel(kLang);
  }

  Future<RecResult> recognize(List<StrokeData> strokes) async {
    if (!_supported) {
      return const RecResult(error: 'Android/iOS only');
    }
    if (strokes.isEmpty) return const RecResult(error: 'Canvas empty');

    try {
      _rec ??= di.DigitalInkRecognizer(languageCode: kLang);

      final ink = di.Ink();
      ink.strokes = strokes.where((s) => s.points.isNotEmpty).map((s) {
        final ms = di.Stroke();
        ms.points = s.points
            .map((p) => di.StrokePoint(x: p.x, y: p.y, t: p.t))
            .toList();
        return ms;
      }).toList();

      final ctx = di.DigitalInkRecognitionContext(
        writingArea: di.WritingArea(width: kLogicalSize, height: kLogicalSize),
      );

      final res = await _rec!.recognize(ink, context: ctx);
      return RecResult(
        candidates: res.map((e) => RecCandidate(e.text, e.score)).toList(),
      );
    } catch (e) {
      return RecResult(error: e.toString());
    }
  }

  Future<void> dispose() async {
    try {
      await _rec?.close();
    } catch (_) {}
    _rec = null;
  }
}

// ── App State ─────────────────────────────────────────────────────────────────

class AppState extends ChangeNotifier {
  final _svc = RecService();

  bool _ready = false;
  String? _initError;
  bool _modelReady = false;
  bool _modelDownloading = false;
  bool _busy = false;
  CanvasData _canvas = const CanvasData();
  RecResult? _result;

  bool get ready => _ready;
  String? get initError => _initError;
  bool get modelReady => _modelReady;
  bool get modelDownloading => _modelDownloading;
  bool get busy => _busy;
  CanvasData get canvas => _canvas;
  RecResult? get result => _result;

  bool get canCheck =>
      _canvas.strokes.isNotEmpty && _modelReady && !_busy && !_modelDownloading;

  Future<void> init() async {
    _ready = true;
    notifyListeners();
  }

  // ── Canvas ──

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

  // ── Model ──

  Future<void> downloadModel() async {
    if (_modelDownloading) return;
    _modelDownloading = true;
    notifyListeners();
    try {
      await _svc.download();
      _modelReady = await _svc.isReady();
    } catch (e) {
      _result = RecResult(error: e.toString());
    } finally {
      _modelDownloading = false;
      notifyListeners();
    }
  }

  // ── Recognize ──

  Future<void> recognize() async {
    if (_busy || _canvas.strokes.isEmpty) return;
    _busy = true;
    _result = null;
    notifyListeners();
    try {
      _result = await _svc.recognize(_canvas.strokes);
    } catch (e) {
      _result = RecResult(error: e.toString());
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }
}
