import SwiftUI
import AppKit

/// Design tokens and Liquid Glass surfaces.
///
/// Every colour, radius and spacing value in the editor resolves here so the SwiftUI chrome and the
/// Core Graphics timeline cannot drift apart. Glass is applied through `jhSurface`, which degrades in
/// two steps: Liquid Glass on macOS 26, `Material` on macOS 14–15, and a flat fill whenever the user
/// asks for reduced transparency or increased contrast.
enum JH {

    // MARK: Metrics

    /// 4pt grid. Panels and bars only ever use these.
    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Concentric radii: a control inside a panel uses the next step down so the curves stay parallel.
    enum Radius {
        static let chip: CGFloat = 7
        static let control: CGFloat = 10
        static let panel: CGFloat = 16
        static let window: CGFloat = 22
        /// A child inset by `inset` inside a `parent`-radius container.
        static func concentric(in parent: CGFloat, inset: CGFloat) -> CGFloat { max(chip - 3, parent - inset) }
    }

    enum Stroke {
        static let hairline: CGFloat = 1 / 2
        static let focus: CGFloat = 2
    }

    // MARK: Type

    /// Numbers always use monospaced digits so timecode and durations do not jitter.
    enum Font {
        static let sectionTitle = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let rowTitle = SwiftUI.Font.system(size: 12, weight: .medium)
        static let label = SwiftUI.Font.system(size: 11)
        static let caption = SwiftUI.Font.system(size: 10)
        static let micro = SwiftUI.Font.system(size: 9)
        static let control = SwiftUI.Font.system(size: 11, weight: .medium)
        static func numeric(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight).monospacedDigit()
        }
        static let timecode = SwiftUI.Font.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()
        static let wordmark = SwiftUI.Font.system(size: 15, weight: .bold, design: .rounded)
    }

    // MARK: Colour

    enum Palette {
        /// Behind every glass surface. Deep and neutral so glass picks up real contrast.
        static let canvas = Color(nsColor: NSColor(calibratedWhite: 0.055, alpha: 1))
        /// Flat substitute used when transparency is reduced.
        static let surface = Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1))
        static let surfaceRaised = Color(nsColor: NSColor(calibratedWhite: 0.155, alpha: 1))
        static let hairline = Color.white.opacity(0.09)
        static let accent = Color(nsColor: accentNS)
        static let accentNS = NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.74, alpha: 1)
        static let playhead = Color(nsColor: playheadNS)
        static let playheadNS = NSColor(calibratedRed: 0.98, green: 0.41, blue: 0.35, alpha: 1)
        static let warning = Color(nsColor: NSColor(calibratedRed: 0.99, green: 0.67, blue: 0.25, alpha: 1))

        /// Track identity. Shared by the timeline canvas and every SwiftUI badge that names a track.
        static func track(_ kind: TrackPalette) -> Color { Color(nsColor: trackNS(kind)) }
        static func trackNS(_ kind: TrackPalette) -> NSColor {
            switch kind {
            case .video: return NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.78, alpha: 1)
            case .overlay: return NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.82, alpha: 1)
            case .title: return NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.24, alpha: 1)
            case .audio: return NSColor(calibratedRed: 0.20, green: 0.63, blue: 0.51, alpha: 1)
            }
        }
    }

    /// Mirrors `TrackKind` without importing the core module into the token layer.
    enum TrackPalette { case video, overlay, title, audio }

    // MARK: Surfaces

    /// How prominent a glass surface should read against the canvas.
    enum Surface {
        /// Sidebars and the timeline shell.
        case panel
        /// Toolbars and status bars that sit flush against an edge.
        case bar
        /// Controls that float over video, where glass is most visible.
        case floating
        /// The one accented surface per screen, for the primary action.
        case accented

        var fallbackMaterial: Material {
            switch self {
            case .panel: return .regularMaterial
            case .bar: return .bar
            case .floating: return .ultraThinMaterial
            case .accented: return .regularMaterial
            }
        }
        var flatFill: Color {
            switch self {
            case .panel: return Palette.surface
            case .bar: return Palette.surface
            case .floating: return Palette.surfaceRaised
            case .accented: return Palette.accent.opacity(0.9)
            }
        }
    }
}

/// Applies a Liquid Glass surface, stepping down to `Material` and then to a flat fill.
private struct JHSurfaceModifier<S: Shape>: ViewModifier {
    let surface: JH.Surface
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(surface.flatFill, in: shape)
                .overlay(shape.stroke(JH.Palette.hairline, lineWidth: JH.Stroke.hairline))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(surface.fallbackMaterial, in: shape)
                .overlay(shape.stroke(JH.Palette.hairline, lineWidth: JH.Stroke.hairline))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        // Clear glass over video: the frame stays readable through the controls, which is the whole
        // point of floating them there. Chrome away from the image uses regular glass.
        var value: Glass = surface == .floating ? .clear : .regular
        if surface == .accented { value = value.tint(JH.Palette.accent) }
        if interactive { value = value.interactive() }
        return value
    }
}

extension View {
    /// The single entry point for a glass surface. `shape` drives the concentric radius.
    func jhSurface<S: Shape>(_ surface: JH.Surface, in shape: S, interactive: Bool = false) -> some View {
        modifier(JHSurfaceModifier(surface: surface, shape: shape, interactive: interactive))
    }
    func jhSurface(_ surface: JH.Surface, radius: CGFloat = JH.Radius.panel, interactive: Bool = false) -> some View {
        jhSurface(surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: interactive)
    }

    /// A hairline that reads as a seam between surfaces rather than a drawn line.
    func jhSeam(_ edge: Edge) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle().fill(JH.Palette.hairline)
                .frame(width: edge == .leading || edge == .trailing ? JH.Stroke.hairline : nil,
                       height: edge == .top || edge == .bottom ? JH.Stroke.hairline : nil)
        }
    }

    /// Icon-only controls are invisible to VoiceOver without this; `help` alone is not an a11y label.
    func jhIconLabel(_ label: String, hint: String? = nil) -> some View {
        accessibilityLabel(Text(label))
            .accessibilityHint(hint.map(Text.init) ?? Text(""))
            .help(hint ?? label)
    }
}

private extension Edge {
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

/// Primary action button. Uses the real Liquid Glass prominent style where it exists.
struct JHPrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label.fontWeight(.semibold) }
                .buttonStyle(.glassProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label.fontWeight(.semibold) }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Secondary control in a toolbar or panel. The window-wide accent tint is cleared here: glass adopts
/// the tint and every secondary button would otherwise read as loud as the primary action.
struct JHToolButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glass)
                .tint(nil)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.bordered)
                .tint(nil)
        }
    }
}

extension PrimitiveButtonStyle where Self == JHPrimaryButtonStyle {
    static var jhPrimary: JHPrimaryButtonStyle { JHPrimaryButtonStyle() }
}
extension PrimitiveButtonStyle where Self == JHToolButtonStyle {
    static var jhTool: JHToolButtonStyle { JHToolButtonStyle() }
}
