import AVFoundation
import UIKit
import Combine

class CameraManager: NSObject, ObservableObject {
    
    @Published var isRunning: Bool = false
    @Published var permissionGranted: Bool = false
    
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.groceryscanner.camera", qos: .userInteractive)
    
    // Callback for each frame
    var onFrame: ((CVPixelBuffer) -> Void)?
    
    // Throttle: detect every N frames
    private var frameCount = 0
    private let frameSkip = 3  // Run inference every 3 frames for performance
    
    override init() {
        super.init()
        checkPermission()
    }
    
    // MARK: - Permission
    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionGranted = granted
                    if granted { self?.setupSession() }
                }
            }
        default:
            permissionGranted = false
        }
    }
    
    // MARK: - Setup Session
    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1920x1080
            
            // Back camera (wide angle)
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                print("Camera setup failed")
                return
            }
            self.session.addInput(input)
            
            // Configure autofocus and exposure for product scanning
            try? device.lockForConfiguration()
            let supportsFocus = device.isFocusModeSupported(.continuousAutoFocus)
            if supportsFocus {
                device.focusMode = .continuousAutoFocus
            }
            let supportsExposure = device.isExposureModeSupported(.continuousAutoExposure)
            if supportsExposure {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            
            // Video output
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            
            // Set landscape orientation for iPad
            if let connection = self.videoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            
            self.session.commitConfiguration()
        }
    }
    
    // MARK: - Start / Stop
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
    
    // MARK: - Toggle torch
    func toggleTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCount += 1
        guard frameCount % frameSkip == 0 else { return }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
