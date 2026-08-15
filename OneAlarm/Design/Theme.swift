import SwiftUI

/// The design system, ported from `design/prototype.html`.
///
/// Two brands, fused on one rule. Eight Sleep's colour is continuous, a position on a ramp. Whoop's
/// is discrete, seven flat accents each meaning one thing. On one screen they destroy each other: a
/// colour halfway along a ramp is none of Whoop's meanings, and flat accents turn a gradient into
/// decoration. So each gets one job.
///
/// **The gradient encodes time. The flat accents encode state. There is one gradient in the app.**
///
/// Corollary, easy to walk into given this thing controls a heated bed: because the gradient means
/// time, it may never also mean temperature. Temperature would be a number, never a hue.
enum Theme {

    // MARK: Colour

    /// Whoop's method, Eight Sleep's hue. Whoop's app ground is not black, it is a subtle vertical
    /// charcoal gradient; this is that, shifted navy.
    enum Ground {
        static let top = Color(hex: 0x101A2B)
        static let bottom = Color(hex: 0x05070C)

        static var gradient: LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: top, location: 0),
                    .init(color: bottom, location: 0.46),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    static let card = Color(hex: 0x0D1119)
    static let cardLift = Color(hex: 0x161C28)
    static let line = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.18)

    /// Whoop's official text greys.
    static let grey = Color(hex: 0xB8C0C3)
    static let greyDim = Color(hex: 0x7F898D)

    /// Discrete state only. Whoop's official values, so they are known good on a dark ground.
    /// These never appear on the cascade.
    enum State {
        static let confirmed = Color(hex: 0x00F19F)   // Whoop teal
        static let unconfirmed = Color(hex: 0xFFDE00) // Whoop medium recovery
        static let failed = Color(hex: 0xFF0026)      // Whoop low recovery
        static let target = Color(hex: 0x7BA1BB)      // Whoop sleep blue
    }

    /// The cascade ramp: dawn, which is what Eight Sleep's gradient meant in their first identity
    /// before it ever meant temperature.
    ///
    /// The periwinkle midpoint is load bearing. A straight blue to orange ramp muddies through grey
    /// and reads as a weather map.
    enum Ramp {
        static let coolLit = Color(hex: 0x2E7FD4)
        static let coolDeep = Color(hex: 0x0A1F38)
        static let midLit = Color(hex: 0x6E74D8)
        static let midDeep = Color(hex: 0x16172E)
        static let warmLit = Color(hex: 0xF4643C)
        static let warmDeep = Color(hex: 0x2E0E10)

        static func lit(for device: DeviceID) -> Color {
            switch device {
            case .eightSleep: return coolLit
            case .whoop: return midLit
            case .iphone: return warmLit
            }
        }

        static func deep(for device: DeviceID) -> Color {
            switch device {
            case .eightSleep: return coolDeep
            case .whoop: return midDeep
            case .iphone: return warmDeep
            }
        }

        /// The card wash. Light end bleeds in from the leading edge, as Eight Sleep's Nap and Rapid
        /// Cooling cards do.
        static func card(for device: DeviceID) -> LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: lit(for: device), location: -0.25),
                    .init(color: deep(for: device), location: 0.62),
                    .init(color: Ground.bottom, location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }

        /// The whole dawn, top to bottom. Used on the one continuous rail.
        static var full: LinearGradient {
            LinearGradient(colors: [coolLit, midLit, warmLit], startPoint: .top, endPoint: .bottom)
        }

        static func rail(for device: DeviceID) -> LinearGradient {
            LinearGradient(colors: [lit(for: device), deep(for: device)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: Type

    /// Whoop's rule is two typefaces: one for words, a rigid engineering face for numbers, so data
    /// reads as data before you read it. Theirs is DINPro, which is commercial.
    ///
    /// **DIN Alternate ships with iOS.** So the numerals are a real DIN, on device, with no bundled
    /// font and no licence.
    static func numeral(_ size: CGFloat) -> Font {
        .custom("DINAlternate-Bold", size: size)
            .monospacedDigit()
    }

    /// Whoop's most identifiable move: small, uppercase, wide tracking, grey.
    struct Label: ViewModifier {
        var color: Color = Theme.grey
        func body(content: Content) -> some View {
            content
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.65)
                .textCase(.uppercase)
                .foregroundStyle(color)
        }
    }

    // MARK: Shape

    /// Eight Sleep generosity on the hero cards, Whoop tightness on rows.
    static let radiusCard: CGFloat = 18
    static let radiusRow: CGFloat = 13
    static let gutter: CGFloat = 22
}

extension View {
    func themeLabel(_ color: Color = Theme.grey) -> some View {
        modifier(Theme.Label(color: color))
    }

    /// Standard card: near black, hairline border, generous radius.
    func themeCard(radius: CGFloat = Theme.radiusCard) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
