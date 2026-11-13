import AppKit
import SubzeroCore
import SubzeroEngine
import SwiftUI

// Arcade fighting-game look: pixel sprites, a 5×7 pixel font, chamfered panels.
// The fighter is an original character: Frost, an ice golem.

// MARK: - Palette

enum Arcade {
    static let night = Color(red: 0.035, green: 0.047, blue: 0.10)
    static let panel = Color(red: 0.075, green: 0.095, blue: 0.17)
    static let panelHigh = Color(red: 0.11, green: 0.14, blue: 0.24)
    static let steel = Color(red: 0.25, green: 0.31, blue: 0.47)
    static let steelLight = Color(red: 0.45, green: 0.53, blue: 0.72)
    static let ice = Color(red: 0.45, green: 0.78, blue: 0.96)
    static let iceDeep = Color(red: 0.18, green: 0.45, blue: 0.82)
    static let frost = Color(red: 0.90, green: 0.98, blue: 1.0)
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.25)
    static let ember = Color(red: 1.0, green: 0.45, blue: 0.12)
    static let blood = Color(red: 0.92, green: 0.18, blue: 0.20)
    static let life = Color(red: 0.36, green: 0.86, blue: 0.36)
    static let caution = Color(red: 1.0, green: 0.66, blue: 0.16)

    static func font(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Sprites

struct PixelSprite: Sendable {
    let rows: [String]
    let palette: [Character: Color]

    var width: Int { rows.map(\.count).max() ?? 0 }
    var height: Int { rows.count }

    func draw(in context: inout GraphicsContext, origin: CGPoint, scale: CGFloat, override: Color? = nil) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = palette[ch] else { continue }
                let rect = CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale, width: scale, height: scale)
                context.fill(Path(rect), with: .color(ch == "k" ? color : (override ?? color)))
            }
        }
    }

    /// Bitmap for AppKit (menu bar, Dock, app icon).
    func image(scale: Int, background: NSColor? = nil) -> NSImage {
        let w = width * scale, h = height * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background?.setFill()
        if background != nil { NSRect(x: 0, y: 0, width: w, height: h).fill() }
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = palette[ch] else { continue }
                NSColor(color).setFill()
                NSRect(x: x * scale, y: h - (y + 1) * scale, width: scale, height: scale).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }
}

enum Frost {
    static let palette: [Character: Color] = [
        "k": Color(red: 0.04, green: 0.06, blue: 0.14),
        "d": Color(red: 0.11, green: 0.25, blue: 0.54),
        "b": Color(red: 0.18, green: 0.45, blue: 0.82),
        "l": Color(red: 0.45, green: 0.78, blue: 0.96),
        "w": Color(red: 0.90, green: 0.98, blue: 1.0),
        "e": Color(red: 0.62, green: 0.99, blue: 1.0),
        "c": Color(red: 0.72, green: 0.94, blue: 1.0),
        "s": Color(red: 0.08, green: 0.12, blue: 0.24),
    ]

    enum Pose { case stance, cast, rest }

    static func sprite(_ pose: Pose) -> PixelSprite {
        switch pose {
        case .stance: PixelSprite(rows: stance, palette: palette)
        case .cast: PixelSprite(rows: cast, palette: palette)
        case .rest: PixelSprite(rows: rest, palette: palette)
        }
    }

    static let stance = [
        "................c...............",
        "..............c.c.c.............",
        ".............kckckc.............",
        "............kllllllk............",
        ".kkkkkk....klwwbbbblk...........",
        "kllllllk...kddddddddk...........",
        "klbbbbdw...klswssswdk...w.......",
        "klbbbbdc...klseeseedk...c.......",
        "klbbbbccckkklssssssdkkkccc......",
        "klbbbbdklllklbbbbbbdklllllk.....",
        "kldddddkbbbklbbbbbbdkbbbbblk....",
        ".kkkkkkkbbbkldddddddkbbbbbdk....",
        ".klbbbdkbbbdkkkkkkkklbbbbbdk....",
        ".klbbbdkkbbdkkkkkkkklbbbbbdk....",
        ".kldbbbllkbdkllllllklbbbbbdk....",
        "..kklbbbdkddkbbbbbbklddddddk....",
        "...klbbbdkkkbbbcbbbbkkkkkkkk....",
        "...klbbbdklbbbcwcbbbbdkbbbdk....",
        "...klbbbdklbbbbcbbbbbdkbbbdk....",
        "...klddddklbbbbbbbbdbdkbbdk.....",
        "....kkkkkklbdbbbbbdbbdkbbdk.....",
        ".........klbbdbbbbbbbdkbbdk.....",
        "........klbbbbbbbbbbbblkddk.....",
        "........kldddddccddddddkkk......",
        "........klbbbbbbbbbbbbdk........",
        "........kldddddddddddddk........",
        ".......kkkkkkkkkkkkkkkkkk.......",
        "......kllbbbddk..kldbbbllk......",
        "......klbbbdkk....kklbbbdk......",
        "......klbbbdk......klbbbdk......",
        ".....kklbbbdk......klbbbdkk.....",
        "....kllbbbbdk......klbbbbllk....",
        "....klbbbbbdk......klbbbbbdk....",
        "....klddddddk......klddddddk....",
        ".....kkkkkkk........kkkkkkk.....",
    ]

    static let cast = [
        "................c...............",
        "..............c.c.c.............",
        ".............kckckc.............",
        "............kllllllk............",
        "...........klwwbbbblk...........",
        "...........kddddddddk...........",
        ".......w...klswssswdk...w.......",
        ".......c...klseeseedk...c.......",
        "......ccckkklssssssdkkkccc......",
        ".....klllllklbbbbbbdklllllk.....",
        "....klbbbbbklbbbbbbdkbbbbblk....",
        "....klbbbbbkldddddddkbbbbbdk....",
        "....klbbbbbdkkkkkkkklbbbbbdkkkk.",
        "....kkkkkkbdkkkkkkkkkbcbbbdklllk",
        "....klllllkkkkkklllllkbcbbdkbbdk",
        "....klbbbblllllklbbbdcdddddkbbdk",
        "....klbbbbbbbbbclbbbdwwkckkbbbdk",
        "....klbbbbbbbbcwcbbbdck.kldddddk",
        "....kldddddddddclbbbdkkc.kkkkkk.",
        ".....kkkkkkkkkkklddddkc.........",
        ".........klbdbbbkkdkkdk.........",
        ".........klbbdbbbbbbbdk.........",
        "........klbbbbbbbbbbbblk........",
        "........kldddddccddddddk........",
        "........klbbbbbbbbbbbbdk........",
        "........kldddddddddddddk........",
        ".......kkkkkkkkkkkkkkkkkk.......",
        "......kllbbbddk..kldbbbllk......",
        "......klbbbdkk....kklbbbdk......",
        "......klbbbdk......klbbbdk......",
        ".....kklbbbdk......klbbbdkk.....",
        "....kllbbbbdk......klbbbbllk....",
        "....klbbbbbdk......klbbbbbdk....",
        "....klddddddk......klddddddk....",
        ".....kkkkkkk........kkkkkkk.....",
    ]

    static let rest = [
        "................c...............",
        "..............c.c.c.............",
        ".............kckckc.............",
        "............kllllllk............",
        "...........klwwbbbblk...........",
        "...........kddddddddk...........",
        ".......w...klssssssdk...w.......",
        ".......c...klsddsdsdk...c.......",
        "......ccckkklssssssdkkkccc......",
        ".....klllllklbbbbbbdklllllk.....",
        "....klbbbbbklbbbbbbdkbbbbblk....",
        "....klbbbbbkldddddddkbbbbbdk....",
        "....klbbbbbdkkkkkkkklbbbbbdk....",
        "....kkkkkbbdkkkkkkkklbbbbbdk....",
        "...klllllkbdkllllllklbbbbbdk....",
        "...klbbbdkddkbbbbbbklddddddk....",
        "...klbbbdkkkbbbcbbbbkkkkkkkk....",
        "...klbbbdklbbbcwcbbbbdklbbdk....",
        "...klbbbdklbbbbcbbbbbdklbbdk....",
        "...klbbbdklbbbbbbbbdbdklbbdk....",
        "...klbbbdklbdbbbbbdbbdklbbdk....",
        "...klbbbdklbbdbbbbbbbdklbbdk....",
        "...klbbbdkbbbbbbbbbbbblkbbblk...",
        "...klbbbdkdddddccddddddkbbbdk...",
        "...klbbbdkbbbbbbbbbbbbdkbbbdk...",
        "...klbbbdkdddddddddddddkbbbdk...",
        "...klbbbdkkkkkkkkkkkkkklddddk...",
        "...klddddkklbbdkklbbdk.kkkkk....",
        "....kkkkk.klbbdkklbbdk..........",
        "..........klbbdkklbbdk..........",
        "..........klbbdkklbbdk..........",
        "..........klbbdkklbbdk..........",
        ".........klbbbdkklbbblk.........",
        ".........klddddkklddddk.........",
        "..........kkkkk..kkkkk..........",
    ]

    /// Golem head for the menu bar: '#' is ink, '.' is clear.
    static let head = [
        "....#.#.#....",
        "....#.#.#....",
        "..#########..",
        ".###########.",
        ".###########.",
        ".##..###..##.",
        ".##..###..##.",
        ".###########.",
        "..#########..",
        "#..#######..#",
        "###.#####.###",
        "#############",
        "#############",
    ]
}

/// Draws a sprite at an integer scale, optionally bobbing like an idle fighter.
struct SpriteView: View {
    let sprite: PixelSprite
    var scale: CGFloat = 3
    var bob = false
    var tint: Color?
    var dim = false

    var body: some View {
        let w = CGFloat(sprite.width) * scale
        let h = CGFloat(sprite.height) * scale
        Group {
            if bob {
                TimelineView(.periodic(from: .now, by: 0.55)) { timeline in
                    let up = Int(timeline.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                    canvas(offset: up ? 0 : scale)
                }
            } else {
                canvas(offset: 0)
            }
        }
        .frame(width: w, height: h + scale)
        .saturation(dim ? 0.15 : 1)
        .opacity(dim ? 0.8 : 1)
    }

    private func canvas(offset: CGFloat) -> some View {
        Canvas { context, _ in
            sprite.draw(in: &context, origin: CGPoint(x: 0, y: offset), scale: scale, override: tint)
        }
    }
}

// MARK: - Pixel font

enum PixelFont {
    static let glyphs: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "J": ["..###", "...#.", "...#.", "...#.", "#..#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
        "!": ["#", "#", "#", "#", "#", ".", "#"],
        ".": [".", ".", ".", ".", ".", ".", "#"],
        ":": [".", "#", ".", ".", ".", "#", "."],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
        "-": ["...", "...", "...", "###", "...", "...", "..."],
        "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
        " ": ["...", "...", "...", "...", "...", "...", "..."],
    ]

    static func glyph(_ ch: Character) -> [String] {
        glyphs[Character(ch.uppercased())] ?? glyphs["?"]!
    }

    /// Width in font pixels, with 1 px between letters.
    static func width(_ text: String) -> Int {
        let widths = text.map { glyph($0)[0].count }
        return widths.reduce(0, +) + max(0, widths.count - 1)
    }
}

/// Arcade title text: blocky letters with a top-to-bottom gradient, outline and drop shadow.
struct PixelText: View {
    let text: String
    var scale: CGFloat = 3
    var colors: [Color] = [Arcade.frost, Arcade.gold, Arcade.ember]
    var outline: Color = Arcade.night

    var body: some View {
        let w = CGFloat(PixelFont.width(text) + 2) * scale
        let h = CGFloat(7 + 3) * scale
        Canvas { context, _ in
            var cells: [(x: Int, y: Int)] = []
            var cursor = 1
            for ch in text {
                let glyph = PixelFont.glyph(ch)
                for (y, row) in glyph.enumerated() {
                    for (x, bit) in row.enumerated() where bit == "#" {
                        cells.append((cursor + x, y + 1))
                    }
                }
                cursor += glyph[0].count + 1
            }
            func fill(_ x: Int, _ y: Int, _ color: Color) {
                context.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)), with: .color(color))
            }
            // Drop shadow, then outline, then the letters.
            for c in cells { fill(c.x + 1, c.y + 2, outline.opacity(0.55)) }
            for c in cells {
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    fill(c.x + dx, c.y + dy, outline)
                }
            }
            for c in cells {
                let band = min(colors.count - 1, (c.y - 1) * colors.count / 7)
                fill(c.x, c.y, colors[band])
            }
        }
        .frame(width: w, height: h)
        .accessibilityLabel(text)
    }
}

// MARK: - Shapes and surfaces

/// Rectangle with cut corners, like an arcade HUD frame.
struct Chamfer: InsettableShape {
    var cut: CGFloat = 6
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = min(cut, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Chamfer {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// Night sky with snow and a stone floor: the arena behind the fighter.
struct ArenaBackdrop: View {
    var tint: Color

    var body: some View {
        Canvas { context, size in
            let sky = Gradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), tint.opacity(0.35), Color(red: 0.03, green: 0.04, blue: 0.09)])
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Distant mountains.
            var hills = Path()
            hills.move(to: CGPoint(x: 0, y: size.height - 30))
            let peaks: [(CGFloat, CGFloat)] = [(0.08, 52), (0.18, 38), (0.3, 64), (0.44, 44), (0.57, 70), (0.7, 46), (0.83, 60), (0.95, 40), (1.0, 48)]
            for (fx, h) in peaks {
                hills.addLine(to: CGPoint(x: size.width * fx, y: size.height - 30 - h))
            }
            hills.addLine(to: CGPoint(x: size.width, y: size.height))
            hills.addLine(to: CGPoint(x: 0, y: size.height))
            context.fill(hills, with: .color(Color(red: 0.08, green: 0.11, blue: 0.22).opacity(0.9)))

            // Snow: deterministic pixels.
            var seed: UInt32 = 7
            for _ in 0..<38 {
                seed = seed &* 1_103_515_245 &+ 12345
                let x = CGFloat(seed % 1000) / 1000 * size.width
                seed = seed &* 1_103_515_245 &+ 12345
                let y = CGFloat(seed % 1000) / 1000 * (size.height - 34)
                let big = seed % 5 == 0
                context.fill(Path(CGRect(x: x.rounded(), y: y.rounded(), width: big ? 2 : 1, height: big ? 2 : 1)),
                             with: .color(.white.opacity(big ? 0.75 : 0.45)))
            }

            // Stone floor with bricks.
            let floorY = size.height - 22
            context.fill(Path(CGRect(x: 0, y: floorY, width: size.width, height: 22)), with: .color(Color(red: 0.13, green: 0.15, blue: 0.24)))
            context.fill(Path(CGRect(x: 0, y: floorY, width: size.width, height: 2)), with: .color(Arcade.steelLight.opacity(0.7)))
            for row in 0..<3 {
                let y = floorY + 2 + CGFloat(row) * 7
                context.fill(Path(CGRect(x: 0, y: y + 6, width: size.width, height: 1)), with: .color(.black.opacity(0.45)))
                var x: CGFloat = row % 2 == 0 ? 0 : -14
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: 1, height: 6)), with: .color(.black.opacity(0.45)))
                    x += 28
                }
            }
            // Frost on the floor edge.
            context.fill(Path(CGRect(x: 0, y: floorY - 1, width: size.width, height: 1)), with: .color(Arcade.ice.opacity(0.5)))
        }
    }
}

/// Fighting-game health bar with a label above it.
struct HealthBar: View {
    let label: String
    let value: Double
    let color: Color
    var mirrored = false

    var body: some View {
        VStack(alignment: mirrored ? .trailing : .leading, spacing: 2) {
            PixelText(text: label, scale: 1.5, colors: [Arcade.frost], outline: Arcade.night)
            GeometryReader { geo in
                let fill = max(0, min(1, value)) * (geo.size.width - 4)
                ZStack(alignment: mirrored ? .trailing : .leading) {
                    Rectangle().fill(Arcade.night)
                    Rectangle().fill(Arcade.blood.opacity(0.35)).padding(2)
                    Rectangle()
                        .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.35), color, color.mix(with: .black, by: 0.3)], startPoint: .top, endPoint: .bottom))
                        .frame(width: fill)
                        .padding(2)
                    Rectangle().strokeBorder(Arcade.gold, lineWidth: 1)
                }
            }
            .frame(height: 12)
        }
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

// MARK: - Menu bar icon

enum MenuBarArt {
    /// Golem head; template (follows the menu bar) unless a color is given.
    static func image(color: NSColor?) -> NSImage {
        let rows = Frost.head
        let px: CGFloat = 1.25
        let size = NSSize(width: CGFloat(rows[0].count) * px, height: CGFloat(rows.count) * px)
        let image = NSImage(size: size, flipped: true) { _ in
            (color ?? .black).setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px).fill()
                }
            }
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "Subzero"
        return image
    }
}

// MARK: - Ice ball

enum IceBall {
    static let sprite = PixelSprite(rows: [
        "..kkkk..",
        ".kwwlck.",
        "kwlllcbk",
        "kllllbbk",
        "klcllbdk",
        "kcbbbbdk",
        ".kbbddk.",
        "..kkkk..",
    ], palette: Frost.palette)

    /// Flight time of the ball, then how long the impact stays on screen.
    static let flight: TimeInterval = 0.55
    static let impact: TimeInterval = 1.6
    static var total: TimeInterval { flight + impact }
}

/// Plays a throw over the arena: ball from the golem's hand to the target app,
/// then the app freezes in a block of ice (or shatters on a kill).
struct ArenaThrow: View {
    let hit: EnforcementHit
    /// Where the ball leaves the hand, in the arena's coordinates.
    let hand: CGPoint

    var body: some View {
        if hit.kind == .thaw {
            ThawScene(hit: hit)
        } else {
            iceThrow
        }
    }

    private var iceThrow: some View {
        TimelineView(.periodic(from: hit.at, by: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSince(hit.at)
            GeometryReader { geo in
                let target = CGPoint(x: geo.size.width - 31, y: geo.size.height - 40)
                ZStack(alignment: .topLeading) {
                    if t >= 0, t < IceBall.flight {
                        ball(progress: t / IceBall.flight, from: hand, to: target)
                    }
                    if t >= IceBall.flight, t < IceBall.total {
                        ImpactView(hit: hit, elapsed: t - IceBall.flight)
                            .position(target)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func ball(progress p: Double, from a: CGPoint, to b: CGPoint) -> some View {
        let x = a.x + (b.x - a.x) * p
        let arc = -14 * 4 * p * (1 - p)
        let y = a.y + (b.y - a.y) * p + arc
        let spin = Int(p * 8) % 2 == 0
        return ZStack {
            // Frost trail: square crumbs behind the ball.
            ForEach(1..<6) { i in
                let back = Double(i) * 0.045
                let q = max(0, p - back)
                Rectangle()
                    .fill(Arcade.frost.opacity(0.8 - Double(i) * 0.13))
                    .frame(width: CGFloat(6 - i), height: CGFloat(6 - i))
                    .position(x: a.x + (b.x - a.x) * q, y: a.y + (b.y - a.y) * q - 14 * 4 * q * (1 - q) + CGFloat(i % 2 == 0 ? 2 : -2))
            }
            SpriteView(sprite: IceBall.sprite, scale: 3)
                .rotationEffect(.degrees(spin ? 0 : 90))
                .shadow(color: Arcade.ice.opacity(0.9), radius: 6)
                .position(x: x, y: y)
        }
    }
}

/// The struck app: encased in ice, or shattered into red shards.
private struct ImpactView: View {
    let hit: EnforcementHit
    let elapsed: TimeInterval

    var body: some View {
        let fade = elapsed > IceBall.impact - 0.35 ? max(0, (IceBall.impact - elapsed) / 0.35) : 1
        let burst = min(1, elapsed / 0.3)
        ZStack {
            if let kind = hit.kinds.first {
                AppIcon(kind: kind, size: 30)
                    .saturation(hit.shatter ? 0 : 0.25)
                    .opacity(hit.shatter ? max(0, 1 - burst * 1.4) : 1)
            }
            if !hit.shatter {
                // Ice block.
                Chamfer(cut: 5)
                    .fill(LinearGradient(colors: [Arcade.frost.opacity(0.55), Arcade.ice.opacity(0.35), Arcade.iceDeep.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Chamfer(cut: 5).strokeBorder(Arcade.frost, lineWidth: 1.5))
                    .overlay(alignment: .topLeading) {
                        Rectangle().fill(.white.opacity(0.9)).frame(width: 10, height: 2).offset(x: 6, y: 6)
                    }
                    .frame(width: 42 * burst, height: 42 * burst)
            }
            // Shards flying out.
            ForEach(0..<10) { i in
                let angle = Double(i) / 10 * 2 * .pi + 0.3
                let dist = 6 + 30 * burst
                Rectangle()
                    .fill(hit.shatter ? (i % 2 == 0 ? Arcade.blood : Arcade.ember) : (i % 2 == 0 ? Arcade.frost : Arcade.ice))
                    .frame(width: i % 3 == 0 ? 4 : 3, height: i % 3 == 0 ? 4 : 3)
                    .offset(x: cos(angle) * dist, y: sin(angle) * dist + elapsed * 18)
                    .opacity(max(0, 1 - elapsed / 0.9))
            }
            if hit.shatter {
                PixelText(text: "K.O.", scale: 2, colors: [Color.white, Arcade.ember, Arcade.blood])
                    .offset(x: -6, y: -30 - min(6, elapsed * 12))
            }
        }
        .opacity(fade)
    }
}

/// Segmented countdown bar (fills from the left, one block per segment).
struct SegmentBar: View {
    let value: Double
    var color: Color = Arcade.blood
    var segments = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let on = Double(i) < (max(0, min(1, value)) * Double(segments)).rounded(.up)
                Rectangle()
                    .fill(on ? AnyShapeStyle(LinearGradient(colors: [color.mix(with: .white, by: 0.3), color], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Arcade.night))
            }
        }
        .padding(2)
        .frame(height: 12)
        .background(Arcade.night)
        .overlay(Rectangle().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Fire spirit and thaw

extension EnforcementHit {
    /// How long the scene for this hit stays on screen.
    var duration: TimeInterval { kind == .thaw ? Thaw.total : IceBall.total }
}

/// Ember: an original fire spirit that comes in to melt the ice when apps are released.
enum Ember {
    static let palette: [Character: Color] = [
        "k": Color(red: 0.10, green: 0.03, blue: 0.02),
        "r": Color(red: 0.54, green: 0.10, blue: 0.06),
        "o": Color(red: 0.88, green: 0.33, blue: 0.10),
        "y": Color(red: 1.0, green: 0.71, blue: 0.18),
        "w": Color(red: 1.0, green: 0.95, blue: 0.69),
        "e": Color.white,
        "s": Color(red: 0.23, green: 0.05, blue: 0.03),
        "p": Color(red: 0.16, green: 0.04, blue: 0.02),
    ]

    static let idle = PixelSprite(rows: [
        ".........kyk.kyk..k.........",
        ".........kykkyoykkyk........",
        "........kyoykywrkyoyk.......",
        "........kywrkyorkywrk.......",
        "........kyrrkyrrkyrrk.......",
        "........kkkkokkkokkkk.......",
        ".......kyoooooooooooyk......",
        ".......kywooooooooowrk......",
        ".......kyooooooooooork......",
        ".......kyosssssssssork......",
        ".......kyoseessseesork......",
        ".......kyospessspesork......",
        ".......kyosssssssssork......",
        ".......kyossyyyyyssork......",
        "......kkkkkooooooooork......",
        ".....kyyyyykrrrrrrrrrk......",
        ".....kyooorkkkykkkkkkyk.....",
        ".....kyooorkoywyoorkork.....",
        ".....kyooorkooyooorkork.....",
        ".....kyooorkoooooorkooyk....",
        "....kyoooorkoooooorkyork....",
        "....kyooorrkoooooorkyrrk....",
        "....kyoorkkooooooorkkkk.....",
        "....kyrrrkyrrrrrrrrk........",
        ".....kkkk.kkkykkkkk.........",
        "..........kyooooork.........",
        "...........kyooork..........",
        "...........kyoyork..........",
        "...........kyroork..........",
        "............kkyork..........",
        ".............kyyrk..........",
        "..............kkyyk.........",
        "...............kyrk.........",
        "................kk..........",
    ], palette: palette)

    static let toss = PixelSprite(rows: [
        ".........kyk.kyk..k.........",
        ".........kykkyoykkyk........",
        "........kyoykywrkyoyk.......",
        "........kywrkyorkywrk.......",
        "........kyrrkyrrkyrrk.......",
        "........kkkkokkkokkkk.......",
        ".......kyoooooooooooyk......",
        ".......kywooooooooowrk......",
        ".......kyooooooooooork......",
        ".......kyosssssssssork......",
        ".......kyoseessseesork......",
        ".......kyospessspesork......",
        "kkkkk..kyosssssssssork......",
        "yyyyyk.kyossyyyyyssork......",
        "ywoorkkkkkkooooooooork......",
        "yoworkyyyyykrrrrrrrrrk......",
        "yooorkoooorkkkykkkkkkyk.....",
        "yooorkoooorkoywyoorkork.....",
        "yrrrrkrrrrrkooyooorkork.....",
        "kkkkkkkkkkkooooooorkooyk....",
        ".........kyooooooorkyork....",
        ".........kyooooooorkyrrk....",
        ".........kyooooooorkkkk.....",
        ".........kyrrrrrrrrk........",
        "..........kkkykkkkk.........",
        "..........kyooooork.........",
        "...........kyooork..........",
        "...........kyoyork..........",
        "...........kyroork..........",
        "............kkyork..........",
        ".............kyyrk..........",
        "..............kkyyk.........",
        "...............kyrk.........",
        "................kk..........",
    ], palette: palette)

    static let fireball = PixelSprite(rows: [
        "..kkkk..",
        ".kwwyok.",
        "kwyyyork",
        "kyyyyrrk",
        "kyoyyrrk",
        "koooorrk",
        ".korrrk.",
        "..kkkk..",
    ], palette: palette)
}

enum Thaw {
    static let enter: TimeInterval = 0.35
    static let flight: TimeInterval = 0.4
    static let melt: TimeInterval = 1.2
    static let exit: TimeInterval = 0.45
    static var total: TimeInterval { enter + flight + melt + exit }
}

/// Ember flies in, throws a fireball at the frozen app and the ice melts away.
private struct ThawScene: View {
    let hit: EnforcementHit

    var body: some View {
        TimelineView(.periodic(from: hit.at, by: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSince(hit.at)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let target = CGPoint(x: (w * 0.58).rounded(), y: h - 44)
                let restX = w - 44
                let spiritY = h - 66
                let throwAt = Thaw.enter
                let hitAt = throwAt + Thaw.flight
                let leaveAt = hitAt + Thaw.melt
                let x: CGFloat = t < throwAt
                    ? restX + (w + 50 - restX) * CGFloat(1 - ease(t / Thaw.enter))
                    : (t < leaveAt ? restX : restX + (w + 50 - restX) * CGFloat(ease((t - leaveAt) / Thaw.exit)))
                let hover = (Int(t / 0.25) % 2 == 0) ? 0 : CGFloat(3)
                let hand = CGPoint(x: x - 42 + 3, y: spiritY - 51 + 45 + hover)
                ZStack(alignment: .topLeading) {
                    // The frozen app, then the melt.
                    if t < Thaw.total {
                        MeltView(kind: hit.kinds.first, melt: max(0, min(1, (t - hitAt) / Thaw.melt)), elapsed: t - hitAt)
                            .opacity(t > leaveAt ? max(0, 1 - (t - leaveAt) / Thaw.exit) : 1)
                            .position(target)
                    }
                    if t >= throwAt, t < hitAt {
                        fireball(progress: (t - throwAt) / Thaw.flight, from: hand, to: target)
                    }
                    if t >= 0, t < Thaw.total {
                        SpriteView(sprite: t >= throwAt - 0.05 && t < hitAt + 0.25 ? Ember.toss : Ember.idle, scale: 3)
                            .shadow(color: Arcade.ember.opacity(0.8), radius: 8)
                            .position(x: x, y: spiritY + hover)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func ease(_ p: Double) -> Double {
        let c = max(0, min(1, p))
        return 1 - (1 - c) * (1 - c)
    }

    private func fireball(progress p: Double, from a: CGPoint, to b: CGPoint) -> some View {
        let x = a.x + (b.x - a.x) * p
        let y = a.y + (b.y - a.y) * p - 10 * 4 * p * (1 - p)
        return ZStack {
            ForEach(1..<6) { i in
                let q = max(0, p - Double(i) * 0.05)
                Rectangle()
                    .fill((i % 2 == 0 ? Arcade.gold : Arcade.ember).opacity(0.85 - Double(i) * 0.14))
                    .frame(width: CGFloat(7 - i), height: CGFloat(7 - i))
                    .position(x: a.x + (b.x - a.x) * q, y: a.y + (b.y - a.y) * q - 10 * 4 * q * (1 - q) + CGFloat(i % 2 == 0 ? -2 : 2))
            }
            SpriteView(sprite: Ember.fireball, scale: 3)
                .rotationEffect(.degrees(Int(p * 8) % 2 == 0 ? 0 : 90))
                .shadow(color: Arcade.ember, radius: 7)
                .position(x: x, y: y)
        }
    }
}

/// App in a block of ice that melts from the top: drips, steam and sparks.
private struct MeltView: View {
    let kind: AppRuleKind?
    /// 0 = solid ice, 1 = fully melted.
    let melt: Double
    /// Seconds since the fireball hit (negative before it).
    let elapsed: TimeInterval

    var body: some View {
        let ice = 1 - melt
        ZStack {
            if let kind {
                AppIcon(kind: kind, size: 30)
                    .saturation(0.25 + 0.75 * melt)
            }
            if ice > 0 {
                Chamfer(cut: 5)
                    .fill(LinearGradient(colors: [Arcade.frost.opacity(0.55), Arcade.ice.opacity(0.35), Arcade.iceDeep.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Chamfer(cut: 5).strokeBorder(Arcade.frost, lineWidth: 1.5))
                    .frame(width: 42, height: max(4, 42 * ice))
                    .frame(height: 42, alignment: .bottom)
            }
            if elapsed >= 0 {
                // Drips falling off the block.
                ForEach(0..<6) { i in
                    let phase = (elapsed * 1.6 + Double(i) * 0.17).truncatingRemainder(dividingBy: 1)
                    Rectangle()
                        .fill(Arcade.ice)
                        .frame(width: 2, height: 4)
                        .offset(x: CGFloat(i * 7 - 18), y: 21 + CGFloat(phase * 12))
                        .opacity(melt < 1 ? 0.9 * (1 - phase) : 0)
                }
                // Steam rising.
                ForEach(0..<5) { i in
                    let phase = (elapsed * 0.9 + Double(i) * 0.21).truncatingRemainder(dividingBy: 1)
                    Rectangle()
                        .fill(.white.opacity(0.55 * (1 - phase)))
                        .frame(width: CGFloat(3 + i % 3), height: CGFloat(3 + i % 3))
                        .offset(x: CGFloat(i * 8 - 16) + CGFloat(sin(phase * 6 + Double(i)) * 3), y: -20 - CGFloat(phase * 26))
                }
                // Sparks from the impact.
                ForEach(0..<8) { i in
                    let angle = Double(i) / 8 * 2 * .pi
                    let d = 8 + 26 * min(1, elapsed / 0.35)
                    Rectangle()
                        .fill(i % 2 == 0 ? Arcade.gold : Arcade.ember)
                        .frame(width: 3, height: 3)
                        .offset(x: cos(angle) * d, y: sin(angle) * d)
                        .opacity(max(0, 1 - elapsed / 0.6))
                }
                PixelText(text: "THAW!", scale: 2, colors: [Color.white, Arcade.gold, Arcade.ember])
                    .offset(y: -36 - min(6, elapsed * 10))
                    .opacity(min(1, elapsed / 0.15))
            }
        }
    }
}
