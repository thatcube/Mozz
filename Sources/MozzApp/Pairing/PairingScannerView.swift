import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if canImport(UIKit)
import UIKit

/// Renders a pairing code big enough to be read across a desk.
enum PairingCodeImage {
    static func make(from text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium correction. Higher levels buy resilience against a damaged
        // code, which matters for print and not for a screen held up for ten
        // seconds; the density costs more than it returns here.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // CoreImage emits roughly one pixel per module, so it must be scaled
        // with nearest-neighbour. Letting the image view do it smooths the edges
        // and can make the code unreadable.
        let scale = 12.0
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// A camera preview that reports the first Mozz code it sees.
///
/// Reports once and then stops: a QR code stays in frame for many frames, and a
/// scanner that fires repeatedly starts a second ceremony while the first is
/// still running.
struct PairingScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private var reported = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !reported,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            reported = true
            DispatchQueue.main.async { self.onCode(value) }
        }
    }

    final class ScannerViewController: UIViewController {
        weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            // Set AFTER adding the output; the available types are empty before
            // then, and assigning [.qr] to an empty set traps.
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard !session.isRunning else { return }
            // startRunning blocks; keeping it off the main thread is the
            // difference between a smooth push and a visibly stalled one.
            Task.detached(priority: .userInitiated) { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }
    }
}
#endif
