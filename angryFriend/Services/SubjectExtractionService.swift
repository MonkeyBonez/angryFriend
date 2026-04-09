import Vision
import UIKit
import CoreImage

actor SubjectExtractionService {
    static let shared = SubjectExtractionService()

    /// Returns a UIImage with the foreground subject cut out (transparent background).
    /// Falls back to a center-square crop of the original if extraction fails.
    func extractSubject(from image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return centerSquareCrop(image) }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return centerSquareCrop(image)
        }

        guard let observation = request.results?.first else {
            return centerSquareCrop(image)
        }

        do {
            // generateMaskedImage returns RGBA CVPixelBuffer:
            // foreground pixels keep original color, background alpha = 0
            let pixelBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let outCG = context.createCGImage(ciImage, from: ciImage.extent) else {
                return centerSquareCrop(image)
            }
            return centerSquareCrop(UIImage(cgImage: outCG))
        } catch {
            return centerSquareCrop(image)
        }
    }

    // MARK: Zoom-to-face extraction (Feature 3)

    /// Crops to the face region (2× padding) then runs subject extraction on the crop.
    /// Falls back to full-image extraction if faceBoundingBox is zero or crop fails.
    func extractSubjectAroundFace(from image: UIImage, faceBoundingBox: CGRect) -> UIImage {
        guard faceBoundingBox != .zero, let cgImage = image.cgImage else {
            return extractSubject(from: image)
        }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        // 2× face area: 0.5 padding on each normalized side
        let pad: CGFloat = 0.5
        let box = faceBoundingBox
        let expandedX = box.origin.x - pad * box.width
        let expandedY = box.origin.y - pad * box.height
        let expandedW = box.width * (1 + 2 * pad)
        let expandedH = box.height * (1 + 2 * pad)

        // Y-flip: Vision bottom-left origin → CGImage top-left origin
        let flippedY = 1.0 - expandedY - expandedH

        let cropRect = CGRect(
            x: max(0, expandedX * w),
            y: max(0, flippedY * h),
            width: min(expandedW * w, w - max(0, expandedX * w)),
            height: min(expandedH * h, h - max(0, flippedY * h))
        )

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return extractSubject(from: image)
        }
        return extractSubject(from: UIImage(cgImage: cropped))
    }

    // MARK: Square crop centered on image

    private func centerSquareCrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let side = min(w, h)
        let x = (w - side) / 2
        let y = (h - side) / 2
        guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
            return image
        }
        return UIImage(cgImage: cropped)
    }
}
