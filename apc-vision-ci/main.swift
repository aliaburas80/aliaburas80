import Foundation
import Vision
import CoreGraphics

func makeImage(width: Int = 1800, height: Int = 1200) -> CGImage {
    let bytesPerRow = width * 4
    var pixels = Data(count: bytesPerRow * height)
    let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.12, green: 0.28, blue: 0.47, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.81, green: 0.65, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 350, y: 220, width: 900, height: 650))
        return context.makeImage()
    }
    guard let image else { fatalError("could not create synthetic CGImage") }
    return image
}

let image = makeImage()
var totalLabels = 0
var saliencyHits = 0
var totalFaces = 0

for pass in 1...100 {
    autoreleasepool {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            totalLabels += request.results?.count ?? 0
        } catch {
            fputs("classification recoverable error: \(error.localizedDescription)\n", stderr)
        }
    }

    autoreleasepool {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            if request.results?.first != nil { saliencyHits += 1 }
        } catch {
            fputs("saliency recoverable error: \(error.localizedDescription)\n", stderr)
        }
    }

    autoreleasepool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            totalFaces += request.results?.count ?? 0
        } catch {
            fputs("faces recoverable error: \(error.localizedDescription)\n", stderr)
        }
    }

    if pass % 10 == 0 {
        print("Vision safety-profile pass \(pass)/100")
    }
}

print("labels=\(totalLabels) saliencyHits=\(saliencyHits) faces=\(totalFaces)")
print("APC_VISION_STRESS_PASS")
