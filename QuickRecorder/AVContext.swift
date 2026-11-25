//
//  AVContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/27.
//

import AppKit
import Foundation
import AVFoundation
import UserNotifications

extension AppDelegate {
    func recordingCamera(with device: AVCaptureDevice) {
        AVOutputClass.shared.startCameraOverlay(with: device)
    }

    func closeCamera() {
        AVOutputClass.shared.stopCameraOverlay()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 保留 delegate 协议实现
    }
}

/// 隔离管理摄像头叠层、移动设备叠层与移动设备录屏三个独立会话，杜绝共享会话覆盖与 Quit 提前截断（P0-4 / P1-11）
class AVOutputClass: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = AVOutputClass()

    private let sessionQueue = DispatchQueue(label: "com.kahlilhazel.longtake.avSessions")
    private var cameraOverlaySession: AVCaptureSession?
    private var iDeviceCaptureSession: AVCaptureSession?
    private var iDevicePreviewSession: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private var dataOutput: AVCaptureVideoDataOutput?

    private var cameraGeneration: UInt64 = 0
    private var deviceGeneration: UInt64 = 0
    private var isStoppingDeviceRecording = false
    private var activeDeviceRecordingPath: String?

    var activeCameraSession: AVCaptureSession? {
        sessionQueue.sync { cameraOverlaySession }
    }

    var activeDevicePreviewSession: AVCaptureSession? {
        sessionQueue.sync { iDevicePreviewSession }
    }

    var isRecordingDevice: Bool {
        sessionQueue.sync { output?.isRecording == true || isStoppingDeviceRecording }
    }

    func isAnyCameraOrDeviceActive() -> Bool {
        sessionQueue.sync {
            (cameraOverlaySession?.isRunning == true) ||
            (iDeviceCaptureSession?.isRunning == true) ||
            (iDevicePreviewSession?.isRunning == true)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}

    // MARK: - 独立摄像头叠层

    func startCameraOverlay(with device: AVCaptureDevice) {
        sessionQueue.async {
            self.cameraGeneration &+= 1
            let gen = self.cameraGeneration
            self.teardownCameraOverlayOnQueue()

            let session = AVCaptureSession()
            guard let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                print("Failed to set up camera")
                SCContext.requestCameraPermission()
                return
            }
            session.addInput(input)
            self.cameraOverlaySession = session
            SCContext.captureSession = session
            session.startRunning()

            DispatchQueue.main.async {
                let stillValid = self.sessionQueue.sync { self.cameraGeneration == gen && self.cameraOverlaySession === session }
                guard stillValid else { return }
                AppDelegate.shared.startCameraOverlayer()
            }
        }
    }

    func stopCameraOverlay() {
        sessionQueue.async {
            self.cameraGeneration &+= 1
            self.teardownCameraOverlayOnQueue()
        }
        DispatchQueue.main.async {
            if camWindow.isVisible { camWindow.close() }
        }
    }

    private func teardownCameraOverlayOnQueue() {
        if let session = cameraOverlaySession {
            if session.isRunning { session.stopRunning() }
            cameraOverlaySession = nil
        }
    }

    // MARK: - 独立移动设备录制 / 预览叠层

    public func startRecording(with device: AVCaptureDevice, mute: Bool = false, preset: AVCaptureSession.Preset = .high, didOutput: Bool = true) {
        if SCContext.isTerminating { return }
        sessionQueue.async {
            self.deviceGeneration &+= 1
            let gen = self.deviceGeneration
            self.teardownDeviceSessionsOnQueue()

            let previewSession = AVCaptureSession()
            previewSession.sessionPreset = preset
            let dataOut = AVCaptureVideoDataOutput()
            dataOut.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .utility))

            guard let previewInput = try? AVCaptureDeviceInput(device: device),
                  previewSession.canAddInput(previewInput),
                  previewSession.canAddOutput(dataOut) else {
                print("Failed to set up mobile device preview")
                SCContext.requestCameraPermission()
                return
            }
            previewSession.addInput(previewInput)
            previewSession.addOutput(dataOut)
            self.iDevicePreviewSession = previewSession
            self.dataOutput = dataOut
            SCContext.previewSession = previewSession

            if didOutput {
                let captureSession = AVCaptureSession()
                captureSession.sessionPreset = preset
                let movieOut = AVCaptureMovieFileOutput()
                guard let capInput = try? AVCaptureDeviceInput(device: device),
                      captureSession.canAddInput(capInput),
                      captureSession.canAddOutput(movieOut) else {
                    print("Failed to set up mobile device capture")
                    self.teardownDeviceSessionsOnQueue()
                    SCContext.requestCameraPermission()
                    return
                }
                captureSession.addInput(capInput)
                captureSession.addOutput(movieOut)

                if mute, let audioConnection = movieOut.connection(with: .audio) {
                    captureSession.removeConnection(audioConnection)
                }

                guard let connection = movieOut.connection(with: .video) else {
                    self.teardownDeviceSessionsOnQueue()
                    return
                }
                let encoderIsH265 = ud.string(forKey: "encoder") == Encoder.h265.rawValue
                let videoSettings: [String: Any] = [AVVideoCodecKey: encoderIsH265 ? AVVideoCodecType.hevc : AVVideoCodecType.h264]
                movieOut.setOutputSettings(videoSettings, for: connection)

                let rawExt = (ud.string(forKey: "videoFormat") ?? VideoFormat.mp4.rawValue).lowercased()
                let fileEnding = rawExt == VideoFormat.mov.rawValue ? VideoFormat.mov.rawValue : VideoFormat.mp4.rawValue
                let uniquePath = "\(SCContext.allocateUniqueFilePath(extensions: [fileEnding])).\(fileEnding)"

                self.iDeviceCaptureSession = captureSession
                self.output = movieOut
                self.activeDeviceRecordingPath = uniquePath
                self.isStoppingDeviceRecording = false

                SCContext.sessionQueue.sync {
                    SCContext.filePath = uniquePath
                    SCContext.streamType = .idevice
                    SCContext.startTime = Date.now
                }

                captureSession.startRunning()
                movieOut.startRecording(to: uniquePath.url, recordingDelegate: self)
            }

            previewSession.startRunning()

            DispatchQueue.main.async {
                let stillValid = self.sessionQueue.sync { self.deviceGeneration == gen && self.iDevicePreviewSession === previewSession }
                guard stillValid else { return }
                if didOutput {
                    closeAllWindow(except: "Area Overlayer".local)
                    updateStatusBar()
                }
                AppDelegate.shared.startDeviceOverlayer(size: NSSize(width: 300, height: 500))
            }
        }
    }

    public func stopRecording() {
        // 同步在 sessionQueue 登记导出保护，确保调用方（尤其是 Quit）在函数返回前即可见进行中的封存任务
        let movieOutToStop: AVCaptureMovieFileOutput? = sessionQueue.sync {
            guard !self.isStoppingDeviceRecording else { return nil }
            if let movieOut = self.output, movieOut.isRecording {
                self.isStoppingDeviceRecording = true
                SCContext.beginAudioExport()
                return movieOut
            }
            self.teardownDeviceSessionsOnQueue()
            return nil
        }

        if let movieOut = movieOutToStop {
            sessionQueue.async {
                movieOut.stopRecording()
            }
        } else {
            SCContext.sessionQueue.sync {
                if SCContext.streamType == .idevice {
                    SCContext.streamType = nil
                    SCContext.startTime = nil
                }
            }
            DispatchQueue.main.async {
                controlPanel.orderOut(nil)
                deviceWindow.close()
                updateStatusBar()
                SparkleUpdaterDelegate.shared.tryResumePendingInstallIfIdle()
            }
        }
    }

    func closePreview() {
        sessionQueue.async {
            self.deviceGeneration &+= 1
            if let preview = self.iDevicePreviewSession {
                if preview.isRunning { preview.stopRunning() }
                self.iDevicePreviewSession = nil
            }
            self.dataOutput = nil
            SCContext.previewSession = nil
        }
        DispatchQueue.main.async {
            if deviceWindow.isVisible { deviceWindow.close() }
        }
    }

    func stopAuxiliaryOverlays() {
        stopCameraOverlay()
        if !isRecordingDevice {
            closePreview()
        }
    }

    private func teardownDeviceSessionsOnQueue() {
        if let cap = iDeviceCaptureSession {
            if cap.isRunning { cap.stopRunning() }
            iDeviceCaptureSession = nil
        }
        if let preview = iDevicePreviewSession {
            if preview.isRunning { preview.stopRunning() }
            iDevicePreviewSession = nil
        }
        output = nil
        dataOutput = nil
        activeDeviceRecordingPath = nil
        SCContext.previewSession = nil
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let wasTrackedStop: Bool = sessionQueue.sync {
            let tracked = self.isStoppingDeviceRecording
            self.isStoppingDeviceRecording = false
            self.teardownDeviceSessionsOnQueue()
            return tracked
        }

        SCContext.sessionQueue.sync {
            if SCContext.streamType == .idevice {
                SCContext.streamType = nil
                SCContext.startTime = nil
            }
        }

        DispatchQueue.main.async {
            controlPanel.orderOut(nil)
            deviceWindow.close()
            updateStatusBar()
        }

        // 校验 error 与 AVErrorRecordingSuccessfullyFinishedKey，避免拔线失败时误报“录制完成”（P1-11）
        let succeeded: Bool
        if let err = error as NSError? {
            succeeded = (err.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
        } else {
            succeeded = true
        }

        if succeeded {
            SCContext.showNotification(
                title: "Recording Completed".local,
                body: String(format: "File saved to: %@".local, outputFileURL.path),
                id: "quickrecorder.completed.\(UUID().uuidString)"
            )
            DispatchQueue.main.async {
                SCContext.showPreview(path: outputFileURL.path)
            }
        } else {
            SCContext.showNotification(
                title: "Failed to save file".local,
                body: error?.localizedDescription ?? "Mobile device recording interrupted.",
                id: "quickrecorder.error.\(UUID().uuidString)"
            )
        }

        if wasTrackedStop {
            SCContext.endAudioExport()
        }
        SparkleUpdaterDelegate.shared.tryResumePendingInstallIfIdle()
    }
}
