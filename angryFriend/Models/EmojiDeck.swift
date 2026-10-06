import UIKit

/// Cards for a practice round: emoji faces standing in for friend cutouts, so the
/// game can be played before anyone has handed over a single photo. Nothing in
/// `GameModel` or the game views changes — only where the pictures come from.
enum EmojiDeck {
    /// The emoji pal's own face — on the home screen sticker and the demo tag.
    static let mascot = "🥸"

    /// Faces only (no hands, no objects) so the grid reads like a line-up.
    static let faces = [
        "😀", "😎", "🥸", "🤠", "🧐", "🤓", "😏", "🥳", "😇", "🤩",
        "😜", "🤪", "🥶", "🥵", "🤯", "😱", "🤭", "🫠", "🙃", "😴",
        "🤑", "🤡", "👻", "👽", "🤖", "😈", "🥺", "😤", "🫡", "🤔",
    ]

    /// Taps a demo round always survives before the angry card can turn up.
    static let safeOpeningTaps = 4

    /// Deals `count` distinct faces, already shuffled. None is angry yet — the
    /// demo decides at tap time (see `GameModel.setup(from:earliestAngryTap:)`).
    static func deal(count: Int) -> [GameCard] {
        faces.shuffled().prefix(max(1, min(count, faces.count))).map { face in
            GameCard(image: render(face), isAngry: false)
        }
    }

    /// Draws one emoji onto a transparent square so the card's tile colour shows
    /// through behind it, the same way a cutout sits on its tile.
    static func render(_ emoji: String, side: CGFloat = 300) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.62),
            ]
            let text = emoji as NSString
            let textSize = text.size(withAttributes: attributes)
            let origin = CGPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2)
            text.draw(at: origin, withAttributes: attributes)
        }
    }
}
