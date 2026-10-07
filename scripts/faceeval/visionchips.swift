// Replicates FaceMatchingService.alignedFaceChip on macOS: Vision landmarks → 2-pt eye alignment → 112×112 chip.
// usage: visionchips <outdir> <image>...   prints one JSON line per face.
import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func loadCG(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func chip(cgImage: CGImage, face: VNFaceObservation) -> (CGImage, CGPoint, CGPoint)? {
    guard let landmarks = face.landmarks else { return nil }
    let imageW = CGFloat(cgImage.width), imageH = CGFloat(cgImage.height), box = face.boundingBox
    func toPixel(_ p: CGPoint) -> CGPoint {
        let fullX = box.origin.x + p.x * box.width, fullY = box.origin.y + p.y * box.height
        return CGPoint(x: fullX * imageW, y: (1.0 - fullY) * imageH)
    }
    func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let region, !region.normalizedPoints.isEmpty else { return nil }
        let pts = region.normalizedPoints, n = CGFloat(pts.count)
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return toPixel(CGPoint(x: sum.x / n, y: sum.y / n))
    }
    guard let rightEyePx = centroid(landmarks.rightEye), let leftEyePx = centroid(landmarks.leftEye) else { return nil }
    let (eyeA, eyeB) = rightEyePx.x < leftEyePx.x ? (rightEyePx, leftEyePx) : (leftEyePx, rightEyePx)
    let dx = eyeB.x - eyeA.x, dy = eyeB.y - eyeA.y, eyeDist = hypot(dx, dy)
    guard eyeDist > 4 else { return nil }
    let angle = atan2(dy, dx), scale = 35.24 / eyeDist
    let midX = (eyeA.x + eyeB.x) / 2, midY = (eyeA.y + eyeB.y) / 2
    let transform = CGAffineTransform.identity
        .translatedBy(x: 55.91, y: 51.60).scaledBy(x: scale, y: scale).rotated(by: -angle).translatedBy(x: -midX, y: -midY)
    guard let ctx = CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.interpolationQuality = .default
    // UIKit draws in a y-down space; emulate it, then draw the image upright inside that space.
    ctx.translateBy(x: 0, y: 112); ctx.scaleBy(x: 1, y: -1)
    ctx.concatenate(transform)
    ctx.translateBy(x: 0, y: imageH); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageW, height: imageH))
    guard let out = ctx.makeImage() else { return nil }
    return (out, eyeA, eyeB)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: visionchips <outdir> <image>...\n", stderr); exit(1) }
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for path in args[2...] {
    let url = URL(fileURLWithPath: path)
    guard let cg = loadCG(url) else { continue }
    let req = VNDetectFaceLandmarksRequest()
    let qreq = VNDetectFaceCaptureQualityRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([req, qreq]) } catch { fputs("\(path): \(error)\n", stderr); continue }
    let quality = (qreq.results ?? []).map { ($0.boundingBox, $0.faceCaptureQuality ?? -1) }
    for (i, face) in (req.results ?? []).enumerated() {
        let W = CGFloat(cg.width), H = CGFloat(cg.height), b = face.boundingBox
        var q: Float = -1
        for (qb, qv) in quality where abs(qb.midX - b.midX) < 0.02 && abs(qb.midY - b.midY) < 0.02 { q = qv }
        let stem = url.deletingPathExtension().lastPathComponent + "_v\(i)"
        var chipOK = false
        if let (img, eA, eB) = chip(cgImage: cg, face: face) {
            let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(stem + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, nil); chipOK = CGImageDestinationFinalize(dest)
            _ = (eA, eB)
        }
        var pts: [String: Any] = [:]
        if let lm = face.landmarks {
            let W = CGFloat(cg.width), H = CGFloat(cg.height), bx = face.boundingBox
            func px(_ p: CGPoint) -> [Double] { [Double((bx.origin.x + p.x * bx.width) * W), Double((1 - (bx.origin.y + p.y * bx.height)) * H)] }
            func region(_ r: VNFaceLandmarkRegion2D?) -> [[Double]] { (r?.normalizedPoints ?? []).map(px) }
            func cen(_ r: VNFaceLandmarkRegion2D?) -> [Double]? {
                let pts = r?.normalizedPoints ?? []; guard !pts.isEmpty else { return nil }
                let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                return px(CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count)))
            }
            pts["leftEye"] = cen(lm.leftEye) ?? []; pts["rightEye"] = cen(lm.rightEye) ?? []
            pts["leftPupil"] = region(lm.leftPupil); pts["rightPupil"] = region(lm.rightPupil)
            pts["noseCrest"] = region(lm.noseCrest); pts["nose"] = region(lm.nose)
            pts["outerLips"] = region(lm.outerLips); pts["medianLine"] = region(lm.medianLine)
        }
        let rec: [String: Any] = ["file": url.lastPathComponent, "stem": stem, "chip": chipOK, "pts": pts,
            "x1": b.minX * W, "y1": (1 - b.maxY) * H, "x2": b.maxX * W, "y2": (1 - b.minY) * H,
            "yaw": face.yaw?.doubleValue ?? 999, "roll": face.roll?.doubleValue ?? 999, "pitch": face.pitch?.doubleValue ?? 999,
            "quality": q, "conf": face.confidence]
        let data = try! JSONSerialization.data(withJSONObject: rec)
        print(String(data: data, encoding: .utf8)!)
    }
}
