import Foundation
import CoreGraphics
import ImageIO
import Darwin

let width = 10_667
let height = 8_000
let bytesPerRow = width * 4
let byteCount = bytesPerRow * height
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/apc-85mp.jpg")

var pixels = Data(count: byteCount)
pixels.withUnsafeMutableBytes { raw in
    guard let base = raw.baseAddress else { return }
    arc4random_buf(base, byteCount)
    // The alpha byte is ignored by noneSkipLast; random RGB gives a deliberately
    // difficult-to-compress source and stresses the decoder more than a flat test image.
}

guard let context = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
    guard let base = raw.baseAddress else { return nil }
    return CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
}), let image = context.makeImage() else {
    fputs("could not create 85MP source image\n", stderr)
    exit(1)
}

guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else {
    fputs("could not create JPEG destination\n", stderr)
    exit(2)
}
CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    fputs("could not finalize JPEG\n", stderr)
    exit(3)
}

let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
print("APC_85MP_JPEG_READY width=\(width) height=\(height) bytes=\(bytes)")
