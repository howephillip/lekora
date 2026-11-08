import SwiftUI
import AVFoundation
import AudioToolbox

#if os(iOS)
public struct QRScannerView: UIViewControllerRepresentable {
    public var onCodeScanned: (String) -> Void
    @Environment(\.presentationMode) var presentationMode

    public init(onCodeScanned: @escaping (String) -> Void) {
        self.onCodeScanned = onCodeScanned
    }

    public func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let parent: QRScannerView
        private var hasScanned = false

        init(parent: QRScannerView) {
            self.parent = parent
        }

        public func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasScanned else { return }
            if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
               let stringValue = metadataObject.stringValue {
                hasScanned = true
                NSLog("LekoraCamera: QR code scanned successfully: %@", stringValue)
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                DispatchQueue.main.async {
                    self.parent.onCodeScanned(stringValue)
                    self.parent.presentationMode.wrappedValue.dismiss()
                }
            }
        }
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

public class ScannerViewController: UIViewController {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.lekora.cameraQueue")
    private let previewView = CameraPreviewView()
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?

    public override func loadView() {
        self.view = previewView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.previewLayer.videoGravity = .resizeAspectFill

        NSLog("LekoraCamera: viewDidLoad, bounds=\(view.bounds)")
        checkPermissionsAndSetup()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let connection = previewView.previewLayer.connection {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            connection.isEnabled = true
        }
        NSLog("LekoraCamera: viewDidLayoutSubviews, bounds=\(view.bounds), isRunning=\(captureSession.isRunning), connection=\(String(describing: previewView.previewLayer.connection))")
    }

    private func checkPermissionsAndSetup() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        NSLog("LekoraCamera: camera authorization status = %ld", status.rawValue)
        switch status {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                NSLog("LekoraCamera: requestAccess result = %d", granted)
                if granted {
                    self?.setupSession()
                } else {
                    DispatchQueue.main.async {
                        self?.showError("Camera access was denied. Please allow camera access in Settings > Lekora.")
                    }
                }
            }
        default:
            showError("Camera access is turned off. Please allow camera access in Settings > Lekora, or paste the link.")
        }
    }

    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            NSLog("LekoraCamera: setupSession running on background queue")
            self.captureSession.beginConfiguration()

            if self.captureSession.canSetSessionPreset(.high) {
                self.captureSession.sessionPreset = .high
            }

            // Prefer multi-lens cameras: they switch to the ultra-wide (macro) lens
            // when the code is close. The plain wide lens can't focus nearer than
            // ~20 cm on Pro iPhones, which forced people to hold the phone far away.
            // Devices come back in the order listed here.
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInTripleCamera,
                    .builtInDualWideCamera,
                    .builtInDualCamera,
                    .builtInWideAngleCamera
                ],
                mediaType: .video,
                position: .back
            )

            guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
                self.captureSession.commitConfiguration()
                NSLog("LekoraCamera: ERROR - No back camera found")
                DispatchQueue.main.async {
                    self.showError("No camera available on this device.")
                }
                return
            }
            NSLog("LekoraCamera: Selected camera: %@", device.localizedName)

            guard let input = try? AVCaptureDeviceInput(device: device), self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration()
                NSLog("LekoraCamera: ERROR - Cannot add camera input")
                DispatchQueue.main.async {
                    self.showError("Cannot connect to camera input.")
                }
                return
            }
            self.captureSession.addInput(input)
            Self.configureForCloseScanning(device)

            let output = AVCaptureMetadataOutput()
            guard self.captureSession.canAddOutput(output) else {
                self.captureSession.commitConfiguration()
                NSLog("LekoraCamera: ERROR - Cannot add metadata output")
                DispatchQueue.main.async {
                    self.showError("Cannot configure barcode scanner.")
                }
                return
            }
            self.captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self.delegate, queue: DispatchQueue.main)

            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
                NSLog("LekoraCamera: Metadata output configured for .qr")
            } else {
                NSLog("LekoraCamera: WARNING - .qr not in availableMetadataObjectTypes")
            }

            self.captureSession.commitConfiguration()
            NSLog("LekoraCamera: commitConfiguration finished")

            // Attach session to previewLayer AFTER inputs have been added
            DispatchQueue.main.async {
                self.previewView.previewLayer.session = self.captureSession
                if let connection = self.previewView.previewLayer.connection {
                    connection.isEnabled = true
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                    NSLog("LekoraCamera: previewLayer attached with connection: isEnabled=%d", connection.isEnabled)
                } else {
                    NSLog("LekoraCamera: WARNING - previewLayer.connection is still nil after session assignment")
                }
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }

            self.captureSession.startRunning()
            NSLog("LekoraCamera: captureSession.startRunning finished, isRunning=%d", self.captureSession.isRunning)

        }
    }


    /// Frames like the Camera app's "1x" and favours near focus, as Apple
    /// recommends for code scanning.
    private static func configureForCloseScanning(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // On multi-lens cameras zoom 1.0 is the ultra-wide view, which makes the
            // code tiny. Zooming to the first switch-over point gives normal framing
            // while still letting the system swap to the macro lens up close.
            if let mainLensZoom = device.virtualDeviceSwitchOverVideoZoomFactors.first {
                device.videoZoomFactor = min(CGFloat(truncating: mainLensZoom), device.activeFormat.videoMaxZoomFactor)
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            NSLog("LekoraCamera: using %@, zoom=%.2f, minFocus=%ldmm",
                  device.localizedName, device.videoZoomFactor, device.minimumFocusDistance)
        } catch {
            NSLog("LekoraCamera: could not configure focus: %@", error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            if self?.captureSession.isRunning == false {
                self?.captureSession.startRunning()
                NSLog("LekoraCamera: viewWillAppear resumed captureSession")
            }
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            if self?.captureSession.isRunning == true {
                self?.captureSession.stopRunning()
                NSLog("LekoraCamera: viewWillDisappear stopped captureSession")
            }
        }
    }
}
#else
// Fallback for macOS previews or test targets
public struct QRScannerView: View {
    public var onCodeScanned: (String) -> Void
    public init(onCodeScanned: @escaping (String) -> Void) {
        self.onCodeScanned = onCodeScanned
    }
    public var body: some View {
        Text("Camera QR Scanning available on iOS devices.")
            .padding()
    }
}
#endif
