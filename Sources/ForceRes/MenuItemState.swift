/// What the gear menu's "Default Resolution" entry should show. Computed by `AppModel` from pure inputs so
/// it can be unit tested against recorded fixtures without SwiftUI.
struct MenuItemState: Equatable, Sendable {
    /// Full label including any " · reason" suffix.
    var title: String
    /// `false` renders the item greyed out.
    var isEnabled: Bool
    /// `true` shows the checkmark (the display is in the mode Default Resolution would restore).
    var isChecked: Bool
}
