// logic.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const double kLogicalSize = 360.0;
const String kDbAsset = 'assets/db/tocfl_vocab_clean.db';
const String kDbFile = 'tocfl_vocab_clean.db';
const String kTable = 'vocab_clean';
const int kTopK = 10;
const int kDbVersion = 5;

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

enum MatchSource { mlkit, none }

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

// ── Realtime Candidate ────────────────────────────────────────────────────────

class RealtimeCandidate {
  final String text;
  const RealtimeCandidate({required this.text});
}

// ── Settings Service ──────────────────────────────────────────────────────────

class SettingsService {
  static const _kAccentColor = 'accent_color';
  static const _kShowRealtimeChips = 'show_realtime_chips';
  static const _kLanguageCode = 'mlkit_language_code';
  static const _kAlwaysShowTemplate = 'always_show_template';

  static Future<bool> loadShowRealtimeChips() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kShowRealtimeChips) ?? true;
  }

  static Future<void> saveShowRealtimeChips(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowRealtimeChips, v);
  }

  static Future<Color> loadAccentColor() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_kAccentColor);
    return v != null ? Color(v) : const Color(0xFFE8D5B0);
  }

  static Future<void> saveAccentColor(Color c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAccentColor, c.value);
  }

  static Future<String> loadLanguageCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLanguageCode) ?? 'zh-Hant';
  }

  static Future<void> saveLanguageCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLanguageCode, code);
  }

  static Future<bool> loadAlwaysShowTemplate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAlwaysShowTemplate) ?? true;
  }

  static Future<void> saveAlwaysShowTemplate(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAlwaysShowTemplate, v);
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
      onUpgrade: _onUpgrade,
    );
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
}

// ── ML Kit Recognition Service ────────────────────────────────────────────────

class MlKitRecognitionService {
  static mlkit.DigitalInkRecognizer? _recognizer;
  static String? _activeLanguage;
  static final _modelManager = mlkit.DigitalInkRecognizerModelManager();

  static Future<bool> isModelDownloaded(String languageCode) async {
    return await _modelManager.isModelDownloaded(languageCode);
  }

  static Future<void> downloadModel(String languageCode) async {
    await _modelManager.downloadModel(languageCode);
  }

  static Future<List<String>> recognize({
    required List<StrokeData> strokes,
    required String languageCode,
  }) async {
    if (strokes.isEmpty) return [];

    final downloaded = await isModelDownloaded(languageCode);
    if (!downloaded) return [];

    // Create or reuse recognizer for the current language
    if (_recognizer == null || _activeLanguage != languageCode) {
      _recognizer?.close();
      _recognizer = mlkit.DigitalInkRecognizer(languageCode: languageCode);
      _activeLanguage = languageCode;
    }

    // Convert app strokes → ML Kit Ink
    final ink = mlkit.Ink();
    for (final strokeData in strokes) {
      if (strokeData.points.isEmpty) continue;
      final stroke = mlkit.Stroke();
      for (final pt in strokeData.points) {
        stroke.points.add(mlkit.StrokePoint(
          x: pt.x.toDouble(),
          y: pt.y.toDouble(),
          t: pt.t,
        ));
      }
      ink.strokes.add(stroke);
    }

    if (ink.strokes.isEmpty) return [];

    final candidates = await _recognizer!.recognize(ink);
    return candidates.map((c) => c.text).toList();
  }

  static void close() {
    _recognizer?.close();
    _recognizer = null;
    _activeLanguage = null;
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

  // Realtime ML Kit recognition
  List<RealtimeCandidate> _realtimeCandidates = const [];
  bool _realtimeBusy = false;
  bool _realtimePending = false;
  Timer? _realtimeDebounce;

  // Settings
  bool _showRealtimeChips = true;
  Color _accentColor = const Color(0xFFE8D5B0);
  String _languageCode = 'zh-Hant';
  bool _modelReady = false;
  bool _modelDownloading = false;
  bool _alwaysShowTemplate = true;

  // Getters
  bool get ready => _ready;
  String? get initError => _initError;
  bool get busy => _busy;
  CanvasData get canvas => _canvas;
  RecResult? get result => _result;
  double get strokeWidth => _strokeWidth;
  String get searchQuery => _searchQuery;
  List<VocabEntry> get searchSuggestions => _searchSuggestions;
  VocabEntry? get pinnedEntry => _pinnedEntry;
  bool get showRealtimeChips => _showRealtimeChips;
  Color get accentColor => _accentColor;
  String get languageCode => _languageCode;
  bool get modelReady => _modelReady;
  bool get modelDownloading => _modelDownloading;
  bool get alwaysShowTemplate => _alwaysShowTemplate;
  List<RealtimeCandidate> get realtimeCandidates => _realtimeCandidates;
  bool get realtimeBusy => _realtimeBusy;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      await DbService.init();
      _accentColor = await SettingsService.loadAccentColor();
      _showRealtimeChips = await SettingsService.loadShowRealtimeChips();
      _languageCode = await SettingsService.loadLanguageCode();
      _alwaysShowTemplate = await SettingsService.loadAlwaysShowTemplate();
      await _ensureModelReady();
    } catch (e, st) {
      debugPrint('[AppState.init] $e');
      debugPrint(st.toString());
      _initError = e.toString();
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  Future<void> _ensureModelReady() async {
    try {
      _modelReady =
          await MlKitRecognitionService.isModelDownloaded(_languageCode);
      if (!_modelReady) {
        _modelDownloading = true;
        notifyListeners();
        await MlKitRecognitionService.downloadModel(_languageCode);
        _modelReady = true;
      }
    } catch (e) {
      debugPrint('[_ensureModelReady] $e');
    } finally {
      _modelDownloading = false;
    }
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  void setLanguageCode(String code) {
    if (_languageCode == code) return;
    _languageCode = code;
    _modelReady = false;
    MlKitRecognitionService.close();
    SettingsService.saveLanguageCode(code);
    notifyListeners();
    _ensureModelReady().then((_) => notifyListeners());
  }

  void setAccentColor(Color c) {
    _accentColor = c;
    SettingsService.saveAccentColor(c);
    notifyListeners();
  }

  void setShowRealtimeChips(bool v) {
    _showRealtimeChips = v;
    SettingsService.saveShowRealtimeChips(v);
    notifyListeners();
  }

  void setAlwaysShowTemplate(bool v) {
    _alwaysShowTemplate = v;
    SettingsService.saveAlwaysShowTemplate(v);
    notifyListeners();
  }

  // ── Canvas ────────────────────────────────────────────────────────────────

  List<StrokeData> _allCurrentStrokes() {
    if (_canvas.active == null) return _canvas.strokes;
    return [..._canvas.strokes, _canvas.active!];
  }

  void setStrokeWidth(double v) {
    _strokeWidth = v.clamp(4.0, 24.0);
    notifyListeners();
  }

  void strokeStart(double x, double y) {
    _canvas = _canvas.startStroke(x, y);
    notifyListeners();
  }

  void strokeAdd(double x, double y) {
    _canvas = _canvas.addPoint(x, y);
    notifyListeners();
    _realtimeDebounce?.cancel();
    _realtimeDebounce = Timer(const Duration(milliseconds: 180), () {
      _runMlKitRecognize();
    });
  }

  void strokeEnd() {
    _canvas = _canvas.endStroke();
    notifyListeners();
    _realtimeDebounce?.cancel();
    _runMlKitRecognize();
  }

  void undo() {
    _canvas = _canvas.undo();
    _result = null;
    notifyListeners();
    // Re-run recognition with remaining strokes
    if (_canvas.hasStrokes) {
      _realtimeDebounce?.cancel();
      _runMlKitRecognize();
    } else {
      _realtimeCandidates = const [];
      notifyListeners();
    }
  }

  void clear() {
    _canvas = _canvas.clear();
    _result = null;
    _realtimeCandidates = const [];
    notifyListeners();
  }

  // ── Realtime ML Kit Recognition ───────────────────────────────────────────

  Future<void> _runMlKitRecognize() async {
    if (_realtimeBusy) {
      _realtimePending = true;
      return;
    }
    _realtimePending = false;
    _realtimeBusy = true;

    try {
      final strokes = _allCurrentStrokes();
      if (strokes.isEmpty) return;

      if (!_modelReady) return;

      final rawCandidates = await MlKitRecognitionService.recognize(
        strokes: strokes,
        languageCode: _languageCode,
      );

      if (rawCandidates.isEmpty) {
        _realtimeCandidates = const [];
      } else {
        _realtimeCandidates = rawCandidates
            .take(kTopK)
            .map((t) => RealtimeCandidate(text: t))
            .toList();

        // Also build lookup tokens and populate _result for info display
        final tokens = <String>{};
        for (final item in rawCandidates.take(kTopK)) {
          final s = item.trim();
          if (s.isEmpty) continue;
          tokens.add(s);
          for (final rune in s.runes) {
            final ch = String.fromCharCode(rune).trim();
            if (ch.isNotEmpty) tokens.add(ch);
          }
        }

        final matches =
            await DbService.findByVocabularyTokens(tokens.toList());

        // Sort matches by candidate order
        final orderMap = <String, int>{};
        for (var i = 0; i < rawCandidates.length; i++) {
          orderMap.putIfAbsent(rawCandidates[i], () => i);
        }
        matches.sort((a, b) {
          final aIdx = orderMap[a.vocabulary] ?? 9999;
          final bIdx = orderMap[b.vocabulary] ?? 9999;
          return aIdx.compareTo(bIdx);
        });

        _result = RecResult(
          matches: matches,
          raw: rawCandidates.take(kTopK).toList(),
          matchSource: MatchSource.mlkit,
        );
      }
    } catch (e) {
      debugPrint('[_runMlKitRecognize] $e');
    } finally {
      _realtimeBusy = false;
      notifyListeners();
      if (_realtimePending) {
        _realtimePending = false;
        _runMlKitRecognize();
      }
    }
  }

  // ── Search ────────────────────────────────────────────────────────────────

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
    _searchQuery = '';
    _searchSuggestions = [];
    notifyListeners();
  }

  void resetPinned() {
    _pinnedEntry = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _realtimeDebounce?.cancel();
    MlKitRecognitionService.close();
    super.dispose();
  }
}
