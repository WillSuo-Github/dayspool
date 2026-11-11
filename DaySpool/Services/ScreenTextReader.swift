import CoreGraphics
import ScreenCaptureKit
import Vision

enum ScreenTextReader {
    struct Snapshot {
        let fingerprint: Data?
        let text: String
    }

    static func read(pid: pid_t, target: FocusedWindow, previous: Data?) async throws -> Snapshot? {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let matches = content.windows.filter { window in
            window.owningApplication?.processID == pid && window.isOnScreen &&
                (window.title == nil || window.title == target.title) && sameFrame(window.frame, target.frame)
        }
        guard matches.count == 1, let window = matches.first else { return nil }
        try Task.checkCancellation()
        let config = SCStreamConfiguration()
        let scale = min(2, 2400 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config
        )
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { () throws -> Snapshot? in
            try Task.checkCancellation()
            let fingerprint = Self.fingerprint(image)
            if let fingerprint, fingerprint == previous { return nil }
            return Snapshot(fingerprint: fingerprint, text: try recognizeText(in: image))
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let desired = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
        if !desired.isEmpty { request.recognitionLanguages = desired }
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").prefix(8_000))
    }

    private static func fingerprint(_ image: CGImage) -> Data? {
        let side = 32
        var pixels = Data(count: side * side)
        let succeeded = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return succeeded ? pixels : nil
    }

    private static func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 3 && abs(lhs.minY - rhs.minY) <= 3 &&
            abs(lhs.width - rhs.width) <= 3 && abs(lhs.height - rhs.height) <= 3
    }
}
