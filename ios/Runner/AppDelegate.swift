import UIKit
import Flutter
import Vision

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "tocfl/vision",
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { call, result in
      if call.method == "recognize" {
        guard let args = call.arguments as? [String: Any],
              let bytes = args["image"] as? FlutterStandardTypedData
        else {
          result(FlutterError(code: "BAD_ARGS", message: "Missing image", details: nil))
          return
        }
        self.recognize(imageBytes: bytes.data, completion: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func recognize(imageBytes: Data, completion: @escaping FlutterResult) {
    guard let image = UIImage(data: imageBytes),
          let cgImage = image.cgImage
    else {
      completion([String]())
      return
    }

    let request = VNRecognizeTextRequest { req, err in
      if let err = err {
        completion(FlutterError(code: "VISION_ERR", message: err.localizedDescription, details: nil))
        return
      }
      let strings = (req.results as? [VNRecognizedTextObservation] ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
      completion(strings)
    }

    request.recognitionLanguages = ["zh-Hant"]
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try handler.perform([request])
      } catch {
        completion(FlutterError(code: "HANDLER_ERR", message: error.localizedDescription, details: nil))
      }
    }
  }
}