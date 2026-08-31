import Foundation
import ImageIO
import CoreGraphics
import Darwin

private let magic = Data([0x41, 0x50, 0x43, 0x52])
private let headerBytes = 16
private let maxPixel = 1800

private enum HarnessError: LocalizedError {
    case invalidArgs
    case sourceOpen
    case thumbnail
    case render
    case invalidPayload
    case childTimeout
    case childSignal(Int32)
    case childExit(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidArgs: return "invalid arguments"
        case .sourceOpen: return "source open failed"
        case .thumbnail: return "thumbnail decode failed"
        case .render: return "render failed"
        case .invalidPayload: return "invalid payload"
        case .childTimeout: return "child timeout"
        case .childSignal(let signal): return "child signal \(signal)"
        case .childExit(let code): return "child exit \(code)"
        }
    }
}

private func arg(_ key: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.indices.contains(i + 1) else { return nil }
    return CommandLine.arguments[i + 1]
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { raw in
        var value: UInt32 = 0
        memcpy(&value, raw.baseAddress!.advanced(by: offset), 4)
        return UInt32(littleEndian: value)
    }
}

private func decodeSourceToRaw(input: URL, output: URL, maxPixel: Int) throws {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(input as CFURL, sourceOptions), CGImageSourceGetCount(source) > 0 else {
        throw HarnessError.sourceOpen
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw HarnessError.thumbnail
    }
    let width = thumb.width
    let height = thumb.height
    guard width > 0, height > 0, width <= maxPixel, height <= maxPixel else { throw HarnessError.invalidPayload }
    let bytesPerRow = width * 4
    let byteCount = bytesPerRow * height
    guard byteCount > 0, byteCount <= 2048 * 2048 * 4 else { throw HarnessError.invalidPayload }

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
    guard rendered else { throw HarnessError.render }

    var payload = Data()
    payload.reserveCapacity(headerBytes + byteCount)
    payload.append(magic)
    appendUInt32(UInt32(width), to: &payload)
    appendUInt32(UInt32(height), to: &payload)
    appendUInt32(UInt32(bytesPerRow), to: &payload)
    payload.append(pixels)
    try payload.write(to: output, options: .atomic)
}

private func validatePayload(_ url: URL) throws -> (Int, Int) {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count >= headerBytes, data.prefix(4) == magic else { throw HarnessError.invalidPayload }
    let width = Int(readUInt32(data, 4))
    let height = Int(readUInt32(data, 8))
    let bytesPerRow = Int(readUInt32(data, 12))
    guard width > 0, height > 0, width <= maxPixel, height <= maxPixel, bytesPerRow == width * 4 else { throw HarnessError.invalidPayload }
    guard data.count == headerBytes + bytesPerRow * height else { throw HarnessError.invalidPayload }
    return (width, height)
}

private func runChild(arguments: [String], timeout: Double = 30) throws -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = arguments
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    child.terminationHandler = { _ in done.signal() }
    try child.run()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        if child.isRunning { child.terminate() }
        _ = done.wait(timeout: .now() + 2)
        throw HarnessError.childTimeout
    }
    return child
}

private func makeJPEG(_ url: URL, width: Int = 6000, height: Int = 4000) throws {
    let bytesPerRow = width * 4
    var pixels = Data(count: bytesPerRow * height)
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(CGColor(red: 0.12, green: 0.35, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.80, green: 0.62, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: width / 5, y: height / 5, width: width * 3 / 5, height: height * 3 / 5))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
    guard ok else { throw HarnessError.render }
}

if CommandLine.arguments.contains("--trap-helper") {
    raise(SIGTRAP)
    exit(99)
}

if CommandLine.arguments.contains("--decode-helper") {
    do {
        guard let input = arg("--input"), let output = arg("--output") else { throw HarnessError.invalidArgs }
        try decodeSourceToRaw(input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output), maxPixel: maxPixel)
        exit(0)
    } catch {
        fputs("decode-helper: \(error.localizedDescription)\n", stderr)
        exit(65)
    }
}

if CommandLine.arguments.contains("--runtime-self-test") {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("apc-macos-ci-\(UUID().uuidString)", isDirectory: true)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let valid = root.appendingPathComponent("large.jpg")
        try makeJPEG(valid)

        for pass in 1...10 {
            let out = root.appendingPathComponent("out-\(pass).apcrgba")
            let child = try runChild(arguments: ["--decode-helper", "--input", valid.path, "--output", out.path])
            guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                if child.terminationReason == .uncaughtSignal { throw HarnessError.childSignal(child.terminationStatus) }
                throw HarnessError.childExit(child.terminationStatus)
            }
            let dims = try validatePayload(out)
            guard max(dims.0, dims.1) <= maxPixel else { throw HarnessError.invalidPayload }
            try fm.removeItem(at: out)
            print("large-image isolated decode pass \(pass): \(dims.0)x\(dims.1)")
        }

        let malformed = root.appendingPathComponent("bad.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02, 0x03]).write(to: malformed)
        let badOut = root.appendingPathComponent("bad.apcrgba")
        let bad = try runChild(arguments: ["--decode-helper", "--input", malformed.path, "--output", badOut.path])
        guard !(bad.terminationReason == .exit && bad.terminationStatus == 0) else { throw HarnessError.invalidPayload }
        print("malformed input contained: child status \(bad.terminationStatus)")

        let trapped = try runChild(arguments: ["--trap-helper"])
        guard trapped.terminationReason == .uncaughtSignal, trapped.terminationStatus == SIGTRAP else {
            throw HarnessError.invalidPayload
        }
        print("forced SIGTRAP contained: parent remained alive")
        print("APC_MACOS_DECODER_CI_PASS")
        exit(0)
    } catch {
        fputs("APC_MACOS_DECODER_CI_FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

fputs("usage: --runtime-self-test | --decode-helper | --trap-helper\n", stderr)
exit(64)
