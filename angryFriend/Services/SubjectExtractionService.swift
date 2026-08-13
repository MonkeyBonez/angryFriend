import Vision
import UIKit
import CoreImage
import os

actor SubjectExtractionService {
    static let shared = SubjectExtractionService()
    private static let logger = Logger(subsystem: "com.angryFriend", category: "SubjectExtraction")

    /// Extracts the foreground subject from the full image.
    /// 1. Detects faces on the original (reliable — full context, no transparency)
    /// 2. Checks if the friend's face is in the foreground mask
    /// 3. Returns face-aware crop of cutout (if friend in mask) or original (if not)
    func extractSubject(from image: UIImage, faceBoundingBox: CGRect = .zero) -> UIImage {
        let normalized = Self.normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return centerSquareCrop(normalized) }

        // Step 1: Determine the face box. The scan already located the matching face,
        // so reuse its box (normalized coords are resolution-independent) and skip a
        // second full-image face-detection pass. Only re-detect for the .zero fallback
        // (e.g. saved-friend rehydration before the index is consulted).
        let faceBox: CGRect
        if faceBoundingBox != .zero {
            faceBox = faceBoundingBox
        } else {
            let detectedFaces = Self.detectFaces(in: cgImage)
            guard let best = Self.bestFace(from: detectedFaces, near: .zero) else {
                Self.logger.info("No faces detected in original — center crop fallback")
                return centerSquareCrop(normalized)
            }
            faceBox = best.boundingBox
        }

        // Step 2: Run foreground instance mask
        let maskRequest = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([maskRequest])
        } catch {
            return faceAwareSquareCrop(normalized, faceBox: faceBox)
        }

        guard let observation = maskRequest.results?.first else {
            return faceAwareSquareCrop(normalized, faceBox: faceBox)
        }

        // Step 3: Find which foreground instance contains the friend's face, so the
        // cutout isolates just that person instead of everyone in the photo.
        var friendInstance: IndexSet? = nil
        for instance in observation.allInstances {
            let covers = Self.faceRegionHasForeground(
                observation: observation,
                handler: handler,
                faceBox: faceBox,
                instances: IndexSet(integer: instance)
            )
            if covers {
                friendInstance = IndexSet(integer: instance)
                break
            }
        }

        guard let friendInstance else {
            // Friend was masked as background — use original photo with face-aware crop
            Self.logger.info("Friend face not in any foreground instance — using original photo")
            return faceAwareSquareCrop(normalized, faceBox: faceBox)
        }

        // Step 4: Generate the single-person cutout and return face-aware crop of it
        do {
            let pixelBuffer = try observation.generateMaskedImage(
                ofInstances: friendInstance,
                from: handler,
                croppedToInstancesExtent: false
            )
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let outCG = context.createCGImage(ciImage, from: ciImage.extent) else {
                return faceAwareSquareCrop(normalized, faceBox: faceBox)
            }
            return faceAwareSquareCrop(UIImage(cgImage: outCG), faceBox: faceBox)
        } catch {
            return faceAwareSquareCrop(normalized, faceBox: faceBox)
        }
    }

    // MARK: - Face detection on original image

    /// Runs VNDetectFaceRectanglesRequest on a CGImage. Returns empty array on error.
    private static func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return request.results ?? []
    }

    /// Picks the best face: if storedBox is non-zero, picks the detected face closest
    /// to it (handles fresh-scan path). Otherwise picks the largest face (saved friends).
    private static func bestFace(from faces: [VNFaceObservation], near storedBox: CGRect) -> VNFaceObservation? {
        guard !faces.isEmpty else { return nil }
        if storedBox != .zero {
            // Pick face whose center is closest to storedBox center
            return faces.min(by: { a, b in
                distance(a.boundingBox, storedBox) < distance(b.boundingBox, storedBox)
            })
        } else {
            // Pick largest face by area
            return faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        }
    }

    /// Euclidean distance between centers of two Vision bounding boxes.
    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy  // no need for sqrt, just comparing
    }

    // MARK: - Mask check: is face region in foreground?

    /// Checks if the friend's face bbox has coverage in the mask of the given instances.
    /// Uses generateScaledMaskForImage which returns OneComponent8 (0=bg, 255=fg).
    private static func faceRegionHasForeground(
        observation: VNInstanceMaskObservation,
        handler: VNImageRequestHandler,
        faceBox: CGRect,
        instances: IndexSet
    ) -> Bool {
        guard let maskBuffer = try? observation.generateScaledMaskForImage(
            forInstances: instances, from: handler
        ) else { return false } // can't scope to this instance → try the next one

        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(maskBuffer) else { return true }
        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(maskBuffer)

        // Vision bbox: origin bottom-left, y-up → pixel buffer: origin top-left, y-down
        let flippedMidY = 1.0 - faceBox.midY
        let cx = clamp(Int(faceBox.midX * CGFloat(width)), lo: 0, hi: width - 1)
        let cy = clamp(Int(flippedMidY * CGFloat(height)), lo: 0, hi: height - 1)

        // Sample center + 4 corners within the face bbox
        let halfW = Swift.max(1, Int(faceBox.width * CGFloat(width) / 4))
        let halfH = Swift.max(1, Int(faceBox.height * CGFloat(height) / 4))
        let offsets: [(Int, Int)] = [
            (0, 0),
            (-halfW, -halfH), (halfW, -halfH),
            (-halfW,  halfH), (halfW,  halfH),
        ]

        var visible = 0
        for (dx, dy) in offsets {
            let px = clamp(cx + dx, lo: 0, hi: width - 1)
            let py = clamp(cy + dy, lo: 0, hi: height - 1)

            let isForeground: Bool
            if pixelFormat == kCVPixelFormatType_OneComponent32Float {
                let ptr = base.assumingMemoryBound(to: Float.self)
                let rowFloats = bytesPerRow / MemoryLayout<Float>.stride
                isForeground = ptr[py * rowFloats + px] > 0.5
            } else {
                // OneComponent8: 0 = background, 255 = foreground
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                isForeground = ptr[py * bytesPerRow + px] > 128
            }

            if isForeground { visible += 1 }
        }

        logger.debug("Face mask check: \(visible)/5 sample points foreground")
        return visible >= 3
    }

    // MARK: - Face-aware square crop

    /// Crops to a square centered on the face, keeping the friend in frame.
    /// Falls back to center crop if faceBox is zero.
    private func faceAwareSquareCrop(_ image: UIImage, faceBox: CGRect) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let side = Swift.min(w, h)

        // Convert Vision bbox center (normalized, y-up) → CGImage pixels (y-down)
        let faceCenterX = faceBox.midX * w
        let faceCenterY = (1.0 - faceBox.midY) * h

        // Center the square on the face, clamped to image bounds
        var x = faceCenterX - side / 2
        var y = faceCenterY - side / 2
        x = Swift.max(0, Swift.min(x, w - side))
        y = Swift.max(0, Swift.min(y, h - side))

        guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
            return image
        }
        return UIImage(cgImage: cropped)
    }

    // MARK: - Orientation normalization

    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
    }

    // MARK: - Center square crop (last-resort fallback)

    private func centerSquareCrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let side = Swift.min(w, h)
        let x = (w - side) / 2
        let y = (h - side) / 2
        guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
            return image
        }
        return UIImage(cgImage: cropped)
    }
}

@inline(__always)
private func clamp(_ v: Int, lo: Int, hi: Int) -> Int {
    Swift.max(lo, Swift.min(v, hi))
}
