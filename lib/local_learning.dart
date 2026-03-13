// local_learning.dart
// Local learning loop — hoàn toàn offline, không cần ML model
// Gồm 3 phần:
//   1. StrokeFeatureExtractor  — trích xuất feature vector từ StrokeData[]
//   2. SimilarityEngine        — so sánh nét vẽ mới với mẫu cũ đã lưu
//   3. LocalLearningService    — orchestrate save + boost + feedback

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'logic.dart';

// ── 1. Feature Extractor ──────────────────────────────────────────────────────

class StrokeFeatures {
  /// Vector 12 chiều, đủ để phân biệt nét vẽ cùng chữ:
  ///
  ///  [0]  stroke_count        — số nét
  ///  [1]  total_points        — tổng điểm
  ///  [2]  avg_points_per_stroke
  ///  [3]  bbox_width          — normalized 0-1
  ///  [4]  bbox_height         — normalized 0-1
  ///  [5]  aspect_ratio        — width/height
  ///  [6]  coverage            — bbox_area / canvas_area
  ///  [7]  dir_right           — % đoạn đi sang phải
  ///  [8]  dir_down            — % đoạn đi xuống
  ///  [9]  dir_left            — % đoạn đi sang trái
  ///  [10] dir_up              — % đoạn đi lên
  ///  [11] avg_stroke_length   — normalized

  final List<double> values;
  const StrokeFeatures(this.values);

  static const int dimension = 12;

  factory StrokeFeatures.fromStrokes(List<StrokeData> strokes) {
    if (strokes.isEmpty) {
      return StrokeFeatures(List.filled(dimension, 0.0));
    }

    // Bounding box
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    int totalPoints = 0;
    int dirRight = 0, dirDown = 0, dirLeft = 0, dirUp = 0, dirTotal = 0;
    double totalLength = 0;

    for (final s in strokes) {
      for (final p in s.points) {
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
        totalPoints++;
      }

      // Phân tích hướng từng đoạn
      for (var i = 1; i < s.points.length; i++) {
        final dx = s.points[i].x - s.points[i - 1].x;
        final dy = s.points[i].y - s.points[i - 1].y;
        final len = math.sqrt(dx * dx + dy * dy);
        totalLength += len;
        if (len < 0.5) continue;
        dirTotal++;
        final angle = math.atan2(dy, dx); // -π to π
        // Phân thành 4 góc phần tư
        if (angle >= -math.pi / 4 && angle < math.pi / 4)
          dirRight++;
        else if (angle >= math.pi / 4 && angle < 3 * math.pi / 4)
          dirDown++;
        else if (angle >= 3 * math.pi / 4 || angle < -3 * math.pi / 4)
          dirLeft++;
        else
          dirUp++;
      }
    }

    final bboxW = (maxX - minX).clamp(0.0, kLogicalSize) / kLogicalSize;
    final bboxH = (maxY - minY).clamp(0.0, kLogicalSize) / kLogicalSize;
    final aspect = bboxH > 0 ? bboxW / bboxH : 1.0;
    final coverage = bboxW * bboxH;
    final dt = dirTotal > 0 ? dirTotal.toDouble() : 1.0;

    return StrokeFeatures([
      strokes.length / 20.0, // [0] normalized stroke count
      totalPoints / 500.0, // [1] normalized total points
      (totalPoints / strokes.length) / 50.0, // [2] avg points per stroke
      bboxW, // [3] bbox width
      bboxH, // [4] bbox height
      aspect.clamp(0.0, 3.0) / 3.0, // [5] aspect ratio
      coverage, // [6] coverage
      dirRight / dt, // [7] dir right %
      dirDown / dt, // [8] dir down %
      dirLeft / dt, // [9] dir left %
      dirUp / dt, // [10] dir up %
      (totalLength / totalPoints.clamp(1, 99999)) /
          kLogicalSize, // [11] avg segment len
    ]);
  }

  /// Cosine similarity với vector khác (0.0 – 1.0)
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

  /// Trung bình cộng của nhiều vector (dùng để tính "mẫu trung bình")
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

// ── 2. Similarity Engine ──────────────────────────────────────────────────────

class SimilarityResult {
  final double score; // 0.0 – 1.0
  final int samplesCompared;
  final String feedback; // text hiển thị cho user

  const SimilarityResult({
    required this.score,
    required this.samplesCompared,
    required this.feedback,
  });

  bool get isConsistent => score >= 0.80;
  bool get isGood => score >= 0.65;
}

class SimilarityEngine {
  /// So sánh nét vẽ hiện tại với các mẫu đã lưu cho cùng chữ.
  /// Trả về null nếu chưa có đủ mẫu để so sánh (< 2 mẫu).
  static Future<SimilarityResult?> compare({
    required List<StrokeData> current,
    required String vocabulary,
  }) async {
    // Lấy tối đa 10 mẫu gần nhất
    final rows = await DbService.getRecentSamples(vocabulary, limit: 10);
    if (rows.length < 2) return null; // cần ít nhất 2 mẫu để có ý nghĩa

    // Parse features từ DB
    final storedFeatures = <StrokeFeatures>[];
    for (final row in rows) {
      final fJson = row['feature_json'] as String?;
      if (fJson != null && fJson.isNotEmpty) {
        try {
          storedFeatures.add(StrokeFeatures.fromJson(fJson));
        } catch (_) {}
      }
    }
    if (storedFeatures.isEmpty) return null;

    // Feature của nét vẽ hiện tại
    final currentFeature = StrokeFeatures.fromStrokes(current);

    // So với trung bình các mẫu cũ
    final avgFeature = StrokeFeatures.average(storedFeatures);
    final score = currentFeature.cosineSimilarity(avgFeature);

    String feedback;
    if (score >= 0.85) {
      feedback = '一致性優秀 ${(score * 100).round()}%';
    } else if (score >= 0.70) {
      feedback = '寫法穩定 ${(score * 100).round()}%';
    } else if (score >= 0.55) {
      feedback = '略有差異 ${(score * 100).round()}%';
    } else {
      feedback = '筆法不同 ${(score * 100).round()}% — 再試試';
    }

    return SimilarityResult(
      score: score,
      samplesCompared: storedFeatures.length,
      feedback: feedback,
    );
  }
}

// ── 3. Local Learning Service ─────────────────────────────────────────────────

class LocalLearningService {
  /// Gọi sau mỗi lần recognize() thành công khi tmpl đang bật.
  /// Trả về SimilarityResult? để UI hiển thị feedback.
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

    // Lưu sample + feature vào SQLite
    await DbService.saveSample(
      vocabulary: vocabulary,
      strokeJson: strokeJson,
      pngBase64: null, // không cần PNG cho local training
      strokeCount: strokes.length,
      strokeWidth: strokeWidth,
      ocrRaw: ocrRaw,
      ocrMatched: ocrMatched,
      featureJson: features.toJson(),
    );

    // Tăng practice count
    await DbService.incrementPracticeCount(vocabulary);

    // So sánh với mẫu cũ
    return SimilarityEngine.compare(
      current: strokes,
      vocabulary: vocabulary,
    );
  }

  /// Boost score: ưu tiên chữ đã luyện nhiều trong kết quả OCR match.
  /// Gọi trong _sortMatchesByCandidateOrder để re-rank.
  static Future<Map<String, double>> getBoostScores(
    List<String> vocabularies,
  ) async {
    final scores = <String, double>{};
    for (final v in vocabularies) {
      final count = await DbService.getPracticeCount(v);
      // Mỗi 5 lần luyện → boost thêm 0.1 (tối đa +0.5)
      scores[v] = math.min(count / 5.0 * 0.1, 0.5);
    }
    return scores;
  }
}

// ── Stroke JSON Serializer ────────────────────────────────────────────────────

class StrokeSerializer {
  static String toJson(List<StrokeData> strokes) {
    final data = strokes
        .map((s) => {
              'points': s.points
                  .map((p) => {
                        'x': p.x,
                        'y': p.y,
                        't': p.t,
                      })
                  .toList(),
            })
        .toList();
    return jsonEncode(data);
  }

  static List<StrokeData> fromJson(String json) {
    final List<dynamic> data = jsonDecode(json);
    return data.map((s) {
      final pts = (s['points'] as List)
          .map(
            (p) => StrokePoint(
              (p['x'] as num).toDouble(),
              (p['y'] as num).toDouble(),
              p['t'] as int,
            ),
          )
          .toList();
      return StrokeData(pts);
    }).toList();
  }
}
