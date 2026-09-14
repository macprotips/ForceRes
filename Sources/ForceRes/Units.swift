import Foundation

/// The one unit vocabulary of every user-facing string.
enum Units {
    /// "120 Hertz" (whole Hz; 59.94 rounds to 60), matching System Settings' spelling.
    static func hertz(_ hertz: Int) -> String { "\(hertz) Hertz" }
}
