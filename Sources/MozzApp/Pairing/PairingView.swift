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
            case .waitingForComputer:
                waiting("Waiting for your computer…")
            case .finishing:
                waiting("Waiting for the other device…")
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
        .navigationTitle("Your Devices")
        .inlineNavigationTitle()
        .onAppear {
            // A circle may have arrived from another Apple device through
            // iCloud Keychain since this object was made.
            controller.refresh()
            // A device that is not in a circle yet has exactly one thing it
            // could want here, so it does not need to be asked. Opening the
            // screen IS the intent; a button that says "start looking" is a
            // question with one answer.
            if !controller.isPaired, controller.stage == .idle {
                controller.join(path: .digits)
            }
        }
        .onDisappear { controller.cancel() }
    }

    // MARK: - Stages

    @ViewBuilder private var idle: some View {
        if controller.isPaired {
            Section {
                // The answer to "how do I know it worked". Saying "you are in a
                // circle" while naming nothing in it is a claim with nothing
                // behind it.
                ForEach(controller.members, id: \.name) { member in
                    HStack {
                        Label(member.name, mozz: member.isSelf ? "iphone" : "checkmark.seal.fill")
                        Spacer()
                        if member.isSelf {
                            Text("This device").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(member.joinedAt, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if controller.members.isEmpty {
                    Label("This device is in a circle", mozz: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your circle")
            } footer: {
                Text("Your listening, library and servers sync across these devices.")
            }
        } else {
            Section {
                Label("Looking for your other devices…", mozz: "person")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Add this device to your circle to sync listening, library and servers across everything you own.")
            }
        }

        Section {
            Button {
                controller.join()
            } label: {
                Label("Show a code instead", mozz: "qrcode")
            }
        } footer: {
            Text("For adding this device using another phone or tablet, which scans the code with its camera.")
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
            Label("Added to your circle", mozz: "checkmark.seal.fill")
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
