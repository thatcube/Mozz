import MozzPairing
import SwiftUI

/// The pairing screen, pushed from Settings.
///
/// One page rather than a flow of pushes. Pairing is two people (or one person
/// and two devices) doing something together, and a stack that pushes and pops
/// underneath them loses the thread; the stage changing in place does not.
struct PairingView: View {
    @StateObject private var controller = PairingController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            switch controller.stage {
            case .idle:
                idle
            case let .showingCode(text):
                showingCode(text)
            case .scanning:
                scanning
            case .connecting:
                waiting("Connecting…")
            case let .comparing(digits):
                comparing(digits)
            case .joined:
                joined
            case let .failed(message):
                failed(message)
            }
        }
        .mozzReadableWidth()
        .navigationTitle("Devices")
        .inlineNavigationTitle()
        .onDisappear { controller.cancel() }
    }

    // MARK: - Stages

    @ViewBuilder private var idle: some View {
        Section {
            if controller.isPaired {
                Label("This device is in a circle", mozz: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label("This device is on its own", mozz: "person")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(controller.isPaired
                 ? "Your listening, library and servers sync with the other devices in your circle."
                 : "Pair with another device to sync your listening, library and servers between them.")
        }

        Section {
            Button {
                controller.join()
            } label: {
                Label("Show my code", mozz: "qrcode")
            }
        } footer: {
            Text("Use this on the device you are adding. Another device that is already set up scans the code.")
        }

        Section {
            Button {
                controller.beginScanning()
            } label: {
                Label("Scan a code", mozz: "camera")
            }
        } footer: {
            Text(controller.isPaired
                 ? "Use this to add another device to your circle."
                 : "Use this on the device that already has your music. Pairing this way creates your circle.")
        }

        if controller.isPaired {
            Section {
                Button(role: .destructive) {
                    controller.leaveCircle()
                } label: {
                    Label("Leave circle", mozz: "person.badge.minus")
                }
            } footer: {
                Text("This device stops syncing. Nothing is removed from your servers.")
            }
        }
    }

    @ViewBuilder private func showingCode(_ text: String) -> some View {
        Section {
            VStack(spacing: 16) {
                #if canImport(UIKit)
                if let image = PairingCodeImage.make(from: text) {
                    Image(uiImage: image)
                        .interpolation(.none)      // nearest-neighbour, or the code blurs
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Pairing code")
                }
                #endif
                ProgressView()
                Text("Scan this with a device already in your circle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        cancelSection
    }

    @ViewBuilder private var scanning: some View {
        Section {
            #if canImport(UIKit)
            PairingScannerView { code in controller.admit(scannedText: code) }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
            #endif
        } footer: {
            Text("Point the camera at the code on the other device.")
        }
        cancelSection
    }

    @ViewBuilder private func waiting(_ message: String) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(message)
            }
        }
        cancelSection
    }

    @ViewBuilder private func comparing(_ digits: String) -> some View {
        Section {
            VStack(spacing: 12) {
                Text(spaced(digits))
                    .font(.system(.largeTitle, design: .monospaced))
                    .fontWeight(.semibold)
                    .accessibilityLabel(digits.map(String.init).joined(separator: " "))
                Text("Both devices should be showing this number.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }

        Section {
            Button {
                controller.answer(true)
            } label: {
                Label("They match", mozz: "checkmark")
            }
            Button(role: .destructive) {
                controller.answer(false)
            } label: {
                Label("They do not match", mozz: "xmark")
            }
        } footer: {
            Text("If the numbers differ, something is intercepting the connection. Nothing is shared unless you confirm.")
        }
    }

    @ViewBuilder private var joined: some View {
        Section {
            Label("Paired", mozz: "checkmark.seal.fill")
        } footer: {
            Text("These devices now share listening, library and servers.")
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder private func failed(_ message: String) -> some View {
        Section {
            Text(message)
        }
        Section {
            Button("Try again") { controller.reset() }
        }
    }

    @ViewBuilder private var cancelSection: some View {
        Section {
            Button(role: .cancel) {
                controller.reset()
            } label: {
                Text("Cancel")
            }
        }
    }

    /// Six digits read aloud far more reliably in two groups of three, which is
    /// how people say them to each other over the phone anyway.
    private func spaced(_ digits: String) -> String {
        guard digits.count == 6 else { return digits }
        let middle = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[digits.startIndex..<middle]) \(digits[middle...])"
    }
}
