import SwiftUI

// The pictures inside the add-a-friend tutorial card: a cartoon version of the
// Photos picker populated with stick figures, so no real faces are needed.

// MARK: - Stick figures

/// One recognisable feature per person — the friend being added always wears the hat.
enum StickFeature: CaseIterable {
    case hat, spikes, long, bun, pony, cap, curls, bow, mohawk, beard, halo, none

    static let friend: StickFeature = .hat
    static func person(_ i: Int) -> StickFeature { allCases[i % allCases.count] }
    /// Anyone but the friend, picked deterministically from an index.
    static func other(_ i: Int) -> StickFeature { allCases[1 + i % (allCases.count - 1)] }
}

struct StickPose {
    let arms: (CGPoint, CGPoint)
    let legs: (CGPoint, CGPoint)
    var lift: CGFloat = 0
    var lean: Double = 0

    static let all: [StickPose] = [
        StickPose(arms: (.init(x: 13, y: 25), .init(x: 27, y: 25)), legs: (.init(x: 15, y: 36), .init(x: 25, y: 36))),             // standing
        StickPose(arms: (.init(x: 13, y: 25), .init(x: 28, y: 12)), legs: (.init(x: 15, y: 36), .init(x: 25, y: 36))),             // waving
        StickPose(arms: (.init(x: 12, y: 12), .init(x: 28, y: 12)), legs: (.init(x: 15, y: 36), .init(x: 25, y: 36))),             // cheering
        StickPose(arms: (.init(x: 11, y: 20), .init(x: 29, y: 20)), legs: (.init(x: 12, y: 36), .init(x: 28, y: 36))),             // star
        StickPose(arms: (.init(x: 13, y: 17), .init(x: 27, y: 24)), legs: (.init(x: 13, y: 34), .init(x: 27, y: 35))),             // running
        StickPose(arms: (.init(x: 12, y: 12), .init(x: 28, y: 12)), legs: (.init(x: 14, y: 32), .init(x: 26, y: 32)), lift: -3),   // jumping
        StickPose(arms: (.init(x: 14, y: 26), .init(x: 26, y: 26)), legs: (.init(x: 15, y: 36), .init(x: 25, y: 36)), lean: 10),   // leaning
        StickPose(arms: (.init(x: 13, y: 25), .init(x: 27, y: 14)), legs: (.init(x: 17, y: 36), .init(x: 27, y: 34))),             // pointing
    ]
    static func at(_ i: Int) -> StickPose { all[i % all.count] }
}

/// A person to draw: who, how they're standing, and where in the 40×40 frame.
struct StickPerson {
    var feature: StickFeature
    var pose: Int = 0
    var x: CGFloat = 0
    var scale: CGFloat = 1
}

/// Draws one or more stick figures in a 40×40 design space scaled to fit.
struct StickFigures: View {
    let people: [StickPerson]
    var color: Color = StickerTheme.ink

    init(_ people: [StickPerson], color: Color = StickerTheme.ink) {
        self.people = people
        self.color = color
    }

    init(_ feature: StickFeature, pose: Int = 0) {
        self.init([StickPerson(feature: feature, pose: pose)])
    }

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 40
            context.translateBy(x: (size.width - 40 * k) / 2, y: (size.height - 40 * k) / 2)
            context.scaleBy(x: k, y: k)
            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)

            for person in people {
                let pose = StickPose.at(person.pose)
                var c = context
                c.translateBy(x: person.x, y: pose.lift)
                // Lean and scale both pivot on the feet so figures stay grounded.
                c.translateBy(x: 20, y: 36)
                c.rotate(by: .degrees(pose.lean))
                c.scaleBy(x: person.scale, y: person.scale)
                c.translateBy(x: -20, y: -36)
                c.stroke(Self.body(pose), with: .color(color), style: style)
                c.stroke(Self.feature(person.feature), with: .color(color), style: style)
            }
        }
    }

    private static func body(_ pose: StickPose) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 15, y: 6, width: 10, height: 10))
        p.move(to: CGPoint(x: 20, y: 16)); p.addLine(to: CGPoint(x: 20, y: 27))
        p.move(to: CGPoint(x: 20, y: 19)); p.addLine(to: pose.arms.0)
        p.move(to: CGPoint(x: 20, y: 19)); p.addLine(to: pose.arms.1)
        p.move(to: CGPoint(x: 20, y: 27)); p.addLine(to: pose.legs.0)
        p.move(to: CGPoint(x: 20, y: 27)); p.addLine(to: pose.legs.1)
        return p
    }

    private static func feature(_ f: StickFeature) -> Path {
        var p = Path()
        switch f {
        case .hat:
            p.move(to: CGPoint(x: 12, y: 7)); p.addLine(to: CGPoint(x: 28, y: 7))
            p.move(to: CGPoint(x: 16, y: 7)); p.addLine(to: CGPoint(x: 16, y: 2))
            p.addLine(to: CGPoint(x: 24, y: 2)); p.addLine(to: CGPoint(x: 24, y: 7))
        case .spikes:
            p.move(to: CGPoint(x: 16, y: 7)); p.addLine(to: CGPoint(x: 15, y: 3))
            p.move(to: CGPoint(x: 20, y: 6)); p.addLine(to: CGPoint(x: 20, y: 2))
            p.move(to: CGPoint(x: 24, y: 7)); p.addLine(to: CGPoint(x: 25, y: 3))
        case .long:
            p.move(to: CGPoint(x: 15, y: 10)); p.addLine(to: CGPoint(x: 15, y: 18))
            p.move(to: CGPoint(x: 25, y: 10)); p.addLine(to: CGPoint(x: 25, y: 18))
        case .bun:
            p.addEllipse(in: CGRect(x: 18, y: 2, width: 4, height: 4))
        case .pony:
            p.move(to: CGPoint(x: 25, y: 9)); p.addLine(to: CGPoint(x: 30, y: 14))
        case .cap:
            p.addArc(center: CGPoint(x: 20, y: 9), radius: 5, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            p.addLine(to: CGPoint(x: 30, y: 9))
        case .curls:
            for cx in [16.0, 20.0, 24.0] {
                p.addEllipse(in: CGRect(x: cx - 1.6, y: (cx == 20 ? 5 : 6) - 1.6, width: 3.2, height: 3.2))
            }
        case .bow:
            p.move(to: CGPoint(x: 20, y: 6)); p.addLine(to: CGPoint(x: 16, y: 3)); p.addLine(to: CGPoint(x: 16, y: 8)); p.closeSubpath()
            p.move(to: CGPoint(x: 20, y: 6)); p.addLine(to: CGPoint(x: 24, y: 3)); p.addLine(to: CGPoint(x: 24, y: 8)); p.closeSubpath()
        case .mohawk:
            p.move(to: CGPoint(x: 20, y: 6)); p.addLine(to: CGPoint(x: 20, y: 1))
            p.move(to: CGPoint(x: 17.5, y: 6.5)); p.addLine(to: CGPoint(x: 17.5, y: 3))
            p.move(to: CGPoint(x: 22.5, y: 6.5)); p.addLine(to: CGPoint(x: 22.5, y: 3))
        case .beard:
            p.move(to: CGPoint(x: 16, y: 14)); p.addQuadCurve(to: CGPoint(x: 24, y: 14), control: CGPoint(x: 20, y: 20))
        case .halo:
            p.addEllipse(in: CGRect(x: 15, y: 1.5, width: 10, height: 3))
        case .none:
            break
        }
        return p
    }
}

/// The friend's photo number `i`: same person every time, different pose,
/// framing and company — so the grid reads as a real album, not a repeat.
func friendPhoto(_ i: Int) -> [StickPerson] {
    let me = StickFeature.friend
    let other = StickFeature.other(i * 5), third = StickFeature.other(i * 3 + 4)
    switch i % 5 {
    case 0: return [StickPerson(feature: me, pose: i)]
    case 1: return [StickPerson(feature: me, pose: i, scale: 0.7)]
    case 2: return [StickPerson(feature: me, pose: i, x: -9, scale: 0.8), StickPerson(feature: other, pose: i + 3, x: 9, scale: 0.8)]
    case 3: return [StickPerson(feature: me, pose: i, x: i % 2 == 0 ? -7 : 7, scale: 0.9)]
    default: return [StickPerson(feature: other, pose: i + 1, x: -12, scale: 0.62),
                     StickPerson(feature: me, pose: i, scale: 0.62),
                     StickPerson(feature: third, pose: i + 5, x: 12, scale: 0.62)]
    }
}

// MARK: - Picker parts

/// Pink ring around the thing the step says to tap.
struct TapRing: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(StickerTheme.pink, lineWidth: 2.5)
                .padding(-4)
        )
    }
}

extension View {
    func tapRing(cornerRadius: CGFloat = 8) -> some View { modifier(TapRing(cornerRadius: cornerRadius)) }
}

private let wireGrey = Color(red: 0.90, green: 0.89, blue: 0.85)
private let wireText = Color(red: 0.48, green: 0.46, blue: 0.42)

/// One square in the picker grid. Pastel-backed when it holds a person.
struct MiniTile<Content: View>: View {
    var index: Int
    var tinted: Bool = true
    var round: Bool = false
    var selected: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: round ? 10 : 6)
                .fill(tinted ? StickerTheme.tile(index) : wireGrey)
            content()
                .padding(2)
            if selected {
                RoundedRectangle(cornerRadius: round ? 10 : 6)
                    .stroke(StickerTheme.pink, lineWidth: 2.5)
                Circle()
                    .fill(StickerTheme.pink)
                    .frame(width: 14, height: 14)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .black)).foregroundStyle(.white))
                    .padding(3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: round ? 10 : 6))
    }
}

/// A fixed-column grid of tiles, laid out by hand so every tile keeps its square.
struct MiniGrid<Content: View>: View {
    var count: Int
    var columns: Int = 4
    @ViewBuilder var tile: (Int) -> Content

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<Int((Double(count) / Double(columns)).rounded(.up)), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { col in
                        let i = row * columns + col
                        if i < count { tile(i) } else { Color.clear.aspectRatio(1, contentMode: .fit) }
                    }
                }
            }
        }
    }
}

struct MiniDot: View {
    var symbol: String
    var filled: Bool = false
    var ringed: Bool = false

    var body: some View {
        Circle()
            .fill(filled ? StickerTheme.pink : .white)
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 1.5))
            .overlay(Image(systemName: symbol).font(.system(size: 9, weight: .black)).foregroundStyle(filled ? .white : StickerTheme.ink))
            .overlay {
                if ringed { Circle().stroke(StickerTheme.pink, lineWidth: 2.5).padding(-4) }
            }
    }
}

/// The picker's top bar: close · Photos | Collections · done.
struct MiniPickerBar: View {
    var collectionsSelected: Bool
    var ringCollections: Bool = false

    var body: some View {
        HStack {
            MiniDot(symbol: "xmark")
            Spacer()
            HStack(spacing: 0) {
                segment("Photos", on: !collectionsSelected)
                segment("Collections", on: collectionsSelected)
                    .overlay {
                        if ringCollections { Capsule().stroke(StickerTheme.pink, lineWidth: 2.5).padding(-3) }
                    }
            }
            .overlay(Capsule().stroke(wireGrey, lineWidth: 1.5))
            Spacer()
            MiniDot(symbol: "checkmark")
        }
    }

    private func segment(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.sticker(10, on ? .heavy : .semibold))
            .foregroundStyle(on ? StickerTheme.ink : wireText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(on ? wireGrey : .clear, in: Capsule())
    }
}

struct MiniHeader: View {
    var title: String
    var doneFilled: Bool = false
    var ringDone: Bool = false

    var body: some View {
        HStack {
            MiniDot(symbol: "chevron.left")
            Spacer()
            Text(title).font(.sticker(12, .heavy)).foregroundStyle(StickerTheme.ink)
            Spacer()
            MiniDot(symbol: "checkmark", filled: doneFilled, ringed: ringDone)
        }
    }
}

/// A Collections "shelf": label with chevron over a row of three round tiles.
struct MiniShelf: View {
    var name: String
    var people: Bool = false
    var ringed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(name) ›")
                .font(.sticker(12, .heavy))
                .foregroundStyle(StickerTheme.ink)
                .modifier(RingIf(on: ringed))
            MiniGrid(count: 4) { i in
                MiniTile(index: i, tinted: people, round: true) {
                    if people { StickFigures(StickFeature.person(i)) }
                }
            }
        }
        .opacity(people ? 1 : 0.4)
    }
}

private struct RingIf: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.tapRing(cornerRadius: 6) } else { content }
    }
}

// MARK: - The four pictures

/// White picker frame every picture sits in. Fixed height so the card never resizes.
struct PictureFrame<Content: View>: View {
    static var height: CGFloat { 250 }
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 7) { content() }
            .font(.sticker(10, .semibold))
            .foregroundStyle(wireText)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(9)
            .frame(height: Self.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .stickerCard(cornerRadius: 16)
    }
}

struct IntroPicture: View {
    var body: some View {
        PictureFrame {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 16)
                .fill(StickerTheme.tile(1))
                .frame(width: 118, height: 118)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StickerTheme.ink, lineWidth: 2.5))
                .overlay(StickFigures(.friend, pose: 1).padding(10))
                .rotationEffect(.degrees(-2))
            Text("Photos already sorts your pictures by person.")
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

struct CollectionsPicture: View {
    var body: some View {
        PictureFrame {
            MiniPickerBar(collectionsSelected: false, ringCollections: true)
            MiniGrid(count: 20) { i in
                MiniTile(index: i, tinted: false) { EmptyView() }
            }
            .opacity(0.4)
        }
    }
}

struct PeoplePicture: View {
    var body: some View {
        PictureFrame {
            MiniPickerBar(collectionsSelected: true)
            MiniShelf(name: "Shared Albums")
            MiniShelf(name: "People", people: true, ringed: true)
        }
    }
}

struct FriendPicture: View {
    var body: some View {
        PictureFrame {
            MiniHeader(title: "People")
            MiniGrid(count: 12) { i in
                MiniTile(index: i, round: true) { StickFigures(StickFeature.person(i)) }
                    .modifier(RingIf(on: i == 0))
            }
        }
    }
}

/// The closing frame: why "all photos" access is worth allowing, and the
/// promise that goes with it. Shown right before iOS asks.
struct KeepFindingPicture: View {
    var body: some View {
        PictureFrame {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: -6) {
                newPhoto(index: 3, pose: 4, lean: -8, dy: 6)
                RoundedRectangle(cornerRadius: 16)
                    .fill(StickerTheme.tile(1))
                    .frame(width: 92, height: 92)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(StickerTheme.ink, lineWidth: 2.5))
                    .overlay(StickFigures(.friend, pose: 2).padding(8))
                    .zIndex(1)
                newPhoto(index: 2, pose: 7, lean: 8, dy: 6)
            }
            Text("Allow access to all photos and we'll keep finding new ones of your friend, so every game has fresh cards.")
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            HStack(spacing: 5) {
                Image(systemName: "lock.shield.fill")
                Text("Stays on your phone. Never uploaded.")
            }
            .font(.sticker(11, .heavy))
            .foregroundStyle(StickerTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(StickerTheme.tile(2), in: Capsule())
            .overlay(Capsule().stroke(StickerTheme.ink, lineWidth: 1.5))
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
    }

    /// A small photo that has just been found — tagged "new" like a fresh sticker.
    private func newPhoto(index: Int, pose: Int, lean: Double, dy: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(StickerTheme.tile(index))
            .frame(width: 58, height: 58)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StickerTheme.ink, lineWidth: 2))
            .overlay(StickFigures(.friend, pose: pose).padding(5))
            .overlay(alignment: .top) {
                Text("new")
                    .font(.sticker(9, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(StickerTheme.pink, in: Capsule())
                    .overlay(Capsule().stroke(StickerTheme.ink, lineWidth: 1.2))
                    .offset(y: -9)
            }
            .rotationEffect(.degrees(lean))
            .offset(y: dy)
    }
}

/// Step 4, animated: a finger taps the first photo, drags to the bottom-right
/// corner and holds while the list scrolls and selects everything, then taps the
/// checkmark. Loops while on screen; the caption follows each beat.
struct SelectPicture: View {
    @Binding var caption: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = 4
    private let photoCount = 32
    private let gap: CGFloat = 4

    @State private var selectedCount = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var finger = CGPoint(x: 0, y: 0)
    @State private var fingerShown = false
    @State private var fingerDown = false
    @State private var checked = false

    static let stillCaption = "Tap the top-left photo, drag to the bottom-right corner and hold while it scrolls. Then tap the checkmark."

    var body: some View {
        PictureFrame {
            MiniHeader(title: "Hat friend", doneFilled: checked, ringDone: reduceMotion)
            GeometryReader { geo in
                let tile = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                let rows = Int((Double(photoCount) / Double(columns)).rounded(.up))
                MiniGrid(count: photoCount, columns: columns) { i in
                    MiniTile(index: i, selected: reduceMotion || i < selectedCount) {
                        StickFigures(friendPhoto(i))
                    }
                }
                // Full height up front so tiles stay square instead of squeezing to fit.
                .frame(width: geo.size.width, height: CGFloat(rows) * (tile + gap) - gap)
                .offset(y: scrollOffset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if reduceMotion {
                        tag("1 · tap").padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if reduceMotion {
                        tag("2 · drag here, hold").padding(4)
                    }
                }
                .task(id: geo.size) {
                    guard !reduceMotion, geo.size.height > 0 else { return }
                    await loop(viewSize: geo.size, tile: tile)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if fingerShown {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(StickerTheme.ink)
                    .shadow(color: .white, radius: 0, x: 1.5, y: 1.5)
                    .scaleEffect(fingerDown ? 0.8 : 1, anchor: .topLeading)
                    .position(finger)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { if reduceMotion { caption = Self.stillCaption } }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.sticker(9.5, .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(StickerTheme.pink, in: RoundedRectangle(cornerRadius: 5))
    }

    // Positions are in the picture's own space: 9pt padding, 20pt header, 7pt gap.
    private func loop(viewSize: CGSize, tile: CGFloat) async {
        let gridOrigin = CGPoint(x: 9, y: 9 + 20 + 7)
        let rowHeight = tile + gap
        let rows = Int((Double(photoCount) / Double(columns)).rounded(.up))
        let visibleRows = max(1, Int(viewSize.height / rowHeight))
        let travel = max(0, CGFloat(rows) * rowHeight - gap - viewSize.height)
        // The finger's tip sits at the glyph's top-left, so offset a touch inward.
        let tip = CGSize(width: 10, height: 6)
        let firstTile = CGPoint(x: gridOrigin.x + tile / 2 + tip.width, y: gridOrigin.y + tile / 2 + tip.height)
        let corner = CGPoint(x: gridOrigin.x + viewSize.width * 0.86 + tip.width, y: gridOrigin.y + viewSize.height * 0.9 + tip.height)
        let check = CGPoint(x: 9 + viewSize.width - 10 + tip.width, y: 9 + 10 + tip.height)
        let rest = CGPoint(x: 9 + viewSize.width / 2, y: gridOrigin.y + viewSize.height * 0.95)

        func move(to point: CGPoint, over seconds: Double) async {
            withAnimation(.easeInOut(duration: seconds)) { finger = point }
            try? await Task.sleep(for: .seconds(seconds + 0.08))
        }
        func press() async {
            withAnimation(.easeOut(duration: 0.12)) { fingerDown = true }
            try? await Task.sleep(for: .seconds(0.22))
            withAnimation(.easeOut(duration: 0.12)) { fingerDown = false }
            try? await Task.sleep(for: .seconds(0.15))
        }
        func selectRows(from: Int, to: Int, over seconds: Double) async {
            for row in from..<max(from, to) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { selectedCount = min(photoCount, (row + 1) * columns) }
                try? await Task.sleep(for: .seconds(seconds / Double(max(1, to - from))))
            }
        }

        while !Task.isCancelled {
            // Reset to the start of the loop without animating.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                selectedCount = 0; scrollOffset = 0; checked = false; fingerDown = false
                finger = rest; fingerShown = true
            }
            caption = "Tap the top-left photo."
            try? await Task.sleep(for: .seconds(0.7)); if Task.isCancelled { return }

            await move(to: firstTile, over: 0.6); if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.12)) { fingerDown = true; selectedCount = 1 }
            try? await Task.sleep(for: .seconds(0.5)); if Task.isCancelled { return }

            caption = "Keep your finger down and drag to the bottom-right corner."
            async let drag: Void = move(to: corner, over: 1.1)
            await selectRows(from: 0, to: visibleRows, over: 1.1)
            await drag; if Task.isCancelled { return }

            caption = "Hold there. The list scrolls and selects everything."
            withAnimation(.linear(duration: 2.2)) { scrollOffset = -travel }
            await selectRows(from: visibleRows, to: rows, over: 2.2); if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation(.easeOut(duration: 0.12)) { fingerDown = false }

            caption = "Tap the checkmark."
            await move(to: check, over: 0.7); if Task.isCancelled { return }
            await press()
            withAnimation(.easeOut(duration: 0.15)) { checked = true }
            try? await Task.sleep(for: .seconds(1.8))
        }
    }
}
