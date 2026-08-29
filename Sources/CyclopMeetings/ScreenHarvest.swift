import Foundation

/// Which of the model's notes have earned a block in the transcript.
///
/// A note earns one only when a frame of its own was actually captured. The
/// document renders every kept note as a picture, so a note whose timecode the
/// model shifted by a second would point at a file nobody wrote — a broken
/// image in the finished file. The same guard drops a timecode the model
/// described twice.
public enum ScreenHarvest {
    public static func renderable(
        _ notes: [ScreenNote], captured: Set<TimeInterval>
    ) -> [ScreenNote] {
        var seen = Set<TimeInterval>()
        return notes.filter { note in
            note.isUseful && captured.contains(note.start) && seen.insert(note.start).inserted
        }
    }
}
