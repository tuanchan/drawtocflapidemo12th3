import UIKit
import Flutter
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "tocfl_writer/vision_ocr"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )

      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(FlutterError(code: "SELF_DEALLOCATED", message: "AppDelegate released", details: nil))
          return
        }

        switch call.method {
        case "recognizeCanvasText":
          self.handleRecognizeCanvasText(call: call, result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // ── Main handler ────────────────────────────────────────────────────────────

  private func handleRecognizeCanvasText(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "BAD_ARGS", message: "Arguments missing", details: nil))
      return
    }

    guard let imageData = (args["imageBytes"] as? FlutterStandardTypedData)?.data else {
      result(FlutterError(code: "BAD_IMAGE", message: "imageBytes missing", details: nil))
      return
    }

    let maxCandidates = args["maxCandidates"] as? Int ?? 10
    let recognitionLevelRaw = (args["recognitionLevel"] as? String ?? "accurate").lowercased()
    let languages = args["languages"] as? [String] ?? ["zh-Hant", "zh-Hans", "en-US"]

    guard let uiImage = UIImage(data: imageData) else {
      result(FlutterError(code: "BAD_IMAGE_DATA", message: "Cannot decode PNG", details: nil))
      return
    }

    // ── Tiền xử lý ảnh trước khi đưa vào Vision ──────────────────────────────
    let processedCGImage: CGImage
    do {
      processedCGImage = try preprocessForOCR(uiImage)
    } catch {
      result(FlutterError(code: "PREPROCESS_FAILED", message: error.localizedDescription, details: nil))
      return
    }

    // ── Vision OCR ────────────────────────────────────────────────────────────
    let request = VNRecognizeTextRequest { request, error in
      if let error = error {
        result(FlutterError(
          code: "VISION_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }

      guard let observations = request.results as? [VNRecognizedTextObservation] else {
        result([])
        return
      }

      var collected: [String] = []
      var seen = Set<String>()

      for observation in observations {
        let candidates = observation.topCandidates(maxCandidates)
        for candidate in candidates {
          let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { continue }
          if !seen.contains(text) {
            seen.insert(text)
            collected.append(text)
          }
        }
      }

      result(collected)
    }

    request.recognitionLevel = (recognitionLevelRaw == "fast") ? .fast : .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.0

    let handler = VNImageRequestHandler(cgImage: processedCGImage, options: [:])

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try handler.perform([request])
      } catch {
        result(FlutterError(
          code: "VISION_PERFORM_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  // ── Image preprocessing pipeline ────────────────────────────────────────────
  //
  //  Bước 1: Grayscale       — loại bỏ màu sắc, giữ lại độ sáng
  //  Bước 2: Otsu threshold  — nhị phân hoá ảnh (chữ đen, nền trắng thuần)
  //  Bước 3: Sharpen         — làm sắc cạnh nét vẽ
  //  Kết quả: CGImage sạch, tương phản cao → Vision nhận dễ hơn nhiều
  //
  private func preprocessForOCR(_ image: UIImage) throws -> CGImage {
    guard let cgInput = image.cgImage else {
      throw NSError(domain: "preprocess", code: 1, userInfo: [NSLocalizedDescriptionKey: "No CGImage"])
    }

    let ci = CIImage(cgImage: cgInput)
    let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    // ── Bước 1: Grayscale ─────────────────────────────────────────────────────
    let grayFilter = CIFilter.colorControls()
    grayFilter.inputImage = ci
    grayFilter.saturation = 0.0   // loại màu
    grayFilter.contrast = 1.1     // tăng nhẹ tương phản
    grayFilter.brightness = 0.0

    guard let grayImage = grayFilter.outputImage else {
      throw NSError(domain: "preprocess", code: 2, userInfo: [NSLocalizedDescriptionKey: "Grayscale failed"])
    }

    // ── Bước 2: Otsu-style threshold ──────────────────────────────────────────
    // CoreImage không có Otsu built-in, dùng colorThreshold với giá trị 0.45
    // (phù hợp cho nét trắng/vàng trên nền đen hoặc nét đen trên nền trắng)
    // Nếu ảnh từ Dart đã là nền trắng + nét đen thì bước này làm sạch thêm
    let threshFilter = CIFilter.colorThreshold()
    threshFilter.inputImage = grayImage
    threshFilter.threshold = 0.45

    guard let threshImage = threshFilter.outputImage else {
      throw NSError(domain: "preprocess", code: 3, userInfo: [NSLocalizedDescriptionKey: "Threshold failed"])
    }

    // ── Bước 3: Sharpen ───────────────────────────────────────────────────────
    let sharpenFilter = CIFilter.unsharpMask()
    sharpenFilter.inputImage = threshImage
    sharpenFilter.radius = 2.5
    sharpenFilter.intensity = 0.8

    guard let sharpenedImage = sharpenFilter.outputImage else {
      throw NSError(domain: "preprocess", code: 4, userInfo: [NSLocalizedDescriptionKey: "Sharpen failed"])
    }

    // ── Xuất CGImage ──────────────────────────────────────────────────────────
    let extent = sharpenedImage.extent
    guard let cgOutput = ctx.createCGImage(sharpenedImage, from: extent) else {
      throw NSError(domain: "preprocess", code: 5, userInfo: [NSLocalizedDescriptionKey: "CGImage output failed"])
    }

    return cgOutput
  }
}