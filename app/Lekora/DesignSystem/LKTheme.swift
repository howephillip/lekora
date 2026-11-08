import SwiftUI

/// Lekora design tokens. Change the look of the whole app here.
///
/// Liquid Glass follows Apple's guidance: glass is for the *control layer* that floats
/// above content (input bar, buttons, badges, toolbars). Content itself (message
/// bubbles, cards) uses solid surface tiers so it stays calm and legible.
public enum LK {

    // MARK: Colour

    public enum Palette {
        /// Brand tint: prominent buttons, the user's bubbles, highlights. iMessage-style system blue.
        public static let accent = Color.blue
        /// Text and symbols drawn on top of `accent`.
        public static let onAccent = Color.white

        public static let success = Color.green
        public static let warning = Color.orange
        public static let danger = Color.red
    }

    /// Surface tiers for content, from the screen background upwards. All adapt to dark mode.
    public enum Surface {
        /// The screen itself (see `lkScreenBackground()`).
        public static let base = AnyShapeStyle(.background)
        /// Cards and grouped content sitting on the screen.
        public static let raised = AnyShapeStyle(.background.secondary)
        /// Agent message bubbles and inset fields.
        public static let inset = AnyShapeStyle(.fill.tertiary)
        /// The user's own message bubbles (solid, like iMessage).
        public static let accent = AnyShapeStyle(Palette.accent)
    }

    /// Liquid Glass presets for controls.
    public enum Glass {
        /// Floating bars and badges.
        public static let bar = SwiftUI.Glass.regular
        /// Things you touch: the composer field, custom tappable chips.
        public static let control = SwiftUI.Glass.regular.interactive()
    }

    // MARK: Typography

    /// Semantic text styles. All scale with Dynamic Type.
    public enum Typography {
        public static let largeTitle = Font.largeTitle.weight(.bold)
        public static let title = Font.title2.weight(.semibold)
        public static let headline = Font.headline
        public static let body = Font.body
        public static let callout = Font.callout
        public static let caption = Font.caption
        public static let captionStrong = Font.caption.weight(.semibold)
        public static let footnote = Font.footnote
        /// Commands the user types on the Hermes machine.
        public static let code = Font.callout.monospaced()
    }

    // MARK: Layout

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let small: CGFloat = 10
        public static let bubble: CGFloat = 20
        public static let card: CGFloat = 22
        public static let field: CGFloat = 22
    }

    public enum Size {
        /// Bubbles never span the full width, so the other side stays visibly "the other side".
        public static let bubbleSideMargin: CGFloat = 48
        public static let statusDot: CGFloat = 8
        public static let heroIcon: CGFloat = 44
    }
}
