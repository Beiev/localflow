import Foundation
import CoreVideo
import CoreGraphics
import Vision

/// Reading one captured frame: a coarse signature to tell whether anything changed, the text on
/// it, and what window it belonged to. Kept apart from the capture loop so the expensive part —
/// recognition — can be moved off the callback, and so the cheap part can be unit-tested.
public enum ScreenReader {
    /// Side of the square thumbnail the change test compares. 16×16 greyscale is 256 bytes and
    /// enough to tell a new slide from a moving cursor.
    public static let signatureSide = 16

    /// A greyscale thumbnail of a BGRA frame, sampled on a grid. Nearest-neighbour on purpose:
    /// this runs on every frame and only has to be stable, not pretty.
    public static func signature(from buffer: CVPixelBuffer, side: Int = signatureSide) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, side > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        // Only the 32-bit interleaved formats ScreenCaptureKit hands us are sampled; anything
        // else returns nothing, and an empty signature reads as "changed".
        guard format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB else { return [] }
        let blue = format == kCVPixelFormatType_32BGRA ? 0 : 3
        let green = format == kCVPixelFormatType_32BGRA ? 1 : 2
        let red = format == kCVPixelFormatType_32BGRA ? 2 : 1
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: side * side)
        for row in 0..<side {
            let y = min(height - 1, row * height / side)
            for column in 0..<side {
                let x = min(width - 1, column * width / side)
                let offset = y * stride + x * 4
                let luma = (Int(pixels[offset + red]) * 299 + Int(pixels[offset + green]) * 587 + Int(pixels[offset + blue]) * 114) / 1000
                result[row * side + column] = UInt8(clamping: luma)
            }
        }
        return result
    }

    /// Languages to recognize: what we want, narrowed to what this Mac actually supports. Asking
    /// for an unsupported language makes the request fail outright rather than degrade, and
    /// Russian only became available in recent releases.
    public static let wantedLanguages = ["ru-RU", "en-US"]
    public static func languages(wanted: [String] = wantedLanguages) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let available = wanted.filter { language in
            supported.contains(language) || supported.contains { $0.hasPrefix(String(language.prefix(2))) }
        }
        return available.isEmpty ? [] : available
    }

    /// Lines of text on a frame, top to bottom as laid out. Returns nothing rather than throwing
    /// when recognition is unavailable: a meeting must never fail because the screen was unreadable.
    public static func read(_ buffer: CVPixelBuffer, languages: [String]) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let found = request.results as? [VNRecognizedTextObservation] else { return [] }
        // Reading order, not confidence order: a document read out of order is unusable.
        return found
            .sorted { first, second in
                let top = 1 - first.boundingBox.maxY, otherTop = 1 - second.boundingBox.maxY
                return abs(top - otherTop) > 0.01 ? top < otherTop : first.boundingBox.minX < second.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    /// The frontmost on-screen window's owner and title, for naming what was shown. Titles only —
    /// never contents — and the app's own windows are skipped so its archive cannot label a moment.
    public static func frontmostWindow(excluding ownProcess: pid_t = getpid()) -> (app: String?, window: String?) {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return (nil, nil) }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownProcess else { continue }
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let app = window[kCGWindowOwnerName as String] as? String
            let title = window[kCGWindowName as String] as? String
            if app != nil || title != nil { return (app, title?.isEmpty == true ? nil : title) }
        }
        return (nil, nil)
    }
}
