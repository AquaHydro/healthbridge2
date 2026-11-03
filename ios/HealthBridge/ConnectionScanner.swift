import AVFoundation
import SwiftUI

struct ConnectionScanner: UIViewControllerRepresentable {
  let receive: (String) -> Void
  let failed: () -> Void
  func makeUIViewController(context: Context) -> CameraScannerController {
    CameraScannerController(receive: receive, failed: failed)
  }
  func updateUIViewController(_ controller: CameraScannerController, context: Context) {}
  static func dismantleUIViewController(_ controller: CameraScannerController, coordinator: ()) {
    CameraDiagnostics.record("dismantle", ["instance": controller.capture.diagnosticID])
    controller.capture.stop()
  }
}

/// All capture configuration and start/stop calls are serialized off the UI thread.
final class BarcodeCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate,
  AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
  let session = AVCaptureSession()
  let diagnosticID = Int.random(in: 1...999999)
  private var stateObservers: [NSObjectProtocol] = []
  private let queue = DispatchQueue(label: "healthbridge.qr-camera")
  private var configured = false
  private let frameQueue = DispatchQueue(label: "healthbridge.camera-frame-check")
  private var receivedFrame = false
  private var received = false  // Accessed only by the metadata delegate on the main queue.
  private let receive: (String) -> Void
  private let failed: () -> Void
  var onRunning: (() -> Void)?
  private var errorObserver: NSObjectProtocol?
  init(receive: @escaping (String) -> Void, failed: @escaping () -> Void) {
    self.receive = receive
    self.failed = failed
    super.init()
    errorObserver = NotificationCenter.default.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
    ) { [weak self] note in
      let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
      CameraDiagnostics.record("runtime_error", ["code": code])
      self?.failed()
    }
    for name in [
      AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification,
      AVCaptureSession.didStartRunningNotification, AVCaptureSession.didStopRunningNotification,
    ] {
      stateObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) {
          [weak self] note in
          CameraDiagnostics.record(
            note.name.rawValue,
            [
              "instance": self?.diagnosticID ?? 0,
              "reason": (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?
                .intValue ?? 0,
            ])
        })
    }
  }
  deinit {
    if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
    for observer in stateObservers { NotificationCenter.default.removeObserver(observer) }
  }
  func configure() {
    queue.async { [self] in
      CameraDiagnostics.record(
        "configure_begin",
        [
          "instance": diagnosticID,
          "authorization": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
        ])
      session.beginConfiguration()
      defer { session.commitConfiguration() }
      do {
        guard
          let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back)
        else { throw PairingError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
          throw PairingError.unavailable
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
          throw PairingError.unavailable
        }
        output.metadataObjectTypes = [.qr]
        if CameraDiagnostics.enabled {
          let frames = AVCaptureVideoDataOutput()
          frames.alwaysDiscardsLateVideoFrames = true
          if session.canAddOutput(frames) {
            session.addOutput(frames)
            frames.setSampleBufferDelegate(self, queue: frameQueue)
          }
        }
        configured = true
        CameraDiagnostics.record(
          "configured",
          [
            "instance": diagnosticID, "inputs": session.inputs.count,
            "outputs": session.outputs.count, "connections": session.connections.count,
          ])
      } catch { DispatchQueue.main.async { self.failed() } }
    }
  }
  func start() {
    queue.async {
      CameraDiagnostics.record(
        "start_requested",
        [
          "instance": self.diagnosticID, "configured": self.configured,
          "running": self.session.isRunning, "interrupted": self.session.isInterrupted,
        ])
      if self.configured && !self.session.isRunning {
        self.session.startRunning()
        CameraDiagnostics.record(
          "start_returned",
          [
            "instance": self.diagnosticID, "running": self.session.isRunning,
            "interrupted": self.session.isInterrupted,
          ])
        DispatchQueue.main.async { self.onRunning?() }
      }
    }
  }
  func stop() {
    queue.async {
      CameraDiagnostics.record(
        "stop_requested", ["instance": self.diagnosticID, "running": self.session.isRunning])
      if self.session.isRunning { self.session.stopRunning() }
    }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !receivedFrame else { return }
    receivedFrame = true
    CameraDiagnostics.record(
      "first_video_frame",
      ["instance": diagnosticID, "ready": CMSampleBufferDataIsReady(sampleBuffer)])
  }
  func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !received else { return }
    for item in metadataObjects {
      guard let code = item as? AVMetadataMachineReadableCodeObject, let value = code.stringValue,
        value.hasPrefix("healthbridge://connect")
      else { continue }
      received = true
      stop()
      receive(value)
      break
    }
  }
}

final class CameraScannerController: UIViewController {
  let capture: BarcodeCapture
  private lazy var preview = AVCaptureVideoPreviewLayer(session: capture.session)
  init(receive: @escaping (String) -> Void, failed: @escaping () -> Void) {
    capture = BarcodeCapture(receive: receive, failed: failed)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  override func viewDidLoad() {
    super.viewDidLoad()
    CameraDiagnostics.record("view_loaded", ["instance": capture.diagnosticID])
    view.backgroundColor = .black
    capture.onRunning = { [weak self] in self?.view.setNeedsLayout() }
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    let guide = UILabel()
    guide.text = "将连接码放入画面"
    guide.textColor = .white
    guide.font = .preferredFont(forTextStyle: .body)
    guide.adjustsFontForContentSizeCategory = true
    guide.textAlignment = .center
    guide.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    guide.layer.cornerRadius = 12
    guide.clipsToBounds = true
    guide.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(guide)
    NSLayoutConstraint.activate([
      guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      guide.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      guide.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
      guide.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
    ])
    capture.configure()
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    CameraDiagnostics.record(
      "view_appeared", ["instance": capture.diagnosticID, "in_window": view.window != nil])
    capture.start()
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    CameraDiagnostics.record("view_disappeared", ["instance": capture.diagnosticID])
    capture.stop()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview.frame = view.bounds
    CameraDiagnostics.record(
      "layout",
      [
        "instance": capture.diagnosticID, "width": view.bounds.width, "height": view.bounds.height,
        "preview_connected": preview.connection != nil,
        "preview_active": preview.connection?.isActive ?? false,
        "preview_enabled": preview.connection?.isEnabled ?? false, "in_window": view.window != nil,
      ])
    let angle: CGFloat
    switch view.window?.windowScene?.interfaceOrientation {
    case .landscapeLeft: angle = 0
    case .landscapeRight: angle = 180
    case .portraitUpsideDown: angle = 270
    default: angle = 90
    }
    if let connection = preview.connection, connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
  }
}
