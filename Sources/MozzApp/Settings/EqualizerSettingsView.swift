import SwiftUI
import MozzCore

/// The graphic-equalizer screen: a master switch, quick presets, ten octave
/// band sliders, a preamp, and reset. Off by default; while playing, band moves
/// are applied live (no gap). Reached from Settings → Playback and from the Now
/// Playing controls.
struct EqualizerSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    /// Presented as a sheet (from Now Playing) vs. pushed (from Settings). A sheet
    /// gets its own Done button; a pushed screen uses the nav back button.
    var presentedAsSheet = false

    @State private var enabled = false
    @State private var settings: EqualizerSettings = .flat

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Label("Equalizer", mozz: "waveform")
                }
                .onChange(of: enabled) { _, on in env.setEqualizerEnabled(on) }
                Text("Shapes the tone of everything you play. Works on streamed and downloaded tracks alike.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Preset") {
                presetRow
            }

            Section {
                bandSliders
            } header: {
                Text("Bands")
            } footer: {
                Text("Drag a band to boost or cut it (±12 dB). Double-tap a band to zero it.")
            }

            Section("Preamp") {
                preampRow
            }

            Section {
                Button(role: .destructive) {
                    apply(.flat)
                } label: {
                    Label("Reset to Flat", mozz: "arrow.triangle.2.circlepath")
                }
                .disabled(settings.isFlat)
            }
        }
        .navigationTitle("Equalizer")
        .toolbar {
            if presentedAsSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            enabled = env.equalizerEnabled
            settings = env.equalizerSettings
        }
    }

    // MARK: Presets

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EqualizerPreset.allCases) { preset in
                    let isCurrent = EqualizerPreset.matching(settings) == preset
                    Button {
                        apply(preset.settings)
                    } label: {
                        Text(preset.displayName)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15))
                            )
                            .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    // MARK: Bands

    private var bandSliders: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(0..<EqualizerSettings.bandCount, id: \.self) { index in
                VStack(spacing: 6) {
                    Text(gainLabel(settings.gains[index]))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(height: 12)
                    VerticalEQSlider(
                        value: settings.gains[index],
                        range: EqualizerSettings.gainRange,
                        onChange: { newValue in
                            update { $0.setGain(newValue, forBand: index) }
                        },
                        onReset: {
                            update { $0.setGain(0, forBand: index) }
                        })
                        .frame(height: 150)
                    Text(EqualizerSettings.frequencyLabel(forBand: index))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(height: 12)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(EqualizerSettings.frequencyLabel(forBand: index)) hertz")
                .accessibilityValue("\(Int(settings.gains[index].rounded())) decibels")
                .accessibilityAdjustableAction { direction in
                    let step = 1.0
                    let delta = direction == .increment ? step : -step
                    update { $0.setGain(settings.gains[index] + delta, forBand: index) }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(enabled ? 1 : 0.5)
        .allowsHitTesting(enabled)
    }

    // MARK: Preamp

    private var preampRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preamp")
                Spacer()
                Text(gainLabel(settings.preampDB) + " dB")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { settings.preampDB },
                    set: { newValue in update { $0.setPreamp(newValue) } }),
                in: EqualizerSettings.gainRange,
                step: 0.5)
            Text("Lower the preamp a few dB if boosting bands makes playback distort.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .opacity(enabled ? 1 : 0.5)
        .allowsHitTesting(enabled)
    }

    // MARK: Helpers

    private func update(_ mutate: (inout EqualizerSettings) -> Void) {
        var next = settings
        mutate(&next)
        settings = next
        env.updateEqualizerSettings(next)
    }

    private func apply(_ newSettings: EqualizerSettings) {
        settings = newSettings
        env.updateEqualizerSettings(newSettings)
    }

    private func gainLabel(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2   // nearest 0.5
        if abs(rounded) < 0.05 { return "0" }
        return String(format: "%+.1f", rounded)
    }
}

/// A vertical slider tuned for a graphic EQ: a center-anchored fill that grows up
/// for a boost and down for a cut, with a draggable knob. Snaps to 0 dB near the
/// middle; double-tap resets the band.
private struct VerticalEQSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void
    let onReset: () -> Void

    private let knob: CGFloat = 16
    private let trackWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let usable = height - knob
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? (value - range.lowerBound) / span : 0.5
            let knobY = usable * (1 - frac)                 // 0 = top
            let centerY = usable * 0.5 + knob / 2

            ZStack(alignment: .top) {
                // Background track.
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: trackWidth)
                    .frame(maxHeight: .infinity)

                // Fill between the 0 dB center and the knob.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: trackWidth,
                           height: max(0, abs((knobY + knob / 2) - centerY)))
                    .position(x: geo.size.width / 2,
                              y: (knobY + knob / 2 + centerY) / 2)

                // Knob.
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .position(x: geo.size.width / 2, y: knobY + knob / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let clampedY = min(max(0, g.location.y - knob / 2), usable)
                        var f = 1 - Double(clampedY / max(usable, 1))
                        f = min(max(f, 0), 1)
                        var newValue = range.lowerBound + f * span
                        // Snap to 0 dB when close, for a satisfying detent.
                        if abs(newValue) < 0.75 { newValue = 0 }
                        onChange(newValue)
                    }
            )
            .onTapGesture(count: 2) { onReset() }
        }
        .frame(width: knob)
    }
}
