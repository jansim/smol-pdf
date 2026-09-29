import AppKit
import SmolPDFCore
import SwiftUI

extension CompressionProfile {
    /// How aggressive the profile is, from 0 (lossless) to 1 (maximum).
    /// The built-in profiles sit at 0, 0.25, 0.5, 0.75 and 1.
    var compressionLevel: Double {
        compressImages ? min(1, max(0, (1 - imageQuality) * 1.25)) : 0
    }
}

/// A speedometer-style dial that selects one of the built-in profiles.
/// The needle locks in to the built-in levels; custom profiles are shown at their approximate level.
struct CompressionGauge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    /// Set for the duration of a drag that started on the center label, so it doesn't move the dial.
    @State private var ignoringDrag: Bool?

    private let detents = CompressionProfile.builtIns
    private let startAngle = 135.0
    private let sweep = 270.0
    private let diameter = 176.0
    private let trackWidth = 10.0
    private let inset = 16.0

    private var radius: Double { diameter / 2 - inset - trackWidth / 2 }

    var body: some View {
        let profile = model.selectedProfile
        let level = profile.compressionLevel
        let onFire = profile.isBuiltIn && level > 0.999
        VStack(spacing: 0) {
            ZStack {
                face
                track
                if onFire {
                    fieryProgress
                        .transition(.opacity)
                } else {
                    progress(level, custom: !profile.isBuiltIn)
                }
                ticks(level)
                knob(level)
                label(profile, onFire: onFire)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(drag)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: level)
            .animation(.easeInOut(duration: 0.35), value: onFire)
            endLabels
                .padding(.top, -12)
        }
        // Like NSSlider, only take key focus with Full Keyboard Access, so the dial isn't focused at launch.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in step(-1) }
        .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in step(1) }
        .opacity(model.isCompressing ? 0.5 : 1)
        .allowsHitTesting(!model.isCompressing)
        .accessibilityElement()
        .accessibilityLabel("Compression level")
        .accessibilityValue(profile.name)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
    }

    // MARK: Parts

    private var face: some View {
        Circle()
            .fill(Color(nsColor: .controlBackgroundColor).gradient
                .shadow(.inner(color: .black.opacity(0.12), radius: 3, y: -2)))
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).blendMode(.overlay))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            .overlay {
                if isFocused {
                    Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 3)
                }
            }
    }

    private var track: some View {
        placeArc(arc(to: 1)
            .stroke(.quaternary, style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)))
    }

    private func progress(_ level: Double, custom: Bool) -> some View {
        let colors: [Color] = custom ? [.gray, .secondary] : [.teal, .blue, .indigo]
        return placeArc(arc(to: level)
            .stroke(
                AngularGradient(colors: colors, center: .center, startAngle: .degrees(-20), endAngle: .degrees(290)),
                style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
            ))
    }

    /// The full arc at maximum: hot colors that swirl around the dial and a pulsing glow.
    private var fieryProgress: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (t * 120).truncatingRemainder(dividingBy: 360)
            placeArc(arc(to: 1)
                .stroke(
                    AngularGradient(
                        colors: [.yellow, .orange, .red, .pink, .red, .orange, .yellow],
                        center: .center,
                        startAngle: .degrees(phase),
                        endAngle: .degrees(phase + 360)
                    ),
                    style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
                ))
                .shadow(color: .red.opacity(0.45 + 0.2 * sin(t * 4)), radius: 6)
        }
    }

    private func ticks(_ level: Double) -> some View {
        ForEach(detents) { detent in
            let reached = detent.compressionLevel <= level + 0.001
            Capsule()
                .fill(reached ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 6, height: 2)
                .offset(x: radius - trackWidth / 2 - 7)
                .rotationEffect(angle(for: detent.compressionLevel))
        }
    }

    private func knob(_ level: Double) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: trackWidth + 8, height: trackWidth + 8)
            .offset(x: radius)
            .rotationEffect(angle(for: level))
    }

    private func label(_ profile: CompressionProfile, onFire: Bool) -> some View {
        VStack(spacing: 2) {
            Text(profile.name)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(onFire
                    ? AnyShapeStyle(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.interpolate)
            Text(profile.isBuiltIn ? dialSummary(profile) : "Custom")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: radius * 1.25)
    }

    /// A short summary that fits inside the dial; the inspector below shows the details.
    private func dialSummary(_ profile: CompressionProfile) -> String {
        guard profile.compressImages else { return "Images untouched" }
        let quality = Format.percent(profile.imageQuality)
        return profile.maxResolution.map { "\($0) dpi · JPEG \(quality)" } ?? "JPEG \(quality)"
    }

    private var endLabels: some View {
        HStack {
            Label("Quality", systemImage: "sparkles")
            Spacer()
            Label("Size", systemImage: "arrow.down.right.and.arrow.up.left")
                .labelStyle(TrailingIconLabelStyle())
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: diameter + 60)
    }

    // MARK: Geometry

    /// A circle trimmed to `level` of the dial's sweep, starting at 3 o'clock.
    private func arc(to level: Double) -> some Shape {
        Circle().trim(from: 0, to: sweep / 360 * level)
    }

    /// Sizes a stroked arc and rotates it so it starts at the bottom left.
    private func placeArc(_ arc: some View) -> some View {
        arc
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(startAngle))
    }

    private func angle(for level: Double) -> Angle {
        .degrees(startAngle + sweep * level)
    }

    /// The dial level under a point, clamped to the ends when it falls into the gap at the bottom.
    private func level(at point: CGPoint) -> Double {
        let dx = point.x - diameter / 2, dy = point.y - diameter / 2
        var degrees = atan2(dy, dx) * 180 / .pi - startAngle
        while degrees < 0 { degrees += 360 }
        if degrees > sweep { return degrees > (sweep + 360) / 2 ? 0 : 1 }
        return degrees / sweep
    }

    // MARK: Interaction

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if ignoringDrag == nil {
                    let start = value.startLocation
                    let distance = hypot(start.x - diameter / 2, start.y - diameter / 2)
                    ignoringDrag = distance < radius * 0.55
                }
                guard ignoringDrag == false else { return }
                let target = level(at: value.location)
                if let nearest = detents.min(by: { abs($0.compressionLevel - target) < abs($1.compressionLevel - target) }) {
                    select(nearest)
                }
            }
            .onEnded { _ in ignoringDrag = nil }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let current = model.selectedProfile.compressionLevel
        let target: CompressionProfile?
        if delta > 0 {
            target = detents.first { $0.compressionLevel > current + 0.001 }
        } else {
            target = detents.last { $0.compressionLevel < current - 0.001 }
        }
        if let target { select(target) }
        return .handled
    }

    private func select(_ profile: CompressionProfile) {
        guard profile.id != model.selectedProfileID else { return }
        model.selectedProfileID = profile.id
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
