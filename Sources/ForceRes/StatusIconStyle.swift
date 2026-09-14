import ForceResCore

/// Which menu bar glyph to show: the outline normally, the solid glyph while ForceRes is forcing
/// a preset on any connected display.
enum StatusIconStyle: Equatable, Sendable {
    case outline
    case solid

    /// Resource name of the template PNG in `Sources/ForceRes/Resources`.
    var resourceName: String {
        switch self {
        case .outline: "MenuBarIcon"
        case .solid: "MenuBarIcon-Solid"
        }
    }

    /// - Parameters:
    ///   - choices: the saved choice of each connected display (`nil` when none).
    ///   - hasActiveMirror: whether any virtual mirror is active.
    static func resolve(choices: [DisplayChoice?], hasActiveMirror: Bool) -> StatusIconStyle {
        if hasActiveMirror { return .solid }
        return choices.contains { $0?.preset != nil } ? .solid : .outline
    }
}
