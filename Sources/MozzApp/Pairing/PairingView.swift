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
    @EnvironmentObject private var ambientJoin: AmbientJoinController
    @AppStorage(RelayBootstrapper.enabledKey) private var deviceSyncEnabled = true

    var body: some View {
        Form {
            if let request = ambientJoin.request {
                ambientConfirmation(request)
            } else if let peerName = ambientJoin.confirmedPeerName {
                waitingForPeerConfirmation(peerName)
            } else {
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
            case let .comparing(digits, peerName):
                comparing(digits, peerName: peerName)
            case .joined:
                joined
            case let .failed(message):
                failed(message)
              }
            }
        }
        .mozzReadableWidth()
        .navigationTitle("Your Devices")
        .inlineNavigationTitle()
        .onAppear {
            // A circle may have arrived from another Apple device through
            // iCloud Keychain since this object was made.
            controller.refresh()
            ambientJoin.setDevicesScreenActive(true)
            if controller.isPaired, controller.stage == .idle {
                controller.listenForJoiners()
            }
        }
        .onDisappear {
            controller.cancel()
            ambientJoin.setDevicesScreenActive(false)
            ambientJoin.setPairingScreenRunsCeremony(false)
        }
        .onChange(of: ambientJoin.completedCircleID) { _, circleID in
            guard circleID != nil else { return }
            controller.refresh()
        }
        .onChange(of: controller.stage) { _, stage in
            if stage == .joined {
                ambientJoin.setPairingScreenRunsCeremony(false)
            }
        }
        .onChange(of: deviceSyncEnabled) { _, _ in
            SharedEnvironment.shared.syncHistoryIfDue()
        }
    }

    // MARK: - Stages

    @ViewBuilder private func ambientConfirmation(
        _ request: AmbientJoinController.Request
    ) -> some View {
        Section {
            VStack(spacing: 20) {
                Text(request.peerName)
                    .font(.headline)
                Text(request.spacedDigits)
                    .font(.system(size: 54, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(
                        request.digits.map(String.init).joined(separator: " "))
                Text("Confirm this number on both devices.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button("Numbers Match") {
                    ambientJoin.answer(true)
                }
                .buttonStyle(.mozzProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                Button("Numbers Do Not Match", role: .destructive) {
                    ambientJoin.answer(false)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } header: {
            Text("Add this device to your circle?")
        }
    }

    @ViewBuilder private func waitingForPeerConfirmation(
        _ peerName: String
    ) -> some View {
        Section {
            VStack(spacing: 16) {
                ProgressView()
                Text("Confirmed on this device")
                    .font(.headline)
                Text("Waiting for \(peerName) to confirm the same number.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    @ViewBuilder private var idle: some View {
        if controller.isPaired {
            Section {
                // The answer to "how do I know it worked". Saying "you are in a
                // circle" while naming nothing in it is a claim with nothing
                // behind it.
                ForEach(controller.members, id: \.id) { member in
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
                beginScreenCeremony {
                    controller.join()
                }
            } label: {
                Label("Show a code instead", mozz: "qrcode")
            }
        } footer: {
            Text("For adding this device using another phone or tablet, which scans the code with its camera.")
        }

        Section {
            Button {
                beginScreenCeremony {
                    controller.beginScanning()
                }
            } label: {
                Label("Scan a code", mozz: "camera")
            }
        } footer: {
            Text(controller.isPaired
                 ? "Use this to add another device to your circle."
                 : "Use this on the device that already has your music. Scanning this way creates your circle.")
        }

        if controller.isPaired {
            Section {
                Toggle(
                    "Sync between your devices",
                    isOn: $deviceSyncEnabled)
            } footer: {
                Text(
                    deviceSyncEnabled
                    ? "Encrypted before it leaves this device; the relay cannot read it."
                    : "Off: devices exchange updates only when another supported local path is available."
                )
            }

            Section {
                Button(role: .destructive) {
                    controller.leaveCircle()
                    ambientJoin.setDevicesScreenActive(true)
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

    @ViewBuilder private func comparing(_ digits: String, peerName: String?) -> some View {
        Section {
            VStack(spacing: 12) {
                Text(spaced(digits))
                    .font(.system(.largeTitle, design: .monospaced))
                    .fontWeight(.semibold)
                    .accessibilityLabel(digits.map(String.init).joined(separator: " "))
                Text("\(peerName ?? "The other device") should be showing this number.")
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
            Button("Try again") { resetToAutomaticJoining() }
        }
    }

    @ViewBuilder private var cancelSection: some View {
        Section {
            Button(role: .cancel) {
                resetToAutomaticJoining()
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

    private func beginScreenCeremony(_ action: () -> Void) {
        ambientJoin.setPairingScreenRunsCeremony(true)
        action()
    }

    private func resetToAutomaticJoining() {
        controller.reset()
        ambientJoin.setPairingScreenRunsCeremony(false)
        if controller.isPaired {
            controller.listenForJoiners()
        }
    }
}
