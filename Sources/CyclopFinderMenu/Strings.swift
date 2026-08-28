import Foundation

/// The extension is its own bundle, so `NSLocalizedString` here looks inside
/// the `.appex` and not inside Cyclop.app. `bundle.sh` copies the same `.lproj`
/// folders into both, so a title is still translated in exactly one place.
///
/// Keys are the English text, as everywhere else in this project: a bundle that
/// somehow lost its tables shows English rather than an identifier.
func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
