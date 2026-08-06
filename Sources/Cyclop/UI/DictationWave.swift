import SwiftUI

/// The strip of light under the notch while dictation is running.
///
/// Three sine waves of different speed and wavelength, summed and drawn on top
/// of each other. One wave reads as a test signal; three drifting against each
/// other never repeat the same shape, which is what makes the thing look alive
/// rather than looped.
///
/// Amplitude comes from the microphone while recording, so the strip answers
/// the voice — that is the whole point of showing it. There is no microphone
/// left to answer during transcription, so the wave keeps its own slow pulse
/// and changes colour instead: ocean while it listens, ember while it thinks.
struct DictationWave: View {
    enum Mood {
        case listening
        case thinking

        /// Left-to-right colours. Three stops rather than two: a straight
        /// two-colour ramp reads as a gradient swatch, a third stop off the
        /// line between them reads as light.
        var colors: [Color] {
            switch self {
            case .listening:
                return [
                    Color(red: 0.16, green: 0.72, blue: 1.00),
                    Color(red: 0.30, green: 0.94, blue: 0.85),
                    Color(red: 0.20, green: 0.55, blue: 1.00),
                ]
            case .thinking:
                return [
                    Color(red: 1.00, green: 0.78, blue: 0.22),
                    Color(red: 1.00, green: 0.45, blue: 0.12),
                    Color(red: 1.00, green: 0.24, blue: 0.35),
                ]
            }
        }

        /// How fast the waves travel. Listening is brisk, thinking is a slower
        /// swell — the difference is legible without reading any text.
        var speed: Double {
            switch self {
            case .listening: return 1.0
            case .thinking: return 0.55
            }
        }
    }

    var mood: Mood
    /// Read per frame, not passed by value: the level changes with every audio
    /// buffer, and a stored `Float` would only be refreshed when SwiftUI
    /// happened to rebuild this view — which is never during a take, since
    /// nothing else about it changes. The wave would then hold one amplitude
    /// for the whole recording, which is exactly the lifelessness it exists to
    /// avoid.
    var level: () -> Float

    /// Wavelength, speed and phase per wave. Deliberately not multiples of each
    /// other, so the sum has no short repeat.
    private let waves: [(length: Double, speed: Double, phase: Double, weight: Double)] = [
        (length: 1.0, speed: 1.00, phase: 0.0, weight: 1.00),
        (length: 1.7, speed: -0.62, phase: 1.3, weight: 0.62),
        (length: 0.55, speed: 1.45, phase: 2.7, weight: 0.34),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate * mood.speed
                let amplitude = self.amplitude(for: size.height)
                let gradient = Gradient(colors: mood.colors)

                // Glow first, sharp line on top: the blurred copy alone looks
                // like a smudge, the sharp line alone like a wire.
                var glow = context
                glow.addFilter(.blur(radius: size.height * 0.42))
                glow.opacity = 0.75
                glow.stroke(
                    path(in: size, time: time, amplitude: amplitude * 1.05),
                    with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                    lineWidth: size.height * 0.34
                )

                context.stroke(
                    path(in: size, time: time, amplitude: amplitude),
                    with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// Rest height plus what the voice adds. Never zero: a strip that flattens
    /// completely between words looks broken rather than quiet.
    private func amplitude(for height: CGFloat) -> Double {
        let rest = height * 0.10
        switch mood {
        case .listening:
            let eased = pow(Double(max(0, min(1, level()))), 0.7)
            return rest + (height * 0.38 - rest) * eased
        case .thinking:
            return height * 0.22
        }
    }

    private func path(in size: CGSize, time: Double, amplitude: Double) -> Path {
        var path = Path()
        let midY = size.height / 2
        // One point per pixel is more than the curve needs and costs redraws on
        // a 120 Hz display; every third is indistinguishable at this height.
        let step: CGFloat = 3

        var x: CGFloat = 0
        while x <= size.width {
            let progress = Double(x / size.width)
            var y = 0.0
            for wave in waves {
                let angle = (progress / wave.length) * 2 * .pi * 3 + time * wave.speed * 2.4 + wave.phase
                y += sin(angle) * wave.weight
            }
            // Taper to nothing at both ends, so the strip has no cut-off edges
            // and reads as light rather than as a drawn object.
            let envelope = sin(progress * .pi)
            let point = CGPoint(x: x, y: midY + y * amplitude * envelope * 0.5)
            if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
            x += step
        }
        return path
    }
}
