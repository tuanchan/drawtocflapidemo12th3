import UIKit
import Flutter
import Vision

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

    guard let uiImage = UIImage(data: imageData),
          let cgImage = uiImage.cgImage else {
      result(FlutterError(code: "BAD_IMAGE_DATA", message: "Cannot decode PNG", details: nil))
      return
    }

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

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

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
}