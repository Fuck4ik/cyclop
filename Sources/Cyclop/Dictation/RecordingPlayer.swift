import AppKit

/// Plays back one recording at a time, and says which one.
///
/// A class rather than two lines inside the controller because `NSSound` needs
/// both things a fire-and-forget call cannot give it: someone to hold it for
/// the length of playback, and a delegate to hear that playback ended. Without
/// the first there is nothing to stop; without the second the button would go
/// on offering to stop a sound that finished a minute ago.
@MainActor
final class RecordingPlayer: NSObject, NSSoundDelegate {
    /// The file playing right now, by name — the same key history records
    /// carry in `audio`.
    private(set) var playing: String?
    /// Fired whenever `playing` changes, including when a sound ends on its
    /// own: SwiftUI has nothing else to learn that from.
    var onChange: (() -> Void)?

    private var sound: NSSound?

    /// Starts the recording, or stops it if it is the one already playing.
    func toggle(url: URL, id: String) {
        let wasPlaying = playing == id
        stop()
        guard !wasPlaying else { return }
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.delegate = self
        self.sound = sound
        playing = id
        sound.play()
        onChange?()
    }

    func stop() {
        sound?.stop()
        sound = nil
        guard playing != nil else { return }
        playing = nil
        onChange?()
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        Task { @MainActor [weak self] in
            // Only if this is still the sound being tracked: a second
            // recording started while the first was fading out would
            // otherwise clear the state belonging to the new one.
            guard let self, self.sound === sound else { return }
            self.sound = nil
            self.playing = nil
            self.onChange?()
        }
    }
}
