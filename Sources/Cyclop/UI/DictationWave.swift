import SwiftUI

/// The light that spills out of the notch while dictation is running.
///
/// Not a row of wave crests — a bloom of light: bright core, soft halo, the
/// shape a voice assistant uses when it is listening rather than speaking.
///
/// The canvas is deliberately much larger than the light drawn in it. A
/// `Canvas` clips to its own bounds, and a blurred glow that reaches the edge
/// is cut off there — a hard horizontal line across the haze, which is the one
/// thing a glow must never have. Everything below is sized so the faintest part
/// of the halo still falls inside.
///
/// It grows with the voice while recording, because that is the only feedback
/// that says "you are being heard". There is no microphone left to answer
/// during transcription, so it keeps a slow breath of its own and changes
/// colour instead: ocean while listening, ember while thinking.
struct DictationWave: View {
    enum Mood {
        case listening
        case thinking

        /// Centre outwards: a near-white core is what makes a glow look like a
        /// light source rather than a coloured shape.
        var core: Color {
            switch self {
            case .listening: return Color(red: 0.86, green: 0.97, blue: 1.00)
            case .thinking: return Color(red: 1.00, green: 0.94, blue: 0.82)
            }
        }

        var mid: Color {
            switch self {
            case .listening: return Color(red: 0.18, green: 0.66, blue: 1.00)
            case .thinking: return Color(red: 1.00, green: 0.50, blue: 0.11)
            }
        }

        var edge: Color {
            switch self {
            case .listening: return Color(red: 0.09, green: 0.28, blue: 0.98)
            case .thinking: return Color(red: 0.96, green: 0.16, blue: 0.22)
            }
        }

        /// Listening is brisk, thinking is a slower swell — legible without
        /// reading a word of text.
        var speed: Double {
            switch self {
            case .listening: return 1.0
            case .thinking: return 0.5
            }
        }
    }

    var mood: Mood
    /// Read per frame, not passed by value: the level changes with every audio
    /// buffer, and a stored `Float` would only refresh when SwiftUI happened to
    /// rebuild this view — which is never during a take, since nothing else
    /// about it changes. The light would then hold one size for the whole
    /// recording, which is exactly the lifelessness it exists to avoid.
    var level: () -> Float

    /// Where the light sits inside the canvas, measured from the top. Above it
    /// is the notch's own black body; below is the room the halo needs.
    static let coreInset: CGFloat = 26

    /// Three blooms rather than one. A single ellipse pulses; three of
    /// different size drifting at different speeds never line up the same way
    /// twice, which is what reads as alive. Offsets are fractions of the lit
    /// width, so they spread as the voice gets louder.
    private let blooms: [(offset: Double, scale: Double, drift: Double, phase: Double)] = [
        (offset: 0.00, scale: 1.00, drift: 0.9, phase: 0.0),
        (offset: -0.26, scale: 0.62, drift: -1.4, phase: 2.1),
        (offset: 0.24, scale: 0.55, drift: 1.7, phase: 4.3),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate * mood.speed
                let loudness = self.loudness(at: time)
                let centerY = Self.coreInset
                let gradient = self.gradient

                // Breathing under the voice, so the light never sits perfectly
                // still even in the pause between two words.
                let breath = 0.90 + 0.10 * sin(time * 2.1)
                let width = size.width * (0.30 + 0.62 * loudness) * breath
                let height = (4 + 34 * loudness) * breath

                // The haze: very wide, very faint, blurred past recognition.
                // This is the layer that makes the notch look lit rather than
                // decorated, and the reason the canvas needs its margins.
                lens(context, center: CGPoint(x: size.width / 2, y: centerY),
                     width: width * 2.3, height: height * 3.2,
                     gradient: gradient, blur: 26, opacity: 0.42)

                for bloom in blooms {
                    let drift = sin(time * bloom.drift + bloom.phase)
                    lens(
                        context,
                        center: CGPoint(
                            x: size.width / 2 + width * bloom.offset + drift * width * 0.06,
                            y: centerY + drift * height * 0.10
                        ),
                        width: width * bloom.scale,
                        height: height * bloom.scale * (0.9 + 0.2 * drift),
                        gradient: gradient,
                        blur: 5 + 5 * bloom.scale,
                        opacity: bloom.scale
                    )
                }

                // Two sines of different wavelength through the middle, clipped
                // to the lit width. Without them the bloom pulses but does not
                // sound like anything; with them there is motion along the
                // strip as well as across it.
                for (index, ripple) in [(waves: 2.2, speed: 3.4, weight: 1.0),
                                        (waves: 3.7, speed: -2.3, weight: 0.55)].enumerated() {
                    var line = context
                    line.addFilter(.blur(radius: 0.7))
                    line.opacity = (0.45 + 0.55 * loudness) * ripple.weight
                    line.stroke(
                        path(in: size, centerY: centerY, time: time, reach: width,
                             amplitude: height * 0.5, waves: ripple.waves, speed: ripple.speed),
                        with: .linearGradient(
                            Gradient(colors: [mood.edge.opacity(0), mood.core, mood.edge.opacity(0)]),
                            startPoint: CGPoint(x: (size.width - width) / 2, y: 0),
                            endPoint: CGPoint(x: (size.width + width) / 2, y: 0)
                        ),
                        style: StrokeStyle(lineWidth: index == 0 ? 1.4 : 1.0, lineCap: .round)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var gradient: Gradient {
        Gradient(stops: [
            .init(color: mood.core.opacity(0.95), location: 0.0),
            .init(color: mood.mid.opacity(0.72), location: 0.34),
            .init(color: mood.edge.opacity(0.30), location: 0.68),
            .init(color: mood.edge.opacity(0.0), location: 1.0),
        ])
    }

    /// 0…1. Recording follows the microphone; transcription has none to follow,
    /// so it swells on its own.
    private func loudness(at time: Double) -> Double {
        switch mood {
        case .listening:
            // Eased hard: raw level spends too long near the bottom, and the
            // light should answer an ordinary speaking voice, not only a shout.
            return pow(Double(max(0, min(1, level()))), 0.8)
        case .thinking:
            return 0.36 + 0.14 * sin(time * 1.6)
        }
    }

    /// One ellipse of light, drawn wide and short.
    private func lens(
        _ context: GraphicsContext,
        center: CGPoint,
        width: Double,
        height: Double,
        gradient: Gradient,
        blur: Double,
        opacity: Double
    ) {
        guard width > 0.5, height > 0.5 else { return }
        var layer = context
        layer.addFilter(.blur(radius: blur))
        layer.opacity = opacity
        layer.translateBy(x: center.x, y: center.y)
        // Drawn as a circle and stretched: a radial gradient in a scaled space
        // keeps its falloff, which a gradient fitted to an ellipse does not.
        layer.scaleBy(x: width / height, y: 1)
        layer.fill(
            Path(ellipseIn: CGRect(x: -height / 2, y: -height / 2, width: height, height: height)),
            with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: height / 2)
        )
    }

    /// A sine that exists only across the lit part of the strip and fades with
    /// it, so the line never sticks out past the glow.
    private func path(
        in size: CGSize,
        centerY: CGFloat,
        time: Double,
        reach: Double,
        amplitude: Double,
        waves: Double,
        speed: Double
    ) -> Path {
        var path = Path()
        let from = (size.width - reach) / 2
        let to = (size.width + reach) / 2
        let step: CGFloat = 3

        var x = from
        while x <= to {
            let progress = (x - from) / max(reach, 1)
            let angle = progress * 2 * .pi * waves + time * speed
            let envelope = sin(progress * .pi)
            let point = CGPoint(x: x, y: centerY + sin(angle) * amplitude * envelope * 0.5)
            if x == from { path.move(to: point) } else { path.addLine(to: point) }
            x += step
        }
        return path
    }
}
