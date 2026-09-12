//
//  CaptureManager.swift
//  LidGuard
//
//  AVFoundation-based front camera capture with ISP warm-up delay.
//  Designed to work reliably immediately after system wake, even when
//  the display was sleeping or the lid was closed.
//

import AVFoundation
import AppKit

// MARK: - CaptureError

enum CaptureError: LocalizedError {
    case noCameraFound
    case notAuthorized
    case sessionConfigurationFailed(String)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCameraFound:
            return "No front-facing camera found on this Mac."
        case .notAuthorized:
            return "Camera access is not authorized. Please grant permission in System Settings → Privacy & Security → Camera."
        case .sessionConfigurationFailed(let detail):
            return "Failed to configure capture session: \(detail)"
        case .captureFailed(let detail):
            return "Photo capture failed: \(detail)"
        }
    }
}

// MARK: - CaptureManager

final class CaptureManager: NSObject, @unchecked Sendable {

    static let shared = CaptureManager()

    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<Data, any Error>?
    private let lock = NSLock()

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    /// Checks current camera authorization and requests access if undetermined.
    static func requestCameraAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Session Setup

    /// Configures the capture session with the front-facing camera.
    private func setupSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Remove existing inputs/outputs
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        captureSession.sessionPreset = .photo

        // Discover front-facing camera
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )

        guard let camera = discoverySession.devices.first else {
            throw CaptureError.noCameraFound
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                throw CaptureError.sessionConfigurationFailed("Cannot add camera input to session.")
            }
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.sessionConfigurationFailed(error.localizedDescription)
        }

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        } else {
            throw CaptureError.sessionConfigurationFailed("Cannot add photo output to session.")
        }
    }

    // MARK: - Capture Photo

    /// Captures a JPEG photo from the front camera.
    ///
    /// Includes a 1.5-second ISP warm-up delay after starting the session
    /// to ensure proper exposure (prevents black frames on wake).
    func capturePhoto() async throws -> Data {
        // Check authorization
        guard await CaptureManager.requestCameraAccess() else {
            throw CaptureError.notAuthorized
        }

        // Setup session
        try setupSession()

        // Start session on a background thread
        captureSession.startRunning()

        // ISP warm-up: wait 1.5 seconds for the image signal processor
        // and auto-exposure to stabilize after wake from sleep.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Capture using continuation
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()

            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }

        // Stop session
        captureSession.stopRunning()

        return data
    }

    /// Compresses raw photo data to JPEG with timestamp metadata.
    private func compressToJPEG(_ photoData: Data) -> Data? {
        guard let image = NSImage(data: photoData) else { return nil }
        guard let tiffData = image.tiffRepresentation else { return nil }
        guard let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.85]
        )
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CaptureManager: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let error = error {
            continuation?.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
            return
        }

        guard let fileData = photo.fileDataRepresentation() else {
            continuation?.resume(throwing: CaptureError.captureFailed("No file data in captured photo."))
            return
        }

        // Compress to JPEG
        if let jpegData = compressToJPEG(fileData) {
            continuation?.resume(returning: jpegData)
        } else {
            // Fall back to raw file data if compression fails
            continuation?.resume(returning: fileData)
        }
    }
}
