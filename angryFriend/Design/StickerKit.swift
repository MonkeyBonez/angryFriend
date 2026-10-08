import SwiftUI

// MARK: - Palette

/// The Sticker Bomb identity: candy tiles slapped onto a highlighter-yellow sheet,
/// everything outlined in ink with a hard offset shadow instead of a soft blur.
/// Deliberately single-theme — the yellow ground *is* the app, so there's no dark
/// variant; `ContentView` pins the color scheme to light to match.
enum StickerTheme {
    static let sun = Color(red: 1.00, green: 0.851, blue: 0.282)     // #FFD948
    static let ink = Color(red: 0.129, green: 0.102, blue: 0.051)    // #211A0D
    static let pink = Color(red: 1.00, green: 0.302, blue: 0.553)    // #FF4D8D
    static let blue = Color(red: 0.239, green: 0.420, blue: 1.00)    // #3D6BFF
    static let flame = Color(red: 1.00, green: 0.231, blue: 0.188)   // #FF3B30
    static let mint = Color(red: 0.184, green: 0.749, blue: 0.443)   // #2FBF71

    /// Pastel backings so no two neighbouring cutouts sit on the same color.
    static let tiles: [Color] = [
        Color(red: 0.749, green: 0.890, blue: 1.00),   // sky
        Color(red: 1.00, green: 0.788, blue: 0.867),   // bubblegum
        Color(red: 0.812, green: 0.961, blue: 0.847),  // pistachio
        Color(red: 1.00, green: 0.878, blue: 0.722),   // apricot
        Color(red: 0.894, green: 0.839, blue: 1.00),   // lilac
    ]

    static func tile(_ index: Int) -> Color {
        tiles[abs(index) % tiles.count]
    }

    /// A stable lean per position — stickers must not re-rotate on every redraw.
    static func lean(_ index: Int) -> Double {
        let angles: [Double] = [-1.8, 1.2, -0.7, 1.9, -1.3, 0.8, -2.1, 1.5]
        return angles[abs(index) % angles.count]
    }
}

// MARK: - Type

extension Font {
    static func sticker(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Outlined display type with a hard drop shadow — the sticker-sheet headline look.
/// Built by stacking offset copies because SwiftUI has no text-stroke primitive.
struct StickerText: View {
    let text: String
    var size: CGFloat
    var fill: Color = .white
    var stroke: Color = StickerTheme.ink
    var strokeWidth: CGFloat = 2
    var drop: CGFloat = 3

    var body: some View {
        let base = Text(text).font(.sticker(size, .black))
        let ring = (0..<12).map { i -> CGPoint in
            let angle = Double(i) / 12 * 2 * .pi
            return CGPoint(x: cos(angle) * strokeWidth, y: sin(angle) * strokeWidth)
        }

        ZStack {
            base.foregroundStyle(stroke)
                .offset(x: drop + strokeWidth, y: drop + strokeWidth)
            ForEach(0..<ring.count, id: \.self) { i in
                base.foregroundStyle(stroke).offset(x: ring[i].x, y: ring[i].y)
            }
            base.foregroundStyle(fill)
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

// MARK: - Surfaces

extension View {
    /// The signature hard shadow: no blur, just ink pushed down-right.
    ///
    /// `compositingGroup` is load-bearing — without it SwiftUI shadows each drawn
    /// element separately, so any label inside the shape casts its own offset copy
    /// and the text reads as doubled.
    func hardShadow(_ color: Color = StickerTheme.ink, x: CGFloat = 3, y: CGFloat = 3) -> some View {
        compositingGroup()
            .shadow(color: color, radius: 0, x: x, y: y)
    }

    /// White card body, ink outline, offset shadow.
    func stickerCard(cornerRadius: CGFloat = 16, fill: Color = .white, lineWidth: CGFloat = 2.5) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(StickerTheme.ink, lineWidth: lineWidth)
            )
            .hardShadow()
    }

    func popIn(delay: Double = 0, from: CGFloat = 0.3, tilt: Double = -14) -> some View {
        modifier(PopIn(delay: delay, from: from, tilt: tilt))
    }

    func wiggling(_ active: Bool, amount: Double = 5, speed: Double = 1.6) -> some View {
        modifier(Wiggle(active: active, amount: amount, speed: speed))
    }
}

// MARK: - Buttons

/// Chunky sticker button that presses *into* its own shadow — the shadow shrinks
/// to zero as the label slides down-right, so it reads as physically depressed.
struct StickerButtonStyle: ButtonStyle {
    var background: Color = StickerTheme.pink
    var foreground: Color = .white
    var size: CGFloat = 17
    var cornerRadius: CGFloat = 18
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .font(.sticker(size, .heavy))
            .foregroundStyle(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 15)
            .padding(.horizontal, fullWidth ? 16 : 22)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(StickerTheme.ink, lineWidth: 2.5)
            )
            .offset(x: down ? 4 : 0, y: down ? 4 : 0)
            .compositingGroup()
            .shadow(color: StickerTheme.ink, radius: 0, x: down ? 0 : 4, y: down ? 0 : 4)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: down)
    }
}

/// Small circular sticker button — close buttons, badges, toolbar actions.
struct StickerCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 34
    var background: Color = .white
    var foreground: Color = StickerTheme.ink

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .font(.sticker(diameter * 0.42, .heavy))
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(background, in: Circle())
            .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 2))
            .offset(x: down ? 2 : 0, y: down ? 2 : 0)
            .compositingGroup()
            .shadow(color: StickerTheme.ink, radius: 0, x: down ? 0 : 2, y: down ? 0 : 2)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: down)
    }
}

/// A torn strip of tape — used for names and small captions.
struct TapeLabel: View {
    let text: String
    var tilt: Double = -2
    var size: CGFloat = 11
    var background: Color = .white
    var foreground: Color = StickerTheme.ink

    var body: some View {
        Text(text)
            .font(.sticker(size, .bold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(background)
            .overlay(Rectangle().stroke(StickerTheme.ink, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .hardShadow(StickerTheme.ink, x: 1.5, y: 1.5)
            .rotationEffect(.degrees(tilt))
    }
}

// MARK: - Backdrop

/// How the confetti moves on a screen: how far each dot wanders (points) and how
/// much it swells, with the period of each in seconds.
struct ConfettiMotion: Equatable {
    var drift: Double
    var driftPeriod: Double
    var grow: Double
    var growPeriod: Double

    /// Home and the result screen — the party is on.
    static let lively = ConfettiMotion(drift: 14, driftPeriod: 3, grow: 0.45, growPeriod: 1.4)
    /// In the game and while working — ambience, not weather.
    static let calm = ConfettiMotion(drift: 5, driftPeriod: 9, grow: 0.15, growPeriod: 4)
    static let still = ConfettiMotion(drift: 0, driftPeriod: 9, grow: 0, growPeriod: 4)
}

/// The running state of the dots. Screens share the one on `AppState` so the
/// scatter keeps moving through a screen change instead of starting over, and a
/// new motion is eased into rather than snapped to.
final class ConfettiClock {
    private(set) var drift = 0.0
    private(set) var grow = 0.0
    private(set) var phase = 0.0
    private(set) var growPhase = 0.0
    private var driftRate = 0.0
    private var growRate = 0.0
    private var last: Date?

    func advance(to now: Date, toward motion: ConfettiMotion) {
        // Capped so a return from the background doesn't fling every dot.
        let dt = last.map { min(0.1, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        let ease = 1 - exp(-dt / 0.8)
        driftRate += (2 * .pi / motion.driftPeriod - driftRate) * ease
        growRate += (2 * .pi / motion.growPeriod - growRate) * ease
        drift += (motion.drift - drift) * ease
        grow += (motion.grow - grow) * ease
        phase += driftRate * dt
        growPhase += growRate * dt
    }
}

/// Scattered confetti dots behind the yellow, placed from a seeded sequence so
/// the sheet looks hand-scattered but never reshuffles. Every screen uses the
/// same count and seed, so the dots are the same dots from one screen to the next.
struct ConfettiSheet: View {
    var motion: ConfettiMotion = .still
    var opacity: Double = 0.55
    var clock: ConfettiClock? = nil
    var count: Int = 30
    var seed: UInt64 = 11

    @State private var ownClock = ConfettiClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dots = Self.scatter(count: count, seed: seed)
        let clock = clock ?? ownClock

        Group {
            if reduceMotion {
                sheet(dots, clock: clock, now: nil)
            } else {
                TimelineView(.animation) { timeline in
                    sheet(dots, clock: clock, now: timeline.date)
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }

    private func sheet(_ dots: [Dot], clock: ConfettiClock, now: Date?) -> some View {
        let palette = [StickerTheme.pink, StickerTheme.blue, Color.white, StickerTheme.mint]
        return Canvas { context, size in
            if let now { clock.advance(to: now, toward: motion) }
            for (i, dot) in dots.enumerated() {
                // A per-dot offset so the sheet shimmers rather than sways as one.
                let offset = Double(i) * 0.9
                let x = dot.x * size.width + clock.drift * sin(clock.phase + offset)
                let y = dot.y * size.height + clock.drift * 0.7 * cos(clock.phase * 0.8 + offset * 1.3)
                let radius = max(0.4, dot.radius * (1 + clock.grow * sin(clock.growPhase + offset)))
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Ellipse().path(in: rect), with: .color(palette[dot.color]))
            }
        }
    }

    private struct Dot {
        let x: Double, y: Double, radius: Double
        let color: Int
    }

    /// Deterministic LCG — same seed always yields the same sheet.
    private static func scatter(count: Int, seed: UInt64) -> [Dot] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 100_000) / 100_000
        }
        return (0..<count).map { _ in
            Dot(x: next(), y: next(), radius: 1.6 + next() * 2.2, color: Int(next() * 4) % 4)
        }
    }
}

/// One-shot confetti explosion for the result screen. Particles are pure math —
/// launch angle, speed and spin derive from the index, so nothing is stored per frame.
struct ConfettiBurst: View {
    var count: Int = 46
    var duration: Double = 2.4

    @State private var launch = Date()
    @State private var running = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = [StickerTheme.pink, StickerTheme.blue, StickerTheme.mint, Color.white, StickerTheme.sun]

        Group {
            if running && !reduceMotion {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let t = timeline.date.timeIntervalSince(launch)
                        guard t > 0 else { return }
                        let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)

                        for i in 0..<count {
                            let seed = Double(i)
                            let angle = (seed * 2.399963) .truncatingRemainder(dividingBy: 2 * .pi)
                            let speed = 190 + (seed * 53).truncatingRemainder(dividingBy: 210)
                            let life = 1.4 + (seed * 17).truncatingRemainder(dividingBy: 90) / 90

                            guard t < life else { continue }
                            let x = origin.x + cos(angle) * speed * t
                            let y = origin.y + sin(angle) * speed * t + 420 * t * t
                            let fade = max(0, 1 - t / life)
                            let side = 5 + (seed * 7).truncatingRemainder(dividingBy: 5)
                            let spin = angle + t * 6

                            var slip = context
                            slip.opacity = fade
                            slip.translateBy(x: x, y: y)
                            slip.rotate(by: .radians(spin))
                            let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side * 0.6)
                            slip.fill(
                                RoundedRectangle(cornerRadius: 1).path(in: rect),
                                with: .color(palette[i % palette.count])
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
                .task {
                    launch = Date()
                    try? await Task.sleep(for: .seconds(duration))
                    running = false
                }
            }
        }
    }
}

/// Candy-striped progress bar with the stripes marching while work is in flight.
struct CandyProgressBar: View {
    var progress: Double
    var stripe: Color = StickerTheme.pink
    var height: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let filled = max(0, min(1, progress)) * geo.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white)

                Group {
                    if reduceMotion {
                        stripes(phase: 0)
                    } else {
                        TimelineView(.animation) { timeline in
                            let t = timeline.date.timeIntervalSinceReferenceDate
                            stripes(phase: CGFloat(t.truncatingRemainder(dividingBy: 0.7) / 0.7) * 26)
                        }
                    }
                }
                .frame(width: filled)
                .clipped()
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(StickerTheme.ink, lineWidth: 2.5))
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(progress * 100)) percent")
    }

    private func stripes(phase: CGFloat) -> some View {
        let color = stripe
        return Canvas { context, size in
            let width: CGFloat = 13
            let gap: CGFloat = 13
            var x = -size.height - phase
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + width, y: 0))
                path.addLine(to: CGPoint(x: x + width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color))
                x += width + gap
            }
        }
    }
}

// MARK: - Motion modifiers

/// Springs a view up from small-and-tilted to full size. Used to stagger stickers
/// and cards onto the screen so a grid "deals" instead of just appearing.
struct PopIn: ViewModifier {
    let delay: Double
    let from: CGFloat
    let tilt: Double

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : from)
            .rotationEffect(.degrees(shown ? 0 : tilt))
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.62).delay(delay)) {
                        shown = true
                    }
                }
            }
    }
}

/// Continuous back-and-forth lean for anything that should feel impatient.
struct Wiggle: ViewModifier {
    let active: Bool
    let amount: Double
    let speed: Double

    @State private var flipped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(flipped ? amount : -amount))
            .onAppear { start() }
            .onChange(of: active) { _, _ in start() }
    }

    private func start() {
        guard active, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: speed).repeatForever(autoreverses: true)) {
            flipped = true
        }
    }
}

/// Horizontal shake driven by a counter — bump `trigger` to shake again.
struct Shake: GeometryEffect {
    var travel: CGFloat = 12
    var shakes: CGFloat = 4
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = travel * sin(animatableData * .pi * shakes)
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}

// MARK: - Chrome

/// Custom top bar — the system navigation bar can't be made to look like torn tape,
/// so designed screens draw their own.
struct StickerTopBar<Trailing: View>: View {
    let title: String?
    let leadingLabel: String
    let onLeading: () -> Void
    @ViewBuilder var trailing: Trailing

    init(
        title: String? = nil,
        leadingLabel: String = "Done",
        onLeading: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.leadingLabel = leadingLabel
        self.onLeading = onLeading
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.press()
                onLeading()
            } label: {
                Text(leadingLabel)
            }
            .buttonStyle(StickerButtonStyle(
                background: .white,
                foreground: StickerTheme.ink,
                size: 13,
                cornerRadius: 999,
                fullWidth: false
            ))

            if let title {
                Spacer(minLength: 4)
                Text(title)
                    .font(.sticker(15, .heavy))
                    .foregroundStyle(StickerTheme.ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

// MARK: - Name field

/// The friend-name field: a slightly tilted white label that turns pink while
/// typing. Shared by the new-friend screen and the friend detail screen.
struct StickerNameField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String = "Friend's name"

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.sticker(20, .black))
            .foregroundStyle(StickerTheme.ink)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .focused(focused)
            .submitLabel(.done)
            .onSubmit { focused.wrappedValue = false }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: 250)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focused.wrappedValue ? StickerTheme.pink : StickerTheme.ink, lineWidth: 2.5)
            )
            .hardShadow(StickerTheme.ink, x: 2.5, y: 2.5)
            .rotationEffect(.degrees(-1))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: focused.wrappedValue)
    }
}
