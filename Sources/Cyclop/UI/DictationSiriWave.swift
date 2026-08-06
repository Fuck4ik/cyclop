import SwiftUI

/// The iOS-style voice waveform: one bright line with colour separated out of
/// it, drifting sideways.
///
/// Ported from the GLSL shader behind the Siri wave rather than from its
/// pictures. The shader draws the same line four times in spectral colours,
/// each with a slightly different phase, and adds the results together —
/// separation between the copies is what produces the rainbow fringe, and
/// summing light rather than painting over it is what makes the overlap white
/// at the crest. Both are reproducible here: `Canvas` can add colours with
/// `.plusLighter`, and a blurred stroke under a sharp one gives the bloom the
/// shader gets from its inverse-distance falloff.
///
/// The shader animates its own fake "frequencies" from time. Here the low band
/// is the real microphone level instead, so the line answers the voice.
struct DictationSiriWave: View {
    var mood: DictationWave.Mood
    var level: () -> Float

    /// Where the line sits inside the canvas, measured from the top.
    static let coreInset: CGFloat = 26

    /// The shader's `spectral4`: red, yellow, green, cyan. Together they sum to
    /// white, which is why the crest goes white where all four overlap.
    private var spectrum: [Color] {
        switch mood {
        case .listening:
            return [
                Color(red: 1.00, green: 0.10, blue: 0.35),
                Color(red: 0.95, green: 0.80, blue: 0.10),
                Color(red: 0.10, green: 0.95, blue: 0.60),
                Color(red: 0.15, green: 0.65, blue: 1.00),
            ]
        case .thinking:
            return [
                Color(red: 1.00, green: 0.15, blue: 0.10),
                Color(red: 1.00, green: 0.55, blue: 0.05),
                Color(red: 1.00, green: 0.80, blue: 0.15),
                Color(red: 0.95, green: 0.35, blue: 0.20),
            ]
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let loudness = self.loudness(at: time)

                // The shader's SPEED: the wave travels sideways forever, which
                // is most of why it looks like a signal rather than a shape.
                let drift = time * 2.4 * mood.speed
                let centerY = Self.coreInset
                let reach = size.width * 0.92
                let amplitude = (2 + 30 * loudness)
                // ABERRATION: how far the colour copies are pushed apart. Grows
                // with the voice, so a loud take fringes wider — the shader
                // does the same through its mid/high bands.
                let spread = 0.55 + 0.85 * loudness

                // Light adds up instead of painting over: four colours crossing
                // at the same crest make it white, exactly as in the shader.
                context.blendMode = .plusLighter

                let core = path(
                    in: size, centerY: centerY, reach: reach,
                    amplitude: amplitude, drift: drift
                )

                for (index, color) in spectrum.enumerated() {
                    let offset = (Double(index) / Double(spectrum.count - 1) - 0.5) * 2 * spread
                    let wave = path(
                        in: size, centerY: centerY, reach: reach,
                        amplitude: amplitude, drift: drift + offset
                    )

                    // The shader's BAND_FILL: the gap between this copy and the
                    // main line is filled, not left empty. That fill is what
                    // gives the wave a body instead of four separate threads,
                    // and it is the part that was missing before.
                    var band = context
                    band.addFilter(.blur(radius: 3))
                    band.opacity = 0.16 + 0.12 * loudness
                    band.fill(closed(wave, and: core), with: .color(color))

                    var halo = context
                    halo.addFilter(.blur(radius: 6))
                    halo.opacity = 0.5
                    halo.stroke(wave, with: .color(color), lineWidth: 5)

                    context.stroke(
                        wave,
                        with: .color(color.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
                    )
                }

                // The white line the colours were separated from. Drawn last
                // and brightest: it is what the eye follows.
                var coreHalo = context
                coreHalo.addFilter(.blur(radius: 10))
                coreHalo.opacity = 0.5 + 0.4 * loudness
                coreHalo.stroke(core, with: .color(.white), lineWidth: 9)

                context.stroke(
                    core,
                    with: .color(.white.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func loudness(at time: Double) -> Double {
        switch mood {
        case .listening:
            return pow(Double(max(0, min(1, level()))), 0.8)
        case .thinking:
            // No microphone to answer any more, so the line breathes on its own
            // — the same shape, just self-driven.
            return 0.30 + 0.16 * sin(time * 1.7) * sin(time * 0.6)
        }
    }

    /// The area between two copies of the line, as a fillable shape: one curve
    /// forward, the other back. Both are sampled at the same x positions, so
    /// the reversed one closes the shape exactly.
    private func closed(_ upper: Path, and lower: Path) -> Path {
        var points: [CGPoint] = []
        upper.forEach { element in
            switch element {
            case .move(let point), .line(let point): points.append(point)
            default: break
            }
        }
        var back: [CGPoint] = []
        lower.forEach { element in
            switch element {
            case .move(let point), .line(let point): back.append(point)
            default: break
            }
        }
        guard let first = points.first else { return Path() }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        for point in back.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The shader's line: a sine tapered by `cos²` towards both ends, so it
    /// dies out instead of being cut off at the edge of the strip.
    private func path(
        in size: CGSize,
        centerY: CGFloat,
        reach: Double,
        amplitude: Double,
        drift: Double
    ) -> Path {
        var path = Path()
        let from = (size.width - reach) / 2
        let to = (size.width + reach) / 2
        let step: CGFloat = 2

        var x = from
        while x <= to {
            let progress = (x - from) / max(reach, 1)
            // -1…1 across the lit part, matching the shader's normalised x.
            let normalised = progress * 2 - 1
            let envelope = pow(cos(.pi * 0.5 * min(abs(0.9 * normalised), 1.0)), 2)
            // Two frequencies: the shader's single sine plus a slower one, so
            // the crest wanders instead of marching at a fixed rate.
            let y = sin(normalised * .pi * 2.6 + drift) * 0.85
                + sin(normalised * .pi * 1.1 - drift * 0.6) * 0.15
            let point = CGPoint(x: x, y: centerY + y * amplitude * envelope)
            if x == from { path.move(to: point) } else { path.addLine(to: point) }
            x += step
        }
        return path
    }
}
