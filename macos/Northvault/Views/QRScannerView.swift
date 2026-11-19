import AVFoundation
import SwiftUI
import Vision

/// Reads (animated) PSBT or account-key QR codes with the Mac's camera.
/// Frames go to the Rust UR decoder until `onFrame` reports the scan complete.
struct QRScannerSheet: View {
    @Environment(\.dismissPanel) private var dismiss
    let title: String
    let onFrame: (UrDecoder) throws -> Bool

    @State private var decoder = UrDecoder()
    @State private var progress = 0.0
    @State private var error: String?

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Text(title).font(.system(size: 16, weight: .semibold))
            CameraPreview { handle($0) }
                .frame(width: 480, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.borderStrong))
            ProgressView(value: progress).frame(width: 480)
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.negative)
            }
            Button("Cancel") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Space.xxl)
        .background(Theme.ground)
    }

    private func handle(_ code: String) {
        do {
            progress = try decoder.receive(part: code)
            if try onFrame(decoder) {
                dismiss()
            }
        } catch {
            self.error = error.userMessage
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Scanner { Scanner(onCode: onCode) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: context.coordinator.session)
        preview.videoGravity = .resizeAspectFill
        view.layer = preview
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Scanner) {
        coordinator.stop()
    }
}

final class Scanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private let queue = DispatchQueue(label: "northvault.qr-scanner")
    private var lastCode: String?

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return }
            self.queue.async { self.configureAndRun() }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    private func configureAndRun() {
        guard session.inputs.isEmpty,
              let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        guard let code = request.results?.first?.payloadStringValue, code != lastCode else { return }
        lastCode = code
        DispatchQueue.main.async { self.onCode(code) }
    }
}
