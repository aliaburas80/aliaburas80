import Foundation
import ImageIO
import CoreGraphics
import Darwin

/// Crash-contained image decoding.
///
/// Source files are never decoded inside the long-lived batch worker. The worker
/// starts a short-lived copy of itself in `--decode-helper` mode. All risky
/// ImageIO decoding happens there. If ImageIO or a codec traps/aborts on a
/// particular file, only the helper dies; the batch worker receives the signal,
/// records that photo as failed, and continues safely.
///
/// The helper returns a small custom RGBA payload (APCR) capped at `maxPixel`,
/// so the parent never has to re-decode the original or a compressed derivative.
struct ImageDownsampler {
    enum DecoderError: LocalizedError {
        case helperMissing
        case helperTimeout
        case helperSignal(Int32, String)
        case helperFailed(Int32, String)
        case outputMissing
        case invalidPayload(String)
        case sourceOpenFailed(String)
        case thumbnailFailed(String)
        case renderFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "The isolated image decoder executable could not be located."
            case .helperTimeout:
                return "The isolated image decoder exceeded the 30-second safety timeout and was stopped."
            case let .helperSignal(code, name):
                return "The isolated image decoder stopped on signal \(code) (\(name)). The batch worker stayed safe."
            case let .helperFailed(code, detail):
                return detail.isEmpty ? "The isolated image decoder exited with code \(code)." : "The isolated image decoder exited with code \(code): \(detail)"
            case .outputMissing:
                return "The isolated image decoder did not produce a bounded analysis image."
            case let .invalidPayload(detail):
                return "The isolated decoder produced an invalid analysis payload: \(detail)"
            case let .sourceOpenFailed(name):
                return "Could not open image source: \(name)"
            case let .thumbnailFailed(name):
                return "Could not decode a bounded thumbnail for: \(name)"
            case .renderFailed:
                return "Could not render the bounded analysis pixels."
            case let .writeFailed(detail):
                return "Could not write the isolated analysis payload: \(detail)"
            }
        }
    }

    private static let magic = Data([0x41, 0x50, 0x43, 0x52]) // "APCR"
    private static let headerBytes = 16
    private static let timeoutSeconds: Double = 30

    /// Parent-side safe entry point used by the batch worker.
    static func load(_ url: URL, maxPixel: Int = 1800) throws -> CGImage {
        let boundedMax = min(2048, max(256, maxPixel))
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("AliPhotoCurator-Decode-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let output = scratch.appendingPathComponent("analysis.apcrgba")
        defer { try? fm.removeItem(at: scratch) }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard fm.isExecutableFile(atPath: executable.path) else { throw DecoderError.helperMissing }

        let helper = Process()
        let stderr = Pipe()
        helper.executableURL = executable
        helper.arguments = [
            "--decode-helper",
            "--input", url.path,
            "--output", output.path,
            "--max", String(boundedMax),
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["APC_DECODE_HELPER"] = "1"
        helper.environment = environment

        let finished = DispatchSemaphore(value: 0)
        helper.terminationHandler = { _ in finished.signal() }
        try helper.run()

        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if helper.isRunning { helper.terminate() }
            _ = finished.wait(timeout: .now() + 2)
            throw DecoderError.helperTimeout
        }

        let diagnosticData = stderr.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(data: diagnosticData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if helper.terminationReason == .uncaughtSignal {
            throw DecoderError.helperSignal(helper.terminationStatus, signalName(helper.terminationStatus))
        }
        guard helper.terminationStatus == 0 else {
            throw DecoderError.helperFailed(helper.terminationStatus, diagnostic)
        }
        guard fm.fileExists(atPath: output.path) else { throw DecoderError.outputMissing }

        return try readRawPayload(output, maxPixel: boundedMax)
    }

    /// Child-process mode. Returns nil when normal batch-worker arguments should
    /// continue through the regular startup path.
    static func runDecodeHelperIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.contains("--decode-helper") else { return nil }
        do {
            guard let input = value(after: "--input", in: arguments),
                  let output = value(after: "--output", in: arguments),
                  let maxText = value(after: "--max", in: arguments),
                  let maxPixel = Int(maxText) else {
                FileHandle.standardError.write(Data("decode helper: invalid arguments\n".utf8))
                return 64
            }
            try decodeSourceToRaw(URL(fileURLWithPath: input), output: URL(fileURLWithPath: output), maxPixel: min(2048, max(256, maxPixel)))
            return 0
        } catch {
            FileHandle.standardError.write(Data("decode helper: \(error.localizedDescription)\n".utf8))
            return 65
        }
    }

    /// Installer/CI self-test. It verifies both the helper-mode round trip and
    /// malformed-input containment without touching the user's photo library.
    static func runSelfTestIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.contains("--runtime-self-test") else { return nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AliPhotoCurator-SelfTest-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }

            let valid = root.appendingPathComponent("large-test.jpg")
            try makeSyntheticJPEG(valid, width: 6000, height: 4000)
            for pass in 1...10 {
                let image = try load(valid, maxPixel: 1800)
                guard image.width > 0, image.height > 0, max(image.width, image.height) <= 1800 else {
                    throw DecoderError.invalidPayload("self-test pass \(pass) exceeded the bounded analysis size")
                }
            }

            let malformed = root.appendingPathComponent("malformed.jpg")
            try Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02, 0x03]).write(to: malformed, options: .atomic)
            do {
                _ = try load(malformed, maxPixel: 1800)
                FileHandle.standardError.write(Data("runtime self-test: malformed input unexpectedly decoded\n".utf8))
                return 71
            } catch {
                // Expected: malformed input must fail without terminating this parent process.
            }

            let trapped = Process()
            trapped.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            trapped.arguments = ["--decode-trap-helper"]
            trapped.standardOutput = FileHandle.nullDevice
            trapped.standardError = FileHandle.nullDevice
            let trappedFinished = DispatchSemaphore(value: 0)
            trapped.terminationHandler = { _ in trappedFinished.signal() }
            try trapped.run()
            if trappedFinished.wait(timeout: .now() + 5) == .timedOut {
                if trapped.isRunning { trapped.terminate() }
                return 72
            }
            guard trapped.terminationReason == .uncaughtSignal, trapped.terminationStatus == SIGTRAP else {
                FileHandle.standardError.write(Data("runtime self-test: forced SIGTRAP was not contained as expected\n".utf8))
                return 73
            }

            FileHandle.standardOutput.write(Data("RUNTIME SELF-TEST PASSED: 10 isolated large-image decodes, malformed-input containment, and SIGTRAP containment.\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("runtime self-test failed: \(error.localizedDescription)\n".utf8))
            return 70
        }
    }

    static func runTrapHelperIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.contains("--decode-trap-helper") else { return nil }
        raise(SIGTRAP)
        return 74
    }

    // MARK: - Isolated helper implementation

    private static func decodeSourceToRaw(_ url: URL, output: URL, maxPixel: Int) throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw DecoderError.sourceOpenFailed(url.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw DecoderError.sourceOpenFailed(url.lastPathComponent)
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw DecoderError.thumbnailFailed(url.lastPathComponent)
        }

        let width = thumb.width
        let height = thumb.height
        guard width > 0, height > 0, width <= maxPixel, height <= maxPixel else {
            throw DecoderError.invalidPayload("decoded dimensions \(width)x\(height) exceed the safety bound")
        }
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        guard byteCount > 0, byteCount <= 2048 * 2048 * 4 else {
            throw DecoderError.invalidPayload("decoded pixel buffer is outside the safety limit")
        }

        var pixels = Data(count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw DecoderError.renderFailed }

        var payload = Data()
        payload.reserveCapacity(headerBytes + byteCount)
        payload.append(magic)
        appendUInt32(UInt32(width), to: &payload)
        appendUInt32(UInt32(height), to: &payload)
        appendUInt32(UInt32(bytesPerRow), to: &payload)
        payload.append(pixels)
        do {
            try payload.write(to: output, options: .atomic)
        } catch {
            throw DecoderError.writeFailed(error.localizedDescription)
        }
    }

    private static func readRawPayload(_ url: URL, maxPixel: Int) throws -> CGImage {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= headerBytes, data.prefix(4) == magic else {
            throw DecoderError.invalidPayload("missing APCR header")
        }
        let width = Int(readUInt32(data, offset: 4))
        let height = Int(readUInt32(data, offset: 8))
        let bytesPerRow = Int(readUInt32(data, offset: 12))
        guard width > 0, height > 0, width <= maxPixel, height <= maxPixel else {
            throw DecoderError.invalidPayload("invalid dimensions \(width)x\(height)")
        }
        guard bytesPerRow == width * 4 else {
            throw DecoderError.invalidPayload("invalid row stride")
        }
        let expected = headerBytes + bytesPerRow * height
        guard expected == data.count, expected <= headerBytes + 2048 * 2048 * 4 else {
            throw DecoderError.invalidPayload("payload length mismatch")
        }

        let pixelData = data.subdata(in: headerBytes..<data.count) as CFData
        guard let provider = CGDataProvider(data: pixelData) else {
            throw DecoderError.invalidPayload("could not create pixel provider")
        }
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw DecoderError.invalidPayload("could not create bounded CGImage")
        }
        return image
    }

    private static func makeSyntheticJPEG(_ url: URL, width: Int, height: Int) throws {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 0.18, green: 0.42, blue: 0.25, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.85, green: 0.72, blue: 0.22, alpha: 1.0))
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
            let props = [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
            CGImageDestinationAddImage(destination, image, props)
            return CGImageDestinationFinalize(destination)
        }
        if !ok { throw DecoderError.writeFailed("could not create synthetic JPEG") }
    }

    private static func value(after key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            memcpy(&value, raw.baseAddress!.advanced(by: offset), 4)
            return UInt32(littleEndian: value)
        }
    }

    private static func signalName(_ code: Int32) -> String {
        switch code {
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGKILL: return "SIGKILL"
        default: return "signal \(code)"
        }
    }
}
