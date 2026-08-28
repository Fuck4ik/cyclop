import Foundation

/// An app extension does not begin at `main`. The system loads the bundle and
/// hands control to `NSExtensionMain`, which reads the principal class out of
/// Info.plist and runs the loop that answers Finder. Xcode arranges this with a
/// linker flag (`-e _NSExtensionMain`) that SwiftPM has no way to pass, so the
/// ordinary entry point calls it instead — same destination, one frame deeper.
///
/// Foundation exports the symbol but declares it in no public header, which is
/// why it is spelled out here rather than imported.
@_silgen_name("NSExtensionMain")
func nsExtensionMain() -> Int32

exit(nsExtensionMain())
