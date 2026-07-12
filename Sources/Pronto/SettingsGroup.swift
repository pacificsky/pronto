import SwiftUI

/// A titled card of rows for the Settings window's grouped-inset-card look —
/// the hand-laid replacement for `.formStyle(.grouped)`. A grouped `Form` is
/// List-backed and reports no intrinsic height (see `SettingsView`'s history:
/// that forced a fixed window frame). This container is a plain `VStack`, so
/// it sizes to its content and the window can auto-resize per tab again.
///
/// `title` is optional: pass `nil` for a headerless card (e.g. an inline
/// error note) that still gets the card chrome without a section label.
struct SettingsGroup: View {
    private let title: String?
    private let rows: [AnyView]

    init(_ title: String? = nil, @SettingsRowBuilder rows: () -> [AnyView]) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.leading, 16)
                    }
                    rows[index]
                }
            }
            // Outside a List, the card sizes to fit its content by default.
            // Force it to span whatever width the tab offers so every card in
            // a tab (e.g. Coffee Boiler vs. Steam Boiler) lines up uniformly,
            // instead of each hugging its own widest row.
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCardBackground()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Single choke point: every `LabeledContent` row in every card, in
        // all three tabs, gets the List-row label/control split for free.
        .labeledContentStyle(FullWidthLabeledContentStyle())
    }
}

/// One row inside a ``SettingsGroup`` card: arbitrary row content (typically
/// `LabeledContent`, `Toggle`, or a `Picker`) plus optional help text
/// directly beneath it, inside the *same* padded cell — per the design spec,
/// help text sits under its row's content rather than as its own
/// divider-separated row.
struct SettingsRow<Content: View>: View {
    private let help: String?
    private let content: Content

    init(help: String? = nil, @ViewBuilder content: () -> Content) {
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                // Merely proposing more width here isn't enough on its own:
                // `LabeledContent`'s `.automatic` style (and any hand-laid
                // `HStack { label; Spacer(); control }`) only spread label
                // and control to opposite edges once actually *offered* the
                // full row width. This is the one place every row across all
                // three tabs passes through, so it's the single spot that
                // needs the width proposal — the label/control split itself
                // comes from `FullWidthLabeledContentStyle` below (applied
                // once, in ``SettingsGroup``) and `FullWidthToggleStyle`.
                .frame(maxWidth: .infinity, alignment: .leading)
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Makes `LabeledContent` spread its label and content to opposite edges
/// outside a List/Form. `LabeledContentStyle.automatic` only does that
/// *inside* a List/Form; standalone (our hand-laid cards) it just hugs its
/// label + content with a small fixed gap, ignoring however much width its
/// ancestors offer it. An explicit `Spacer` is the only way to get the
/// List-row look back — applied once here via `.labeledContentStyle` (see
/// ``SettingsGroup``) so every `LabeledContent` row in every tab gets it for
/// free, no call-site changes needed.
struct FullWidthLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
            Spacer(minLength: 16)
            configuration.content
        }
    }
}

/// Makes a switch `Toggle` push its label leading / switch trailing outside
/// a List/Form, for the same reason as ``FullWidthLabeledContentStyle``:
/// `.switch` alone hugs its label + control instead of spreading them.
struct FullWidthToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
            Spacer(minLength: 16)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// Builds a `[AnyView]` of ``SettingsRow``s (or any row-shaped view) for
/// ``SettingsGroup``'s initializer, so call sites can freely use `if`/
/// optionals to include/exclude rows — mirroring how `Section` bodies used
/// to allow conditional content.
@resultBuilder
enum SettingsRowBuilder {
    static func buildBlock(_ components: [AnyView]...) -> [AnyView] {
        components.flatMap { $0 }
    }

    static func buildExpression<V: View>(_ expression: V) -> [AnyView] {
        [AnyView(expression)]
    }

    static func buildOptional(_ component: [AnyView]?) -> [AnyView] {
        component ?? []
    }

    static func buildEither(first component: [AnyView]) -> [AnyView] {
        component
    }

    static func buildEither(second component: [AnyView]) -> [AnyView] {
        component
    }

    static func buildArray(_ components: [[AnyView]]) -> [AnyView] {
        components.flatMap { $0 }
    }
}

extension View {
    /// Content padding shared by every Settings tab's outer `VStack`, per the
    /// design's content-area spacing (22pt top / 24pt sides / 18pt bottom).
    func settingsTabPadding() -> some View {
        self
            .padding(.top, 22)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
    }

    /// Card chrome shared by every settings group: adaptive background,
    /// rounded corners, hairline stroke — the design's card token (white
    /// background, 10pt radius, 1pt `rgba(0,0,0,0.06)` border) expressed with
    /// semantic `NSColor`s so it holds up in dark mode instead of a
    /// hard-coded hex.
    func settingsCardBackground() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
