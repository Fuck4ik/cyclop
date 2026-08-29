import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Frames out of the recording, and whether two of them show the same screen.
///
/// No ffmpeg: the core spec rejected bundling it (~100 MB) and nothing here
/// needs it. `AVAssetImageGenerator` decodes a frame at a time, and telling
/// «same screen» from «different screen» takes a 64-pixel thumbnail, not a
/// video filter.
enum MeetingFrames {
    /// Mean per-pixel difference above which two frames are called different.
    /// A cursor moving over a static page stays well below it; a switched tab
    /// clears it easily.
    static let changeThreshold: Double = 0.04

    /// Wide enough that console text and code survive the JPEG, small enough
    /// that a dozen frames fit in one request.
    private static let maxWidth: CGFloat = 1600
    private static let compression: CGFloat = 0.7

    /// Frames keyed by the time actually requested, so a caller can match them
    /// back to candidates without relying on order.
    static func jpeg(from video: URL, at times: [TimeInterval]) async -> [TimeInterval: Data] {
        guard !times.isEmpty else { return [:] }

        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: 0)
        // A demo is mostly static, so a frame half a second off is the same
        // screen. Zero tolerance would force decoding from the previous
        // keyframe and cost seconds per frame for nothing.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [TimeInterval: Data] = [:]
        for time in times {
            do {
                let image = try await generator.image(
                    at: CMTime(seconds: time, preferredTimescale: 600)).image
                guard let data = encode(image) else { continue }
                frames[time] = data
            } catch {
                // One unreadable frame is not worth the meeting. The plan
                // simply loses that moment and says so in the header.
                NSLog("Cyclop: meeting frame at %.0f failed (%@)", time, error.localizedDescription)
            }
        }
        return frames
    }

    /// Whether the second frame shows something other than the first.
    ///
    /// Compared as 64×64 greyscale: the question is «did the screen change»,
    /// not «how much», and at that size a moved window matters while a blinking
    /// caret does not.
    static func differs(_ frame: Data, from previous: Data) -> Bool {
        guard let a = thumbnail(frame), let b = thumbnail(previous) else { return true }
        let total = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) / 255 }
        return total / Double(a.count) > changeThreshold
    }

    private static func encode(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg, properties: [.compressionFactor: compression])
    }

    private static func thumbnail(_ data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }
}
