import SwiftUI

// MARK: - Browser-style window chrome
//
// The top band is the SYSTEM toolbar, not a painted imitation of one: native
// buttons in native item groups, so macOS draws the same grouped capsules,
// materials, and press states Safari gets. The app's instrument language
// starts below the chrome, where the app's own content begins.
//
// The one custom part is the middle field, because the thing it reads out is
// this app's own: a browser's address bar says which page you are on, so this
// one says what the agent is doing — and becomes the chat search on click,
// since "somewhere else" here is another conversation.

extension View {
    /// ONE face for every control in the top bar: the system's bordered
    /// button, one symbol size, one footprint. Safari's discipline is that
    /// its toolbar is a single row of identical parts — mixing a labelled
    /// button, a bare glyph, and a menu chevron is what made this band read
    /// as three different products.
    func chromeControl(selected: Bool = false) -> some View {
        labelStyle(.iconOnly)
            .font(.system(size: ChromeBar.glyph, weight: .medium))
            .frame(width: ChromeBar.controlWidth, height: ChromeBar.controlHeight)
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .toolbarSelected(selected)
    }

    /// Marks a control as ON in the system's own vocabulary: filled symbol,
    /// accent tint — what AppKit does for a selected toolbar item. A Toggle
    /// would be the purer form, but it reports as a checkbox to XCUITest and
    /// the UI tests address these as buttons.
    @ViewBuilder
    func toolbarSelected(_ on: Bool) -> some View {
        if on {
            symbolVariant(.fill).foregroundStyle(.tint)
        } else {
            self
        }
    }
}

enum ChromeBar {
    /// Every top-bar control: one glyph size, one footprint.
    static let glyph: CGFloat = 14
    static let controlWidth: CGFloat = 24
    static let controlHeight: CGFloat = 20
    static let fieldHeight: CGFloat = 28
    static let fieldMinWidth: CGFloat = 220
    static let fieldIdealWidth: CGFloat = 460
    static let fieldMaxWidth: CGFloat = 560
}

/// Click-to-search, not a live text field: a TextField hosted in the window
/// toolbar takes first responder at launch and swallows ⌘F, and its caret
/// competes with the composer's. The field opens the search panel, whose own
/// field takes focus — which is what a browser's address bar does when it
/// drops its suggestion list.
struct ChromeAddressField<Idle: View>: View {
    var placeholder: String
    var identifier: String? = nil
    var action: () -> Void
    @ViewBuilder var idle: Idle

    var body: some View {
        // Not a Button: AppKit re-templates a toolbar button's label and drops
        // custom content — wrapping this in one made the whole field vanish
        // from the band. The row carries the tap and the button trait itself.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            idle
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .frame(height: ChromeBar.fieldHeight)
        .frame(minWidth: ChromeBar.fieldMinWidth,
               idealWidth: ChromeBar.fieldIdealWidth,
               maxWidth: ChromeBar.fieldMaxWidth)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(placeholder)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(placeholder)
        .accessibilityIdentifier(identifier ?? "")
        .accessibilityAction(.default, action)
    }
}
