import Foundation

/// Turns a Finder selection into the text that goes on the pasteboard.
///
/// Lives apart from the extension for the same reason `CyclopDictation` lives
/// apart from the app: SwiftPM cannot import an executable target into tests,
/// and an app extension is an executable. Everything here is pure, so the part
/// worth checking — spaces, Cyrillic, one line per item — is covered without
/// Finder in the loop.
public enum FinderPathText {
    /// One absolute POSIX path per line, in the order Finder handed them over.
    ///
    /// An empty selection gives an empty string rather than a blank line: the
    /// caller uses that to leave the pasteboard alone instead of wiping it.
    public static func lines(for urls: [URL]) -> String {
        paths(for: urls).joined(separator: "\n")
    }

    /// The paths themselves, before they are joined.
    ///
    /// `path(percentEncoded: false)` is what does the work: it hands back the
    /// file-system path, so neither the `file://` scheme nor the percent
    /// escapes Finder puts in a URL ever reach the pasteboard, and a name with
    /// a space, a Cyrillic letter or an emoji comes out the way it is written
    /// on disk.
    ///
    /// Deliberately not normalised to NFC. The bytes Finder gives are the bytes
    /// the volume stores — decomposed on HFS+, as-written on APFS — and a path
    /// pasted into a shell has to match them. Tidying the Unicode here would
    /// produce a prettier string that finds no file.
    public static func paths(for urls: [URL]) -> [String] {
        urls.compactMap { url in
            // Everything Finder shows sits on a mounted volume, so anything
            // that is not a file URL is not something a POSIX path describes.
            guard url.isFileURL else { return nil }
            return withoutTrailingSlash(url.path(percentEncoded: false))
        }
    }

    /// A folder arrives as a URL ending in a slash, and a path that ends in one
    /// is not what anyone means by "the path of this folder": it is not what
    /// `pwd` prints and it reads wrong the moment it is pasted after a command.
    /// Root is the exception — there the slash is the whole path.
    private static func withoutTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
