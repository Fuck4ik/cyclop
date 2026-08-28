import SwiftUI

/// The "record this call?" card that drops out of the notch.
///
/// Drawn inside the panel rather than as a notification so it reads as Cyclop
/// itself: a system banner would be one more thing to dismiss, and it would
/// appear away from the indicator that follows it.
struct RecordingOffer: View {
    let accept: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.9))
            Text("A call is going on. Record it?")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Button(action: accept) {
                Text("Record")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button(action: dismiss) {
                Text("Not now")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
        .onAppear {
            // The only tactile channel a Mac has: on a MacBook this lands in
            // the trackpad, which is exactly where the hand already is.
            NSHapticFeedbackManager.defaultPerformer.perform(
                .levelChange, performanceTime: .now)
        }
    }
}
