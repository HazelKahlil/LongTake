//
//  SCContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AVFAudio
import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications
import SwiftLAME
import SwiftUI
import AECAudioStream

class SCContext {
    static var trimingList = [URL]()
    static var firstFrame: CMSampleBuffer?
    static var autoStop = 0
    static var recordCam = ""
    static var recordDevice = ""
    static var captureSession: AVCaptureSession!
    static var previewSession: AVCaptureSession!
    static var frameCache: CMSampleBuffer?
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    static var isSkipFrame = false
    static var lastPTS: CMTime?
    static var timeOffset = CMTimeMake(value: 0, timescale: 0)
    static var screenArea: NSRect?
    static let audioEngine = AVAudioEngine()
    static let AECEngine = AECAudioStream(sampleRate: 48000)
    static var backgroundColor: CGColor = CGColor.black
    static var filePath: String!
    static var filePath1: String!
    static var filePath2: String!
    static var audioFile: AVAudioFile?
    static var audioFile2: AVAudioFile?
    static var activeSessionRecordsMic = false
    private static let audioFileWriteQueue = DispatchQueue(label: "longtake.audioFileWrite")
    static var vW: AVAssetWriter!
    static var vwInput, awInput, micInput: AVAssetWriterInput!
    static var startTime: Date?
    static var pauseStartTime: Date?
    static var totalMicPausedSeconds: TimeInterval = 0
    static var timePassed: TimeInterval = 0
    static var stream: SCStream!
    static var screen: SCDisplay?
    static var window: [SCWindow]?
    static var application: [SCRunningApplication]?
    static var streamType: StreamType?
    static var availableContent: SCShareableContent?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]
    
    private static var isShowingPermissionAlert = false

    static func updateAvailableContentSync() -> SCShareableContent? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent? = nil

        updateAvailableContent { content in
            result = content
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5.0)
        return result
    }
    
    private static func updateAvailableContent(completion: @escaping (SCShareableContent?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error = error {
                print("Error: failed to fetch available content: ".local, error.localizedDescription)
                completion(nil)
                return
            }

            availableContent = content
            if let displays = content?.displays, !displays.isEmpty {
                completion(content)
            } else {
                print("There needs to be at least one display connected!".local)
                completion(nil)
            }
        }
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        if !CGPreflightScreenCaptureAccess() && !ud.bool(forKey: "hasTriggeredSystemScreenCapturePrompt") {
            ud.set(true, forKey: "hasTriggeredSystemScreenCapturePrompt")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let granted = CGRequestScreenCaptureAccess()
                if granted {
                    fetchShareableContent(completion: completion)
                }
            }
            return
        }
        fetchShareableContent(completion: completion)
    }

    private static func fetchShareableContent(completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined: requestPermissions()
                default: print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                return
            }
            availableContent = content
            assert(availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected!".local)
            completion()
        }
    }
    
    static func getSelf() -> SCRunningApplication? {
        return SCContext.availableContent!.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }
    
    static func getSelfWindows() -> [SCWindow]? {
        return SCContext.availableContent!.windows.filter( {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != "Mouse Pointer".local
            && title != "Screen Magnifier".local
            && title != "Camera Overlayer".local
            && title != "iDevice Overlayer".local
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).map({ $0.owningApplication }) {
            if !apps.contains(app!) { apps.append(app!) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return apps
    }
    
    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        var windows = [SCWindow]()
        windows = availableContent!.windows.filter {
            guard let app =  $0.owningApplication,
                  let title = $0.title else {//, !title.isEmpty else {
                return false
            }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
        }
        if isOnScreen { windows = windows.filter({$0.isOnScreen == true}) }
        if hideSelf && ud.bool(forKey: "hideSelf") { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return windows
    }
    
    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon!.size = NSSize(width: 69, height: 69)
        return icon
    }
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func getSCDisplayWithMouse() -> SCDisplay? {
        if let displays = availableContent?.displays {
            for display in displays {
                if let currentDisplayID = getScreenWithMouse()?.displayID {
                    if display.displayID == currentDisplayID {
                        return display
                    }
                }
            }
        }
        return nil
    }
    
    static func getFilePath(capture: Bool = false) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        return ud.string(forKey: "saveDirectory")! + (capture ? "/Capturing at ".local : "/Recording at ".local) + dateFormatter.string(from: Date())
    }
    
    static func updateAudioSettings(format: String = ud.string(forKey: "audioFormat") ?? "", rate: Int = 48000) -> [String : Any] {
        var audioSettings: [String : Any] = [AVSampleRateKey : rate, AVNumberOfChannelsKey : 2] // reset audioSettings
        var bitRate = ud.integer(forKey: "audioQuality") * 1000
        if rate < 44100 { bitRate = min(64000, bitRate / 2) }
        switch format {
        case AudioFormat.mp3.rawValue: fallthrough
        case AudioFormat.aac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        case AudioFormat.alac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case AudioFormat.flac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatFLAC
        case AudioFormat.opus.rawValue:
            audioSettings[AVFormatIDKey] = ud.string(forKey: "videoFormat") != VideoFormat.mp4.rawValue ? kAudioFormatOpus : kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] =  bitRate
        default:
            assertionFailure("unknown audio format while setting audio settings: ".local + (ud.string(forKey: "audioFormat") ?? "[no defaults]".local))
        }
        return audioSettings
    }
    
    static func getBackgroundColor() -> CGColor {
        guard let color = ud.string(forKey: "background") else { return CGColor.black  }
        if color == BackgroundType.wallpaper.rawValue { return CGColor.black }
        switch color {
            case "clear": backgroundColor = CGColor.clear
            case "black": backgroundColor = CGColor.black
            case "white": backgroundColor = CGColor.white
            case "gray": backgroundColor = NSColor.systemGray.cgColor
            case "yellow": backgroundColor = NSColor.systemYellow.cgColor
            case "orange": backgroundColor = NSColor.systemOrange.cgColor
            case "green": backgroundColor = NSColor.systemGreen.cgColor
            case "blue": backgroundColor = NSColor.systemBlue.cgColor
            case "red": backgroundColor = NSColor.systemRed.cgColor
            default: backgroundColor = ud.cgColor(forKey: "userColor") ?? CGColor.black
        }
        return backgroundColor
    }
    
    static func performMicCheck() async {
        guard ud.bool(forKey: "recordMic") == true else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        ud.setValue(false, forKey: "recordMic")
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "LongTake needs permission to record your microphone.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    
    private static func requestPermissions() {
        DispatchQueue.main.async {
            guard !isShowingPermissionAlert else { return }
            isShowingPermissionAlert = true
            defer { isShowingPermissionAlert = false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = createAlert(title: "Permission Required",
                                                       message: "LongTake needs screen recording permissions, even if you only intend on recording audio.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
    }
    
    static func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized, .restricted, .notDetermined:
            break
        case .denied:
            DispatchQueue.main.async {
                let alert = createAlert(title: "Permission Required",
                                                           message: "LongTake needs this permission to record your camera or mobile device.",
                                                           button1: "Open Settings",
                                                           button2: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        @unknown default:
            break
        }
    }
    
    static func getWallpaper(_ display: SCDisplay) -> NSImage? {
        guard let screen = display.nsScreen else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        do {
            var wallpaper: NSImage?
            try wallpaper = NSImage(data: Data(contentsOf: url))
            if let w = wallpaper { return w }
        } catch {
            print("load wallpaper error: \(error)")
        }
        return nil
    }
    
    static func getRecordingSize() -> String {
        do {
            let fileAttr = try fd.attributesOfItem(atPath: filePath)
            let byteFormat = ByteCountFormatter()
            byteFormat.allowedUnits = [.useMB]
            byteFormat.countStyle = .file
            return byteFormat.string(fromByteCount: fileAttr[FileAttributeKey.size] as! Int64)
        } catch {
            print(String(format: "failed to fetch file for size indicator: %@".local, error.localizedDescription))
        }
        return "Unknown".local
    }
    
    static func getRecordingLength() -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        if isPaused { return formatter.string(from: timePassed) ?? "Unknown".local }
        timePassed = Date.now.timeIntervalSince(startTime ?? Date.now)
        return formatter.string(from: timePassed) ?? "Unknown".local
    }
    
    static func isCameraRunning() -> Bool {
        var preview = false
        var capture = false
        if let session = previewSession { preview = session.isRunning }
        if let session = captureSession { capture = session.isRunning }
        return (preview || capture)
    }
    
    // MARK: - 音频文件线程安全写入与导出保护
    static func openSystemAudioFile(at url: URL, settings: [String: Any]) {
        audioFileWriteQueue.sync {
            audioFile = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    static func writeSystemAudioSamples(_ samples: AVAudioPCMBuffer) {
        audioFileWriteQueue.sync {
            guard let file = audioFile else { return }
            do {
                try file.write(from: samples)
            } catch {
                print("System audio write error: \(error.localizedDescription)")
            }
        }
    }

    static func closeSystemAudioFile() {
        audioFileWriteQueue.sync {
            audioFile = nil
            audioFile2 = nil
        }
    }

    private static let audioExportQueue = DispatchQueue(label: "quickrecorder.audioExport")
    private static var _audioExportCount = 0
    private static var _audioExportWaiters: [() -> Void] = []
    private static let stopLock = NSLock()
    private static var _isStopping = false
    private static let pendingRemuxDefaultsKey = "longTakePendingRemuxPaths"

    static var audioExportsInProgress: Int {
        audioExportQueue.sync { _audioExportCount }
    }

    static func beginAudioExport() {
        audioExportQueue.sync { _audioExportCount += 1 }
    }

    static func endAudioExport() {
        var callbacks: [() -> Void] = []
        audioExportQueue.sync {
            _audioExportCount = max(0, _audioExportCount - 1)
            if _audioExportCount == 0 {
                callbacks = _audioExportWaiters
                _audioExportWaiters = []
            }
        }
        for cb in callbacks { DispatchQueue.main.async { cb() } }
    }

    static func whenAudioExportsFinished(_ callback: @escaping () -> Void) {
        let done = audioExportQueue.sync { _audioExportCount == 0 }
        if done {
            DispatchQueue.main.async { callback() }
        } else {
            audioExportQueue.sync { _audioExportWaiters.append(callback) }
        }
    }

    static func markPendingRemux(qmaPath: String) {
        audioExportQueue.sync {
            var list = ud.stringArray(forKey: pendingRemuxDefaultsKey) ?? []
            if !list.contains(qmaPath) {
                list.append(qmaPath)
                ud.set(list, forKey: pendingRemuxDefaultsKey)
                ud.synchronize()
            }
        }
    }

    static func clearPendingRemux(qmaPath: String) {
        audioExportQueue.sync {
            var list = ud.stringArray(forKey: pendingRemuxDefaultsKey) ?? []
            list.removeAll { $0 == qmaPath }
            ud.set(list, forKey: pendingRemuxDefaultsKey)
            ud.synchronize()
        }
    }

    static func recoverPendingRemuxesIfNeeded() {
        let pending = audioExportQueue.sync { ud.stringArray(forKey: pendingRemuxDefaultsKey) ?? [] }
        guard !pending.isEmpty else { return }
        for qmaPath in pending {
            let fileURL = URL(fileURLWithPath: qmaPath)
            guard fd.fileExists(atPath: qmaPath),
                  let info = try? qmaPackageHandle.loadInfo(from: fileURL) else {
                clearPendingRemux(qmaPath: qmaPath)
                continue
            }
            let format = info.exportMP3 ? "mp3" : info.format
            let saveURL = fileURL.deletingPathExtension().appendingPathExtension(format)
            if let attrs = try? fd.attributesOfItem(atPath: saveURL.path),
               let size = attrs[.size] as? Int64,
               size > 1024 {
                clearPendingRemux(qmaPath: qmaPath)
                continue
            }
            let manager = AudioPlayerManager(forOfflineExportOnly: true)
            manager.loadAudioFiles(format: info.format, package: fileURL, encoder: info.encoder, saveMP3: info.exportMP3)
            manager.sysVol = info.sysVol
            manager.micVol = info.micVol
            manager.saveFile(saveURL, saveAsMP3: info.exportMP3, sourceQMAPath: qmaPath, isRecovery: true)
        }
    }

    static func pauseRecording() {
        if !isPaused {
            if let start = startTime {
                timePassed = Date.now.timeIntervalSince(start)
            }
            pauseStartTime = Date.now
            isPaused = true
        } else {
            if let pStart = pauseStartTime {
                totalMicPausedSeconds += Date.now.timeIntervalSince(pStart)
            }
            pauseStartTime = nil
            startTime = Date.now.addingTimeInterval(-timePassed)
            isResume = true
            isPaused = false
        }
        PopoverState.shared.isPaused = isPaused
        updateStatusBar()
    }
    
    static func stopRecording() {
        stopLock.lock()
        if _isStopping || (stream == nil && streamType == nil) {
            stopLock.unlock()
            return
        }
        _isStopping = true
        let currentStreamType = streamType
        let currentFilePath = filePath ?? ""
        let currentFilePath1 = filePath1 ?? ""
        let recordedMic = activeSessionRecordsMic
        let activeStream = stream
        stream = nil
        stopLock.unlock()
        defer {
            stopLock.lock()
            _isStopping = false
            activeSessionRecordsMic = false
            stopLock.unlock()
        }

        if ud.bool(forKey: "preventSleep") { SleepPreventer.shared.allowSleep() }
        autoStop = 0
        lastPTS = nil
        recordCam = ""
        recordDevice = ""
        isMagnifierEnabled = false
        mousePointer.orderOut(nil)
        screenMagnifier.orderOut(nil)
        AppDelegate.shared.stopGlobalMouseMonitor()

        if let w = NSApp.windows.first(where:  { $0.title == "Area Overlayer".local }) { w.close() }
        
        if activeStream != nil { activeStream?.stopCapture() }
        if recordedMic {
            micInput?.markAsFinished()
            AudioRecorder.shared.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            if ud.bool(forKey: "enableAEC") { try? AECEngine.stopAudioUnit() }
        }
        if currentStreamType != .systemaudio {
            if let writer = vW, writer.status == .writing {
                let dispatchGroup = DispatchGroup()
                dispatchGroup.enter()
                vwInput?.markAsFinished()
                if #available(macOS 13, *) { awInput?.markAsFinished() }
                let shouldRemuxVideoAudio = recordedMic && ud.bool(forKey: "recordWinSound") && ud.bool(forKey: "remuxAudio")
                if shouldRemuxVideoAudio {
                    beginAudioExport()
                }
                writer.finishWriting {
                    if writer.status != .completed {
                        if shouldRemuxVideoAudio { endAudioExport() }
                        print("Video writing failed with status: \(writer.status), error: \(String(describing: writer.error))")
                        let err = writer.error?.localizedDescription ?? "Unknow Error"
                        showNotification(title: "Failed to save file".local, body: "\(err)", id: "quickrecorder.error.\(UUID().uuidString)")
                    } else if shouldRemuxVideoAudio {
                        mixAudioTracks(videoURL: currentFilePath.url) { result in
                            defer { endAudioExport() }
                            switch result {
                            case .success(let url):
                                print("Exported video to \(String(describing: url.path))")
                                if !ud.bool(forKey: "showPreview") {
                                    showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, url.path), id: "quickrecorder.completed.\(UUID().uuidString)")
                                }
                                DispatchQueue.main.async {
                                    if ud.bool(forKey: "trimAfterRecord") {
                                        AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
                                    } else {
                                        showPreview(path: url.path)
                                    }
                                }
                            case .failure(let error):
                                print("Failed to export video: \(error.localizedDescription)")
                                showNotification(title: "Failed to save file".local, body: error.localizedDescription, id: "quickrecorder.error.\(UUID().uuidString)")
                            }
                        }
                    }
                    dispatchGroup.leave()
                }
                _ = dispatchGroup.wait(timeout: .now() + 20.0)
            }
        } else {
            // 关键根因修复: 必须同步等待麦克风音轨 AVAssetWriter 完成 moov 索引落盘后, 才能读取 mic.m4a 进行混音
            if recordedMic, let writer = vW, writer.status == .writing {
                let micWriterGroup = DispatchGroup()
                micWriterGroup.enter()
                writer.finishWriting {
                    micWriterGroup.leave()
                }
                _ = micWriterGroup.wait(timeout: .now() + 15.0)
            }
        }
        
        DispatchQueue.main.async {
            controlPanel.orderOut(nil)
            if isCameraRunning() {
                if camWindow.isVisible { camWindow.close() }
                if deviceWindow.isVisible { deviceWindow.close() }
                if let preview = previewSession { preview.stopRunning() }
                if let capture = captureSession { capture.stopRunning() }
            }
        }
        
        closeSystemAudioFile()
        if currentStreamType == .systemaudio {
            if ud.string(forKey: "audioFormat") == AudioFormat.mp3.rawValue && !recordedMic {
                beginAudioExport()
                Task {
                    defer { endAudioExport() }
                    let outPutUrl = (String(currentFilePath.dropLast(4)) + ".mp3").url
                    let stagingUrl = outPutUrl.deletingLastPathComponent().appendingPathComponent(".longtake-staging-\(UUID().uuidString).mp3")
                    defer { try? fd.removeItem(at: stagingUrl) }
                    do {
                        try await m4a2mp3(inputUrl: currentFilePath1.url, outputUrl: stagingUrl)
                        if fd.fileExists(atPath: outPutUrl.path) {
                            _ = try fd.replaceItemAt(outPutUrl, withItemAt: stagingUrl)
                        } else {
                            try fd.moveItem(at: stagingUrl, to: outPutUrl)
                        }
                        try? fd.removeItem(atPath: currentFilePath1)
                        if !ud.bool(forKey: "showPreview") {
                            let title = "Recording Completed".local
                            let body = String(format: "File saved to: %@".local, outPutUrl.path.removingPercentEncoding ?? outPutUrl.path)
                            let id = "quickrecorder.completed.\(UUID().uuidString)"
                            showNotification(title: title, body: body, id: id)
                        } else {
                            DispatchQueue.main.async { showPreview(path: outPutUrl.path, image: NSImage(named: "audioIcon")) }
                        }
                    } catch {
                        showNotification(title: "Failed to save file".local, body: "\(error.localizedDescription)", id: "quickrecorder.error.\(UUID().uuidString)")
                    }
                }
            } else {
                if ud.bool(forKey: "remuxAudio") && recordedMic {
                    let fileURL = currentFilePath.url
                    if let info = try? qmaPackageHandle.loadInfo(from: fileURL) {
                        markPendingRemux(qmaPath: currentFilePath)
                        let audioPlayerManager = AudioPlayerManager(forOfflineExportOnly: true)
                        audioPlayerManager.loadAudioFiles(format: info.format, package: fileURL, encoder: info.encoder, saveMP3: info.exportMP3)
                        audioPlayerManager.sysVol = info.sysVol
                        audioPlayerManager.micVol = info.micVol
                        let exportMP3 = info.exportMP3
                        let format = exportMP3 ? "mp3" : info.format
                        let saveURL = fileURL.deletingPathExtension().appendingPathExtension(format)
                        audioPlayerManager.saveFile(saveURL, saveAsMP3: exportMP3, sourceQMAPath: currentFilePath)
                    } else {
                        showNotification(title: "Failed to save file".local, body: "Unable to read .qma metadata.", id: "quickrecorder.error.\(UUID().uuidString)")
                    }
                } else {
                    if !ud.bool(forKey: "showPreview") {
                        let title = "Recording Completed".local
                        let body = String(format: "File saved to: %@".local, currentFilePath)
                        let id = "quickrecorder.completed.\(UUID().uuidString)"
                        showNotification(title: title, body: body, id: id)
                    } else {
                        showPreview(path: currentFilePath, image: NSImage(named: "qmaIcon"))
                    }
                }
            }
        }
        
        isPaused = false
        PopoverState.shared.isPaused = false
        pauseStartTime = nil
        totalMicPausedSeconds = 0
        timePassed = 0
        hideMousePointer = false
        window = nil
        screen = nil
        startTime = nil
        AppDelegate.shared.presenterType = "OFF"
        streamType = nil
        firstFrame = nil
        updateStatusBar()
        
        if !(recordedMic && ud.bool(forKey: "recordWinSound") && ud.bool(forKey: "remuxAudio")) && currentStreamType != .systemaudio {
            if let vW = vW {
                if vW.status != .completed {
                    return
                }
            }
            if !ud.bool(forKey: "showPreview") {
                let title = "Recording Completed".local
                let body = String(format: "File saved to: %@".local, currentFilePath)
                let id = "quickrecorder.completed.\(UUID().uuidString)"
                showNotification(title: title, body: body, id: id)
            } else {
                showPreview(path: currentFilePath)
            }
            trimVideo()
        }
    }
    
    static func showPreview(path: String, image: NSImage? = nil) {
        if !ud.bool(forKey: "showPreview") { return }
        var previewImage: NSImage?
        let previewURL = fd.temporaryDirectory.appendingPathComponent("qr-preview.jpg")
        if image == nil { firstFrame?.nsImage?.saveToFile(previewURL, type: .jpeg) }
        
        if let i = image { previewImage = i } else { previewImage = NSImage(contentsOf: previewURL) }
        if let previewImage = previewImage, let screen = getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFrontRegardless()
        }
    }
    
    static func m4a2mp3(inputUrl: URL, outputUrl: URL) async throws {
        let progress = Progress()
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(Int32(ud.integer(forKey: "audioQuality"))),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress // optional
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }
    
    static func trimVideo() {
        if ud.bool(forKey: "trimAfterRecord") {
            let fileURL = filePath.url
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: fileURL), title: fileURL.lastPathComponent, only: false)
        }
    }
    
    static func getCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getMicrophone() -> [AVCaptureDevice] {
        var discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        }
        return discoverySession.devices.filter({ !$0.localizedName.contains("CADefaultDeviceAggregate") })
    }
    
    static func getiDevice() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .muxed, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getCurrentMic() -> AVCaptureDevice? {
        let deviceName = ud.string(forKey: "micDevice")
        return getMicrophone().first(where: { $0.localizedName == deviceName })
    }
    
    /*static func getChannelCount() -> Int? {
        if let device = getCurrentMic() {
            if let channels = device.formats.first?.formatDescription.audioChannelLayout?.numberOfChannels {
                return channels
            }
            
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let channelCount = audioStreamBasicDescription.mChannelsPerFrame
                return max(2, Int(channelCount))
            }
        }
        return getDefaultChannelCount()
    }
    
    static func getDefaultChannelCount() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取通道数
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // 查询流配置信息
        var streamConfig: UnsafeMutableAudioBufferListPointer?
        propertySize = 0
        
        // 先获取属性大小
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr else {
            print("Failed to get size for stream configuration")
            return nil
        }
        
        // 分配内存以存储音频流配置
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferList.deallocate() }
        
        let configStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        guard configStatus == noErr else {
            print("Failed to get stream configuration")
            return nil
        }
        
        streamConfig = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // 计算通道总数
        var totalChannels = 0
        for buffer in streamConfig! {
            totalChannels += Int(buffer.mNumberChannels)
        }
        return max(2, totalChannels)
    }*/
    
    static func getSampleRate() -> Int? {
        if let device = getCurrentMic() {
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let sampleRate = audioStreamBasicDescription.mSampleRate
                return Int(sampleRate)
            }
        }
        return getDefaultSampleRate()
    }
    
    static func getDefaultSampleRate() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取采样率
        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout.size(ofValue: sampleRate))
        
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let sampleRateStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &sampleRate
        )
        
        guard sampleRateStatus == noErr else {
            print("Failed to get sample rate for the default input device")
            return nil
        }
        
        return Int(sampleRate)
    }
    
    static func adjustTime(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetFormatDescription(sample) != nil else { return nil }
        
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(CMSampleBufferGetNumSamples(sample)))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingInfo.count, arrayToFill: &timingInfo, entriesNeededOut: nil)
        
        for i in 0..<timingInfo.count {
            timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, offset)
            timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, offset)
        }
        
        var outSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: timingInfo.count, sampleTimingArray: &timingInfo, sampleBufferOut: &outSampleBuffer)
        
        return outSampleBuffer
    }
    
    static func showNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification failed to send：\(error.localizedDescription)") }
        }
    }
    
    static func mixAudioTracks(videoURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        showNotification(title: "Still Processing".local, body: "Mixing audio track...".local, id: "quickrecorder.processing.\(UUID().uuidString)")
        
        let asset = AVAsset(url: videoURL)
        let audioOutputURL = videoURL.deletingPathExtension()
        let outputURL = audioOutputURL.deletingPathExtension()
        let audioOnlyComposition = AVMutableComposition()
        
        let fileEnding = ud.string(forKey: "videoFormat") ?? ""
        var fileType: AVFileType?
        switch fileEnding {
        case VideoFormat.mov.rawValue: fileType = AVFileType.mov
        case VideoFormat.mp4.rawValue: fileType = AVFileType.mp4
        default: assertionFailure("loaded unknown video format".local)
        }
        
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
            return
        }
        
        for audioTrack in audioTracks {
            if let compositionAudioTrack = audioOnlyComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                    return
                }
            }
        }
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioTracks.map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.trackID = $0.trackID
            return parameters
        }
        
        guard let audioExportSession = AVAssetExportSession(asset: audioOnlyComposition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "AudioExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio export session."])))
            return
        }
        audioExportSession.outputURL = audioOutputURL
        audioExportSession.outputFileType = fileType ?? .mp4
        audioExportSession.audioMix = audioMix
        
        audioExportSession.exportAsynchronously {
            /*var exportStatus: AVAssetExportSession.Status = .unknown
            
            // Loop until export session is completed, failed, or cancelled
            while exportStatus != .completed && exportStatus != .failed && exportStatus != .cancelled {
                exportStatus = audioExportSession.status
                Thread.sleep(forTimeInterval: 0.1)
            }*/
            
            switch audioExportSession.status {
            case .completed:
                let audioAsset = AVAsset(url: audioOutputURL)
                let composition = AVMutableComposition()
                
                guard let videoTrack = asset.tracks(withMediaType: .video).first,
                      let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    completion(.failure(NSError(domain: "VideoTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get video track."])))
                    return
                }
                
                do {
                    try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "VideoTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert video track: \(error.localizedDescription)"])))
                    return
                }
                
                let audioTracks = audioAsset.tracks(withMediaType: .audio)
                guard audioTracks.count >= 1 else {
                    completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
                    return
                }
                
                for audioTrack in audioTracks {
                    if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        do {
                            try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                        } catch {
                            completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                            return
                        }
                    }
                }
                
                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    completion(.failure(NSError(domain: "ExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session."])))
                    return
                }
                
                exportSession.outputURL = outputURL
                exportSession.outputFileType = fileType ?? .mp4
                exportSession.audioMix = audioMix
                
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        let fileManager = fd
                        try? fileManager.removeItem(at: videoURL)
                        try? fileManager.removeItem(at: audioOutputURL)
                        completion(.success(outputURL))
                    case .failed:
                        completion(.failure(exportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
                    case .cancelled:
                        completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
                    default:
                        break
                    }
                }
            case .failed:
                completion(.failure(audioExportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
            case .cancelled:
                completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
            default:
                break
            }
        }
    }
}
