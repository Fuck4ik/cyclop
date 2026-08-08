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
    var mood: DictationMood
    var level: () -> Float

    /// Where the line sits inside the canvas, measured from the top.
    static let coreInset: CGFloat = 26

    /// Transcription draws the same wave thinner and dimmer: with no voice
    /// left to answer, it only has to say "still working".
    private var bodyScale: Double { mood == .thinking ? 0.55 : 1.0 }

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
                // The full width of the notch. Anything less leaves the wave
                // visibly shorter than the cutout it belongs to.
                let reach = Double(size.width)
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
                    // Every pass is painted through the same fading gradient:
                    // the shader multiplies brightness by the envelope, so a
                    // copy goes out as it flattens. Fading only the amplitude
                    // leaves a straight, fully lit line lying across both quiet
                    // ends — the one part of the wave that never moves, and
                    // therefore the first thing the eye finds.
                    let shading = fading(color, in: size)

                    var band = context
                    band.addFilter(.blur(radius: 4))
                    band.opacity = (0.22 + 0.16 * loudness) * bodyScale
                    band.fill(closed(wave, and: core), with: shading)

                    var haze = context
                    haze.addFilter(.blur(radius: 16))
                    haze.opacity = (0.35 + 0.25 * loudness) * bodyScale
                    haze.stroke(wave, with: shading, lineWidth: 16 * bodyScale)

                    var halo = context
                    halo.addFilter(.blur(radius: 6))
                    halo.opacity = 0.6
                    halo.stroke(wave, with: shading, lineWidth: 7 * bodyScale)

                    context.stroke(
                        wave,
                        with: shading,
                        style: StrokeStyle(lineWidth: 1.8 * bodyScale, lineCap: .round)
                    )
                }

                // The white line the colours were separated from. Drawn last
                // and brightest: it is what the eye follows.
                let white = fading(.white, in: size)

                var coreHalo = context
                coreHalo.addFilter(.blur(radius: 12))
                coreHalo.opacity = 0.5 + 0.4 * loudness
                coreHalo.stroke(core, with: white, lineWidth: 12 * bodyScale)

                context.stroke(
                    core,
                    with: white,
                    style: StrokeStyle(lineWidth: 2.2 * bodyScale, lineCap: .round)
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
            return 0.15 + 0.08 * sin(time * 1.7) * sin(time * 0.6)
        }
    }

    /// One colour, faded out towards both ends by the same envelope that
    /// flattens the wave there.
    private func fading(_ color: Color, in size: CGSize) -> GraphicsContext.Shading {
        let stops = 15
        let gradient = Gradient(stops: (0..<stops).map { step in
            let progress = Double(step) / Double(stops - 1)
            return Gradient.Stop(color: color.opacity(envelope(at: progress)), location: progress)
        })
        return .linearGradient(
            gradient,
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0)
        )
    }

    /// The shader's `env`: `cos²`, reaching zero exactly at both ends.
    private func envelope(at progress: Double) -> Double {
        let normalised = progress * 2 - 1
        return pow(cos(.pi * 0.5 * min(abs(normalised), 1.0)), 2)
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
            // Square root here, the envelope itself in the alpha: the line
            // should still be curving where it is already dimming, or it
            // visibly straightens before it disappears.
            let shape = sqrt(envelope(at: progress))
            // Roughly one and a half waves across the notch. Denser than this
            // and the crests sit closer together than the glow around them,
            // which turns the whole thing into a smear.
            let y = sin(normalised * .pi * 1.5 + drift) * 0.85
                + sin(normalised * .pi * 0.7 - drift * 0.6) * 0.15
            let point = CGPoint(x: x, y: centerY + y * amplitude * shape)
            if x == from { path.move(to: point) } else { path.addLine(to: point) }
            x += step
        }
        return path
    }
}
