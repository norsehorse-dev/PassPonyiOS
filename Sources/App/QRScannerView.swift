import AVFoundation
import SwiftUI
import UIKit

/// Full-screen QR scanner for the one-time code setup sheet: an
/// AVFoundation capture session with `AVCaptureMetadataOutput` doing the
/// decoding, no third-party code. Presented with `fullScreenCover` by the
/// sheet, so the decoded URI (a secret) stays in the sheet's state and
/// never touches navigation or persisted state. Frames are decoded in the
/// capture pipeline and nothing is written anywhere.
///
/// `onDecoded` validates a payload and returns nil to accept it (the
/// caller closes the scanner) or a message to show while scanning resumes,
/// so a wrong kind of QR code (HOTP, a Google Authenticator export, a URL)
/// is explained rather than silently ignored.
struct QRScannerScreen: View {
    var onDecoded: (String) -> String?
    var onClose: () -> Void

    @State private var rejection: String?
    @State private var paused = false
    @State private var torchOn = false
    @State private var hasTorch = false

    var body: some View {
        ZStack {
            QRCameraView(paused: $paused, torchOn: torchOn, hasTorch: $hasTorch) { text in
                if let message = onDecoded(text) {
                    rejection = message
                    paused = true
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Close")
                    Text("Scan QR code")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.leading, 8)
                    Spacer()
                    if hasTorch {
                        Button {
                            torchOn.toggle()
                        } label: {
                            Image(systemName: torchOn ? "flashlight.off.fill" : "flashlight.on.fill")
                                .font(.title3)
                                .padding(10)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .accessibilityLabel("Torch")
                    }
                }
                .foregroundStyle(.white)
                .padding()

                Spacer()

                Text(rejection ?? L("Point the camera at the QR code the site shows during two-factor setup."))
                    .font(.callout)
                    .foregroundStyle(rejection == nil ? Color.white : Color.red)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.6))
            }
        }
        .background(Color.black)
        // A rejected code is shown briefly, then scanning resumes.
        .task(id: rejection) {
            guard rejection != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            rejection = nil
            paused = false
        }
    }
}

/// The camera preview plus the metadata pipeline, as a view controller
/// so the session's lifetime follows the screen's.
struct QRCameraView: UIViewControllerRepresentable {
    @Binding var paused: Bool
    var torchOn: Bool
    @Binding var hasTorch: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let controller = QRCameraController()
        controller.onCode = onCode
        controller.onReady = { torch in
            DispatchQueue.main.async { hasTorch = torch }
        }
        return controller
    }

    func updateUIViewController(_ controller: QRCameraController, context: Context) {
        controller.onCode = onCode
        controller.paused = paused
        controller.setTorch(torchOn)
    }
}

final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onReady: ((Bool) -> Void)?
    var paused = false

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var device: AVCaptureDevice?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setTorch(false)
        session.stopRunning()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        self.device = device

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        onReady?(device.hasTorch)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !paused else { return }
        guard let code = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr }),
            let text = code.stringValue
        else { return }
        // One report per code: the SwiftUI side resumes scanning after a
        // rejection, or closes the screen after an acceptance.
        paused = true
        onCode?(text)
    }
}
