// logic.dart
// All models, database service, state management, canvas stroke engine,
// and repository-style logic for TOCFL Writer app.
// No UI code here — only pure logic, models, and services.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as di;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ══════════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ══════════════════════════════════════════════════════════════════════════════

const kDbAssetPath = 'assets/db/tocfl_vocab_clean.db';
const kDbFileName = 'tocfl_vocab_clean.db';
const kTableName = 'vocab_clean';

// All known levels in display order
const kAllLevels = [
  'Novice 1',
  'Novice 2',
  'Level 1',
  'Level 2',
  'Level 3',
  'Level 4',
  'Level 5',
];

// Level display labels
const kLevelLabels = {
  'Novice 1': '準備級一',
  'Novice 2': '準備級二',
  'Level 1': '入門級',
  'Level 2': '基礎級',
  'Level 3': '進階級',
  'Level 4': '高階級',
  'Level 5': '流利級',
};

// Canvas constants
const double kCanvasLogicalSize = 360.0;
const double kStrokeWidth = 13.0;
const Color kStrokeColor = Color(0xFFF5E6C8);
const Color kCanvasBg = Color(0xFF0F0E0A);
const Color kGridColor = Color(0x26B4783C); // rgba(180,120,60,0.15)
const Color kGridBorder = Color(0x4DB4783C); // rgba(180,120,60,0.3)

// Digital ink recognition
const String kRecognitionLanguageCode = 'zh-Hant';

// ══════════════════════════════════════════════════════════════════════════════
// DATA MODELS
// ══════════════════════════════════════════════════════════════════════════════

/// One vocabulary entry from the database
class VocabEntry {
  final int id;
  final int? sourceId;
  final String? sheetName;
  final String? levelCode;
  final String? context;
  final String vocabulary;
  final String? pinyin;
  final String? partOfSpeech;
  final String? bopomofo;
  final String? variantGroup;

  const VocabEntry({
    required this.id,
    this.sourceId,
    this.sheetName,
    this.levelCode,
    this.context,
    required this.vocabulary,
    this.pinyin,
    this.partOfSpeech,
    this.bopomofo,
    this.variantGroup,
  });

  factory VocabEntry.fromMap(Map<String, dynamic> map) {
    return VocabEntry(
      id: map['id'] as int,
      sourceId: map['source_id'] as int?,
      sheetName: map['sheet_name'] as String?,
      levelCode: map['level_code'] as String?,
      context: map['context'] as String?,
      vocabulary: map['vocabulary'] as String,
      pinyin: map['pinyin'] as String?,
      partOfSpeech: map['part_of_speech'] as String?,
      bopomofo: map['bopomofo'] as String?,
      variantGroup: map['variant_group'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is VocabEntry && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

// ══════════════════════════════════════════════════════════════════════════════
// RECOGNITION MODELS
// ══════════════════════════════════════════════════════════════════════════════

class RecognitionCandidate {
  final String text;
  final double? score;

  const RecognitionCandidate({
    required this.text,
    this.score,
  });
}

class RecognitionResult {
  final List<RecognitionCandidate> candidates;
  final bool modelReady;
  final String? error;

  const RecognitionResult({
    required this.candidates,
    required this.modelReady,
    this.error,
  });

  bool get hasCandidates => candidates.isNotEmpty;
  RecognitionCandidate? get best => hasCandidates ? candidates.first : null;
}

// ══════════════════════════════════════════════════════════════════════════════
// STROKE / CANVAS MODELS
// ══════════════════════════════════════════════════════════════════════════════

/// Single touch point with timestamp for potential recognizer use
class StrokePoint {
  final double x;
  final double y;
  final int timestamp; // milliseconds since epoch

  const StrokePoint(this.x, this.y, this.timestamp);
}

/// A single pen stroke = list of points drawn between touch-down and touch-up
class HandStroke {
  final List<StrokePoint> points;

  const HandStroke(this.points);

  bool get isEmpty => points.isEmpty;
  int get pointCount => points.length;
}

/// All strokes currently on the canvas, plus redo stack
class CanvasState {
  final List<HandStroke> strokes;
  final List<HandStroke> redoStack;
  final HandStroke? activeStroke; // stroke being drawn right now

  const CanvasState({
    this.strokes = const [],
    this.redoStack = const [],
    this.activeStroke,
  });

  bool get hasStrokes => strokes.isNotEmpty || activeStroke != null;

  CanvasState copyWith({
    List<HandStroke>? strokes,
    List<HandStroke>? redoStack,
    HandStroke? activeStroke,
    bool clearActive = false,
  }) {
    return CanvasState(
      strokes: strokes ?? this.strokes,
      redoStack: redoStack ?? this.redoStack,
      activeStroke: clearActive ? null : (activeStroke ?? this.activeStroke),
    );
  }

  /// Start a new stroke at given point
  CanvasState startStroke(double x, double y) {
    final pt = StrokePoint(x, y, DateTime.now().millisecondsSinceEpoch);
    return copyWith(
      activeStroke: HandStroke([pt]),
      redoStack: [], // starting new stroke clears redo
    );
  }

  /// Extend active stroke
  CanvasState addPoint(double x, double y) {
    if (activeStroke == null) return this;
    final pt = StrokePoint(x, y, DateTime.now().millisecondsSinceEpoch);
    final updated = HandStroke([...activeStroke!.points, pt]);
    return copyWith(activeStroke: updated);
  }

  /// Commit active stroke to completed strokes list
  CanvasState endStroke() {
    if (activeStroke == null || activeStroke!.isEmpty) {
      return copyWith(clearActive: true);
    }
    return CanvasState(
      strokes: [...strokes, activeStroke!],
      redoStack: redoStack,
      activeStroke: null,
    );
  }

  /// Undo last completed stroke
  CanvasState undo() {
    if (strokes.isEmpty) return this;
    final removed = strokes.last;
    return CanvasState(
      strokes: strokes.sublist(0, strokes.length - 1),
      redoStack: [...redoStack, removed],
      activeStroke: activeStroke,
    );
  }

  /// Redo last undone stroke
  CanvasState redo() {
    if (redoStack.isEmpty) return this;
    final restored = redoStack.last;
    return CanvasState(
      strokes: [...strokes, restored],
      redoStack: redoStack.sublist(0, redoStack.length - 1),
      activeStroke: activeStroke,
    );
  }

  /// Clear everything
  CanvasState clear() {
    return const CanvasState();
  }

  bool get canUndo => strokes.isNotEmpty;
  bool get canRedo => redoStack.isNotEmpty;
}

// ══════════════════════════════════════════════════════════════════════════════
// OFFLINE RECOGNITION SERVICE
// ══════════════════════════════════════════════════════════════════════════════

class OfflineRecognitionService {
  final di.DigitalInkRecognizerModelManager _modelManager =
      di.DigitalInkRecognizerModelManager();

  di.DigitalInkRecognizer? _recognizer;

  bool get _platformSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  di.DigitalInkRecognizer _ensureRecognizer() {
    return _recognizer ??=
        di.DigitalInkRecognizer(languageCode: kRecognitionLanguageCode);
  }

  Future<bool> isModelDownloaded() async {
    if (!_platformSupported) return false;
    try {
      return await _modelManager.isModelDownloaded(kRecognitionLanguageCode);
    } catch (e) {
      debugPrint('[OfflineRecognitionService] isModelDownloaded error: $e');
      return false;
    }
  }

  Future<void> downloadModelIfNeeded() async {
    if (!_platformSupported) {
      throw Exception('Digital Ink Recognition chỉ hỗ trợ Android/iOS.');
    }
    final ready = await isModelDownloaded();
    if (ready) return;
    await _modelManager.downloadModel(kRecognitionLanguageCode);
  }

  Future<RecognitionResult> recognize(List<HandStroke> strokes) async {
    if (!_platformSupported) {
      return const RecognitionResult(
        candidates: [],
        modelReady: false,
        error: 'Digital Ink Recognition chỉ hỗ trợ Android/iOS.',
      );
    }

    if (strokes.isEmpty) {
      return RecognitionResult(
        candidates: const [],
        modelReady: await isModelDownloaded(),
        error: 'Canvas đang trống.',
      );
    }

    try {
      await downloadModelIfNeeded();

      final ink = _toInk(strokes);
      final recognizer = _ensureRecognizer();

      final context = di.DigitalInkRecognitionContext(
        writingArea: di.WritingArea(
          width: kCanvasLogicalSize,
          height: kCanvasLogicalSize,
        ),
      );

      final result = await recognizer.recognize(ink, context: context);

      return RecognitionResult(
        modelReady: true,
        candidates: result
            .map(
              (e) => RecognitionCandidate(
                text: e.text,
                score: e.score,
              ),
            )
            .toList(),
      );
    } catch (e) {
      debugPrint('[OfflineRecognitionService] recognize error: $e');
      return RecognitionResult(
        candidates: const [],
        modelReady: await isModelDownloaded(),
        error: e.toString(),
      );
    }
  }

  di.Ink _toInk(List<HandStroke> strokes) {
    final ink = di.Ink();
    ink.strokes =
        strokes.where((s) => s.points.isNotEmpty).map(_toMlStroke).toList();
    return ink;
  }

  di.Stroke _toMlStroke(HandStroke stroke) {
    final mlStroke = di.Stroke();
    mlStroke.points = stroke.points
        .map(
          (p) => di.StrokePoint(
            x: p.x,
            y: p.y,
            t: p.timestamp,
          ),
        )
        .toList();
    return mlStroke;
  }

  Future<void> dispose() async {
    try {
      await _recognizer?.close();
    } catch (_) {}
    _recognizer = null;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// DATABASE SERVICE
// ══════════════════════════════════════════════════════════════════════════════

class DbService {
  static Database? _db;

  /// Resolve a safe writable directory for the DB file.
  /// Uses documents dir on mobile, temp dir on desktop as fallback.
  static Future<String> _resolveDbPath() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return p.join(dir.path, kDbFileName);
    } catch (_) {
      // Fallback for desktop platforms where documents dir may fail
      final dir = await getTemporaryDirectory();
      return p.join(dir.path, kDbFileName);
    }
  }

  /// Copy asset DB to local storage (only once), then open it.
  static Future<void> init() async {
    if (_db != null) return;

    final dbPath = await _resolveDbPath();
    debugPrint('[DbService] DB path: $dbPath');

    // Only copy from assets if not already on disk
    if (!File(dbPath).existsSync()) {
      debugPrint('[DbService] Copying database from assets...');
      final data = await rootBundle.load(kDbAssetPath);
      final bytes = data.buffer.asUint8List();
      await File(dbPath).writeAsBytes(bytes, flush: true);
      debugPrint('[DbService] Database copied.');
    } else {
      debugPrint('[DbService] Database already exists.');
    }

    // Use databaseFactory (set to FFI on desktop in main.dart)
    _db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    debugPrint('[DbService] Database opened successfully.');
  }

  static Database get db {
    assert(_db != null, 'DbService.init() must be called before using db');
    return _db!;
  }

  /// Return all distinct level_code values
  static Future<List<String>> fetchLevels() async {
    final rows = await db.rawQuery(
      'SELECT DISTINCT level_code FROM $kTableName WHERE level_code IS NOT NULL ORDER BY level_code',
    );
    return rows.map((r) => r['level_code'] as String).toList();
  }

  /// Return all distinct context values, optionally filtered by level
  static Future<List<String>> fetchContexts({String? levelCode}) async {
    if (levelCode != null && levelCode.isNotEmpty) {
      final rows = await db.rawQuery(
        'SELECT DISTINCT context FROM $kTableName WHERE level_code = ? AND context IS NOT NULL ORDER BY context',
        [levelCode],
      );
      return rows.map((r) => r['context'] as String).toList();
    } else {
      final rows = await db.rawQuery(
        'SELECT DISTINCT context FROM $kTableName WHERE context IS NOT NULL ORDER BY context',
      );
      return rows.map((r) => r['context'] as String).toList();
    }
  }

  /// Search vocabulary with optional filters. Returns up to [limit] entries.
  static Future<List<VocabEntry>> search({
    String query = '',
    String? levelCode,
    String? context,
    int limit = 100,
    int offset = 0,
  }) async {
    final conditions = <String>[];
    final args = <dynamic>[];

    if (query.isNotEmpty) {
      conditions.add('(vocabulary LIKE ? OR pinyin LIKE ?)');
      args.add('%$query%');
      args.add('%$query%');
    }
    if (levelCode != null && levelCode.isNotEmpty) {
      conditions.add('level_code = ?');
      args.add(levelCode);
    }
    if (context != null && context.isNotEmpty) {
      conditions.add('context = ?');
      args.add(context);
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final sql =
        'SELECT * FROM $kTableName $where ORDER BY level_code, id LIMIT ? OFFSET ?';
    args.addAll([limit, offset]);

    final rows = await db.rawQuery(sql, args);
    return rows.map(VocabEntry.fromMap).toList();
  }

  /// Pick one random entry matching current filters
  static Future<VocabEntry?> random({
    String query = '',
    String? levelCode,
    String? context,
  }) async {
    final conditions = <String>[];
    final args = <dynamic>[];

    if (query.isNotEmpty) {
      conditions.add('(vocabulary LIKE ? OR pinyin LIKE ?)');
      args.add('%$query%');
      args.add('%$query%');
    }
    if (levelCode != null && levelCode.isNotEmpty) {
      conditions.add('level_code = ?');
      args.add(levelCode);
    }
    if (context != null && context.isNotEmpty) {
      conditions.add('context = ?');
      args.add(context);
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final countSql = 'SELECT COUNT(*) as c FROM $kTableName $where';
    final countResult = await db.rawQuery(countSql, args);
    final total = Sqflite.firstIntValue(countResult) ?? 0;
    if (total == 0) return null;

    final offset = Random().nextInt(total);
    final sql = 'SELECT * FROM $kTableName $where LIMIT 1 OFFSET ?';
    final rows = await db.rawQuery(sql, [...args, offset]);
    if (rows.isEmpty) return null;
    return VocabEntry.fromMap(rows.first);
  }

  /// Fetch a specific entry by id
  static Future<VocabEntry?> fetchById(int id) async {
    final rows =
        await db.query(kTableName, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return VocabEntry.fromMap(rows.first);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// LOCAL PREFERENCES SERVICE
// ══════════════════════════════════════════════════════════════════════════════

class PrefsService {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static SharedPreferences get prefs {
    assert(_prefs != null, 'PrefsService.init() must be called first');
    return _prefs!;
  }

  // ── Last filter state ──
  static String? get lastLevel => prefs.getString('last_level');
  static Future<void> setLastLevel(String? v) async {
    if (v == null) {
      await prefs.remove('last_level');
    } else {
      await prefs.setString('last_level', v);
    }
  }

  static String? get lastContext => prefs.getString('last_context');
  static Future<void> setLastContext(String? v) async {
    if (v == null) {
      await prefs.remove('last_context');
    } else {
      await prefs.setString('last_context', v);
    }
  }

  // ── Recent practiced words (store list of IDs) ──
  static List<int> get recentIds {
    return prefs.getStringList('recent_ids')?.map(int.parse).toList() ?? [];
  }

  static Future<void> addRecentId(int id) async {
    final ids = recentIds;
    ids.remove(id);
    ids.insert(0, id);
    final trimmed = ids.take(30).toList();
    await prefs.setStringList(
        'recent_ids', trimmed.map((e) => e.toString()).toList());
  }

  // ── Favorites ──
  static Set<int> get favoriteIds {
    return prefs.getStringList('fav_ids')?.map(int.parse).toSet() ?? {};
  }

  static Future<void> toggleFavorite(int id) async {
    final favs = favoriteIds;
    if (favs.contains(id)) {
      favs.remove(id);
    } else {
      favs.add(id);
    }
    await prefs.setStringList(
        'fav_ids', favs.map((e) => e.toString()).toList());
  }

  static bool isFavorite(int id) => favoriteIds.contains(id);
}

// ══════════════════════════════════════════════════════════════════════════════
// APP STATE (ChangeNotifier)
// ══════════════════════════════════════════════════════════════════════════════

/// Central application state, provided via Provider
class AppState extends ChangeNotifier {
  final OfflineRecognitionService _recognitionService =
      OfflineRecognitionService();

  // ── DB init ──
  bool _dbReady = false;
  bool get dbReady => _dbReady;

  // ── Filter state ──
  String _searchQuery = '';
  String? _selectedLevel;
  String? _selectedContext;

  String get searchQuery => _searchQuery;
  String? get selectedLevel => _selectedLevel;
  String? get selectedContext => _selectedContext;

  // ── Filter options ──
  List<String> _levels = [];
  List<String> _contexts = [];
  List<String> get levels => _levels;
  List<String> get contexts => _contexts;

  // ── Vocabulary list ──
  List<VocabEntry> _vocabList = [];
  bool _loadingList = false;
  bool _hasMore = true;
  int _listOffset = 0;
  static const int _pageSize = 80;

  List<VocabEntry> get vocabList => _vocabList;
  bool get loadingList => _loadingList;
  bool get hasMore => _hasMore;

  // ── Currently selected entry for practice ──
  VocabEntry? _selectedEntry;
  VocabEntry? get selectedEntry => _selectedEntry;

  // ── Canvas state ──
  CanvasState _canvasState = const CanvasState();
  CanvasState get canvasState => _canvasState;

  // ── Recent practiced ──
  List<VocabEntry> _recentEntries = [];
  List<VocabEntry> get recentEntries => _recentEntries;

  // ── Favorites ──
  Set<int> _favoriteIds = {};
  Set<int> get favoriteIds => _favoriteIds;

  // ── Practice list navigation ──
  int _currentListIndex = -1;
  int get currentListIndex => _currentListIndex;

  // ── Recognition ──
  bool _recognitionModelReady = false;
  bool _recognitionBusy = false;
  bool _recognitionModelDownloading = false;
  RecognitionResult? _lastRecognition;

  bool get recognitionModelReady => _recognitionModelReady;
  bool get recognitionBusy => _recognitionBusy;
  bool get recognitionModelDownloading => _recognitionModelDownloading;
  RecognitionResult? get lastRecognition => _lastRecognition;

  bool get canRecognize =>
      selectedEntry != null &&
      canvasState.strokes.isNotEmpty &&
      recognitionModelReady &&
      !recognitionBusy &&
      !recognitionModelDownloading;

  bool get isExactMatch {
    final target = _normalizeRecognitionText(selectedEntry?.vocabulary);
    final best = _normalizeRecognitionText(lastRecognition?.best?.text);
    return target.isNotEmpty && best.isNotEmpty && target == best;
  }

  bool get isNearMatch {
    final target = _normalizeRecognitionText(selectedEntry?.vocabulary);
    if (target.isEmpty || lastRecognition == null) return false;
    final top5 = lastRecognition!.candidates.take(5).map((e) {
      return _normalizeRecognitionText(e.text);
    });
    return top5.contains(target) && !isExactMatch;
  }

  String get recognitionVerdict {
    if (isExactMatch) return 'correct';
    if (isNearMatch) return 'near';
    return 'wrong';
  }

  String _normalizeRecognitionText(String? value) {
    return (value ?? '').trim();
  }

  // Debounce timer for search
  Timer? _searchDebounce;

  // ──────────────────────────────────────────────
  // INIT
  // ──────────────────────────────────────────────

  Future<void> init() async {
    await DbService.init();
    await PrefsService.init();

    _dbReady = true;

    // Restore last filters
    _selectedLevel = PrefsService.lastLevel;
    _selectedContext = PrefsService.lastContext;

    // Load filter options
    await _loadFilterOptions();

    // Load recent entries
    await _loadRecentEntries();

    // Load favorites
    _favoriteIds = PrefsService.favoriteIds;

    // Initial list load
    await _loadList(reset: true);

    // Check recognition model status
    await prepareRecognitionModel();

    notifyListeners();
  }

  // ──────────────────────────────────────────────
  // RECOGNITION
  // ──────────────────────────────────────────────

  Future<void> prepareRecognitionModel() async {
    try {
      _recognitionModelReady = await _recognitionService.isModelDownloaded();
    } catch (_) {
      _recognitionModelReady = false;
    }
    notifyListeners();
  }

  Future<void> downloadRecognitionModel() async {
    if (_recognitionModelDownloading) return;
    _recognitionModelDownloading = true;
    _lastRecognition = null;
    notifyListeners();

    try {
      await _recognitionService.downloadModelIfNeeded();
      _recognitionModelReady = await _recognitionService.isModelDownloaded();
    } catch (e) {
      _lastRecognition = RecognitionResult(
        candidates: const [],
        modelReady: false,
        error: e.toString(),
      );
      _recognitionModelReady = false;
    } finally {
      _recognitionModelDownloading = false;
      notifyListeners();
    }
  }

  Future<void> recognizeCurrentStrokes() async {
    if (_recognitionBusy) return;
    if (_selectedEntry == null) return;
    if (_canvasState.strokes.isEmpty) return;

    _recognitionBusy = true;
    _lastRecognition = null;
    notifyListeners();

    try {
      if (!_recognitionModelReady) {
        await _recognitionService.downloadModelIfNeeded();
        _recognitionModelReady = await _recognitionService.isModelDownloaded();
      }

      final result = await _recognitionService.recognize(_canvasState.strokes);
      _lastRecognition = result;
      _recognitionModelReady = result.modelReady;
    } catch (e) {
      _lastRecognition = RecognitionResult(
        candidates: const [],
        modelReady: _recognitionModelReady,
        error: e.toString(),
      );
    } finally {
      _recognitionBusy = false;
      notifyListeners();
    }
  }

  // ──────────────────────────────────────────────
  // FILTER OPTION LOADERS
  // ──────────────────────────────────────────────

  Future<void> _loadFilterOptions() async {
    _levels = await DbService.fetchLevels();
    _contexts = await DbService.fetchContexts(levelCode: _selectedLevel);
    // If selected context is no longer valid after level change, clear it
    if (_selectedContext != null && !_contexts.contains(_selectedContext)) {
      _selectedContext = null;
    }
  }

  // ──────────────────────────────────────────────
  // SEARCH & FILTER
  // ──────────────────────────────────────────────

  void setSearchQuery(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _searchQuery = q;
      _loadList(reset: true);
    });
  }

  Future<void> setLevel(String? level) async {
    _selectedLevel = level;
    _selectedContext = null; // reset context when level changes
    await PrefsService.setLastLevel(level);
    await PrefsService.setLastContext(null);
    // reload context options for new level
    _contexts = await DbService.fetchContexts(levelCode: level);
    await _loadList(reset: true);
    notifyListeners();
  }

  Future<void> setContext(String? context) async {
    _selectedContext = context;
    await PrefsService.setLastContext(context);
    await _loadList(reset: true);
    notifyListeners();
  }

  Future<void> clearFilters() async {
    _searchQuery = '';
    _selectedLevel = null;
    _selectedContext = null;
    await PrefsService.setLastLevel(null);
    await PrefsService.setLastContext(null);
    _contexts = await DbService.fetchContexts();
    await _loadList(reset: true);
    notifyListeners();
  }

  // ──────────────────────────────────────────────
  // VOCAB LIST LOADING
  // ──────────────────────────────────────────────

  Future<void> _loadList({bool reset = false}) async {
    if (_loadingList) return;
    if (reset) {
      _listOffset = 0;
      _hasMore = true;
      _vocabList = [];
    }
    if (!_hasMore) return;

    _loadingList = true;
    notifyListeners();

    try {
      final results = await DbService.search(
        query: _searchQuery,
        levelCode: _selectedLevel,
        context: _selectedContext,
        limit: _pageSize,
        offset: _listOffset,
      );

      if (reset) {
        _vocabList = results;
      } else {
        _vocabList = [..._vocabList, ...results];
      }
      _listOffset += results.length;
      _hasMore = results.length == _pageSize;
    } catch (e) {
      debugPrint('[AppState] Error loading list: $e');
    }

    _loadingList = false;
    notifyListeners();
  }

  /// Load more items (pagination)
  Future<void> loadMore() async {
    await _loadList(reset: false);
  }

  // ──────────────────────────────────────────────
  // ENTRY SELECTION
  // ──────────────────────────────────────────────

  Future<void> selectEntry(VocabEntry entry) async {
    _selectedEntry = entry;
    _currentListIndex = _vocabList.indexOf(entry);
    _canvasState = const CanvasState(); // clear canvas on new word
    _lastRecognition = null; // reset recognition when changing word
    await PrefsService.addRecentId(entry.id);
    _favoriteIds = PrefsService.favoriteIds;
    notifyListeners();
  }

  /// Navigate to next item in current list
  Future<void> nextEntry() async {
    if (_vocabList.isEmpty) return;
    int next = _currentListIndex + 1;
    if (next >= _vocabList.length) {
      // Try to load more
      if (_hasMore) await loadMore();
      if (next >= _vocabList.length) next = 0;
    }
    await selectEntry(_vocabList[next]);
  }

  /// Navigate to previous item in current list
  Future<void> prevEntry() async {
    if (_vocabList.isEmpty) return;
    int prev = _currentListIndex - 1;
    if (prev < 0) prev = _vocabList.length - 1;
    await selectEntry(_vocabList[prev]);
  }

  /// Pick a random entry matching current filters
  Future<void> randomEntry() async {
    final entry = await DbService.random(
      query: _searchQuery,
      levelCode: _selectedLevel,
      context: _selectedContext,
    );
    if (entry != null) {
      await selectEntry(entry);
    }
  }

  // ──────────────────────────────────────────────
  // CANVAS OPERATIONS
  // ──────────────────────────────────────────────

  void canvasStartStroke(double x, double y) {
    _canvasState = _canvasState.startStroke(x, y);
    notifyListeners();
  }

  void canvasAddPoint(double x, double y) {
    _canvasState = _canvasState.addPoint(x, y);
    notifyListeners();
  }

  void canvasEndStroke() {
    _canvasState = _canvasState.endStroke();
    notifyListeners();
  }

  void canvasUndo() {
    _canvasState = _canvasState.undo();
    _lastRecognition = null;
    notifyListeners();
  }

  void canvasRedo() {
    _canvasState = _canvasState.redo();
    _lastRecognition = null;
    notifyListeners();
  }

  void canvasClear() {
    _canvasState = _canvasState.clear();
    _lastRecognition = null;
    notifyListeners();
  }

  // ──────────────────────────────────────────────
  // FAVORITES
  // ──────────────────────────────────────────────

  Future<void> toggleFavorite(int id) async {
    await PrefsService.toggleFavorite(id);
    _favoriteIds = PrefsService.favoriteIds;
    notifyListeners();
  }

  bool isFavorite(int id) => _favoriteIds.contains(id);

  // ──────────────────────────────────────────────
  // RECENT ENTRIES
  // ──────────────────────────────────────────────

  Future<void> _loadRecentEntries() async {
    final ids = PrefsService.recentIds;
    final entries = <VocabEntry>[];
    for (final id in ids.take(10)) {
      final e = await DbService.fetchById(id);
      if (e != null) entries.add(e);
    }
    _recentEntries = entries;
  }

  Future<void> refreshRecent() async {
    await _loadRecentEntries();
    notifyListeners();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _recognitionService.dispose();
    super.dispose();
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CANVAS PAINTER
// ══════════════════════════════════════════════════════════════════════════════

/// Custom painter that draws all strokes + optional placeholder
class HandwritingPainter extends CustomPainter {
  final CanvasState state;
  final String? placeholderChar;
  final double size; // logical canvas size

  HandwritingPainter({
    required this.state,
    this.placeholderChar,
    this.size = kCanvasLogicalSize,
  });

  @override
  void paint(Canvas canvas, Size sz) {
    final scale = sz.width / size;

    // ── Background ──
    canvas.drawRect(
      Rect.fromLTWH(0, 0, sz.width, sz.height),
      Paint()..color = kCanvasBg,
    );

    // ── Grid ──
    _drawGrid(canvas, sz);

    // ── Placeholder ──
    if (!state.hasStrokes && placeholderChar != null) {
      _drawPlaceholder(canvas, sz, placeholderChar!);
    }

    // ── Completed strokes ──
    final strokePaint = _buildStrokePaint();
    for (final stroke in state.strokes) {
      _drawStroke(canvas, stroke, strokePaint, scale);
    }

    // ── Active stroke ──
    if (state.activeStroke != null) {
      _drawStroke(canvas, state.activeStroke!, strokePaint, scale);
    }
  }

  Paint _buildStrokePaint() {
    return Paint()
      ..color = kStrokeColor
      ..strokeWidth = kStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..maskFilter =
          const MaskFilter.blur(BlurStyle.normal, 1.5); // subtle glow
  }

  void _drawStroke(
      Canvas canvas, HandStroke stroke, Paint paint, double scale) {
    if (stroke.points.isEmpty) return;
    if (stroke.points.length == 1) {
      // Draw a dot for single-point strokes
      final pt = stroke.points.first;
      canvas.drawCircle(
        Offset(pt.x * scale, pt.y * scale),
        kStrokeWidth / 2,
        paint,
      );
      return;
    }

    final path = Path();
    final first = stroke.points.first;
    path.moveTo(first.x * scale, first.y * scale);

    for (int i = 1; i < stroke.points.length; i++) {
      final p = stroke.points[i];
      path.lineTo(p.x * scale, p.y * scale);
    }
    canvas.drawPath(path, paint);
  }

  void _drawGrid(Canvas canvas, Size sz) {
    final dashed = Paint()
      ..color = kGridColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final solid = Paint()
      ..color = kGridBorder
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Draw dashed helper lines (center cross + diagonals)
    _drawDashedLine(canvas, Offset(sz.width / 2, 0),
        Offset(sz.width / 2, sz.height), dashed);
    _drawDashedLine(canvas, Offset(0, sz.height / 2),
        Offset(sz.width, sz.height / 2), dashed);
    _drawDashedLine(canvas, Offset(0, 0), Offset(sz.width, sz.height), dashed);
    _drawDashedLine(canvas, Offset(sz.width, 0), Offset(0, sz.height), dashed);

    // Outer border
    canvas.drawRect(
      Rect.fromLTWH(1.5, 1.5, sz.width - 3, sz.height - 3),
      solid,
    );
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashLen = 5.0;
    const gapLen = 5.0;
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final ux = dx / len;
    final uy = dy / len;
    double traveled = 0;
    bool drawing = true;
    while (traveled < len) {
      final seg = drawing ? dashLen : gapLen;
      final next = min(traveled + seg, len);
      if (drawing) {
        canvas.drawLine(
          Offset(start.dx + ux * traveled, start.dy + uy * traveled),
          Offset(start.dx + ux * next, start.dy + uy * next),
          paint,
        );
      }
      traveled = next;
      drawing = !drawing;
    }
  }

  void _drawPlaceholder(Canvas canvas, Size sz, String char) {
    final tp = TextPainter(
      text: TextSpan(
        text: char,
        style: const TextStyle(
          color: Color(0x59B4783C), // ~35% opacity warm brown
          fontSize: 200,
          fontWeight: FontWeight.w100,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(
      canvas,
      Offset(
        (sz.width - tp.width) / 2,
        (sz.height - tp.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(HandwritingPainter oldDelegate) {
    // Only repaint if stroke data or placeholder changed
    return oldDelegate.state != state ||
        oldDelegate.placeholderChar != placeholderChar;
  }

  @override
  bool operator ==(Object other) => false; // always allow repaint check
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPER UTILITIES
// ══════════════════════════════════════════════════════════════════════════════

/// Return display-friendly label for a level_code string
String levelLabel(String? levelCode) {
  if (levelCode == null) return '';
  return kLevelLabels[levelCode] ?? levelCode;
}

/// Return a short color accent per level
Color levelColor(String? levelCode) {
  switch (levelCode) {
    case 'Novice 1':
      return const Color(0xFF4ECDC4);
    case 'Novice 2':
      return const Color(0xFF45B7D1);
    case 'Level 1':
      return const Color(0xFF96CEB4);
    case 'Level 2':
      return const Color(0xFFFFEAA7);
    case 'Level 3':
      return const Color(0xFFFF9F43);
    case 'Level 4':
      return const Color(0xFFFF6B6B);
    case 'Level 5':
      return const Color(0xFFBD93F9);
    default:
      return const Color(0xFFFF4A00);
  }
}
