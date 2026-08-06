import SwiftUI

/// Woven strands of light: several threads of different frequency drifting
/// through each other, each one changing colour along its length.
///
/// Ported from the Strands shader (React Bits). Unlike the Siri waveform, this
/// one survives the trip out of GLSL almost intact: every strand is an ordinary
/// curve, the colour runs along the x axis — which is what `Canvas` draws
/// natively with a horizontal gradient — and the glow is a wide blurred stroke
/// under a narrow sharp one. What is lost is the shader's tone mapping
/// (`1 - exp(-col * glow)`), which brightens crossings more than a linear sum
/// does; additive blending gets close enough that the difference is hard to
/// name without the two side by side.
///
/// The shader's strands ripple on a timer. Here their reach follows the
/// microphone, so the weave opens up when you speak and settles when you stop.
struct DictationStrands: View {
    var mood: DictationWave.Mood
    var level: () -> Float

    /// Where the weave sits inside the canvas, measured from the top.
    static let coreInset: CGFloat = 30

    /// The shader's default palette, minus the colours that vanish against a
    /// black notch. Cycled along each strand rather than assigned per strand,
    /// exactly as `samplePalette` does it.
    private var palette: [Color] {
        switch mood {
        case .listening:
            return [
                Color(red: 0.03, green: 0.71, blue: 0.83),
                Color(red: 0.49, green: 0.23, blue: 0.93),
                Color(red: 0.16, green: 0.55, blue: 1.00),
                Color(red: 0.30, green: 0.90, blue: 0.85),
            ]
        case .thinking:
            return [
                Color(red: 1.00, green: 0.55, blue: 0.10),
                Color(red: 0.92, green: 0.20, blue: 0.25),
                Color(red: 1.00, green: 0.80, blue: 0.20),
                Color(red: 1.00, green: 0.40, blue: 0.05),
            ]
        }
    }

    /// More than the component's three: at this size the extra strands are
    /// what makes the weave read as a cloud of light rather than as a few
    /// separate wires.
    private let count = 5

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate * mood.speed
                let loudness = self.loudness(at: time)
                let centerY = Self.coreInset

                // Light accumulates; crossings go bright, as in the shader.
                context.blendMode = .plusLighter

                for index in 0..<count {
                    let fi = Double(index)
                    // The shader's per-strand constants, verbatim.
                    let phase = fi * 1.7
                    let frequency = 2.0 + fi * 0.35
                    let speed = 1.4 + fi * 1.2

                    let reach = (0.10 + 0.90 * loudness) * Double(size.height) * 0.42
                    let strand = path(
                        in: size, centerY: centerY, time: time,
                        phase: phase, frequency: frequency, speed: speed, reach: reach
                    )

                    // Colour runs along x and drifts with time — the shader's
                    // `h = fi/count + uv.x * 0.30 + t * 0.04`.
                    let shading = GraphicsContext.Shading.linearGradient(
                        gradient(offset: fi / Double(count) + time * 0.04),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    )

                    // Four passes from haze to filament. The wide blurred ones
                    // are what make the weave look like light hanging in the
                    // air; the sharp one at the end gives it something to hang
                    // on. One stroke alone reads as a wire.
                    var haze = context
                    haze.addFilter(.blur(radius: 22))
                    haze.opacity = 0.30 + 0.25 * loudness
                    haze.stroke(strand, with: shading, lineWidth: 30)

                    var bloom = context
                    bloom.addFilter(.blur(radius: 10))
                    bloom.opacity = 0.55 + 0.30 * loudness
                    bloom.stroke(strand, with: shading, lineWidth: 13)

                    var mid = context
                    mid.addFilter(.blur(radius: 3))
                    mid.opacity = 0.85
                    mid.stroke(strand, with: shading, lineWidth: 4.5)

                    context.stroke(
                        strand,
                        with: shading,
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func loudness(at time: Double) -> Double {
        switch mood {
        case .listening:
            return pow(Double(max(0, min(1, level()))), 0.8)
        case .thinking:
            return 0.32 + 0.14 * sin(time * 1.5)
        }
    }

    /// Palette sampled across the width, with the taper folded into the alpha.
    ///
    /// The shader multiplies a strand's *brightness* by the same envelope that
    /// flattens it (`col += color * g * env`), so a strand fades out as it
    /// straightens. Applying the envelope only to the amplitude — as this did
    /// at first — leaves a straight, fully opaque line lying across the quiet
    /// ends of the strip, which is the one part of the weave that never moves
    /// and therefore the first thing the eye catches.
    private func gradient(offset: Double) -> Gradient {
        let stops = 17
        return Gradient(stops: (0..<stops).map { step in
            let progress = Double(step) / Double(stops - 1)
            return Gradient.Stop(
                color: sample(offset + progress * 0.30).opacity(taper(at: progress)),
                location: progress
            )
        })
    }

    /// The shader's `env`, as a plain 0…1 curve: full in the middle, nothing at
    /// either end — and the ends are the ends of the notch.
    ///
    /// `cos(x · π · 1.3)` first reaches zero at x = 0.385, so the span has to
    /// be scaled to exactly that at the edges. Anything wider and the strand
    /// dies out early, leaving it visibly shorter than the cutout it belongs
    /// to — and cramming every wave into whatever is left, which reads as the
    /// weave being too dense.
    private func taper(at progress: Double) -> Double {
        return pow(max(cos(normalised(progress) * .pi * 1.3), 0), 3)
    }

    /// -0.385…0.385 across the full width.
    private func normalised(_ progress: Double) -> Double {
        (progress - 0.5) * 0.77
    }

    /// The shader's `samplePalette`: wrap around and blend between neighbours.
    private func sample(_ position: Double) -> Color {
        let colors = palette
        let wrapped = position - floor(position)
        let scaled = wrapped * Double(colors.count)
        let index = Int(scaled) % colors.count
        let next = (index + 1) % colors.count
        let blend = scaled - floor(scaled)
        return blend < 0.5 ? colors[index] : colors[next]
    }

    /// Two sines of related frequency, tapered towards the edges — the shader's
    /// `w` and `env` together.
    private func path(
        in size: CGSize,
        centerY: CGFloat,
        time: Double,
        phase: Double,
        frequency: Double,
        speed: Double,
        reach: Double
    ) -> Path {
        var path = Path()
        let step: CGFloat = 2
        var x: CGFloat = 0

        while x <= size.width {
            let progress = Double(x / size.width)
            let position = normalised(progress)
            // Square root of the envelope here, the envelope itself in the
            // alpha: the strand should still be curving where it is already
            // dimming, otherwise it visibly straightens before it disappears.
            let shape = sqrt(taper(at: progress))

            // Roughly one wave across the notch for the slowest strand, under
            // two for the fastest. The strip is 180 points wide — any denser
            // and the crests sit closer together than the glow around them,
            // which turns the weave into a solid smear.
            let w = sin(position * frequency * 3.2 + time * speed + phase) * 0.60
                + sin(position * frequency * 3.5 - time * speed * 0.7 + phase * 1.7) * 0.40

            let point = CGPoint(x: x, y: centerY + w * reach * shape)
            if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
            x += step
        }
        return path
    }
}
