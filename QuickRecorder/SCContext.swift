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

enum MicBackend {
    case none
    case aec
    case audioEngine
    case avCapture
}

final class RecordingSession {
    let id = UUID()
    let streamType: StreamType
    let filePath: String
    let filePath1: String
    let filePath2: String
    let audioFormatRaw: String
    let videoFormatRaw: String
    let recordWinSound: Bool
    let remuxAudio: Bool
    var recordsMic: Bool
    var micBackend: MicBackend = .none

    var stream: SCStream?
    var writer: AVAssetWriter?
    var vwInput: AVAssetWriterInput?
    var awInput: AVAssetWriterInput?
    var micInput: AVAssetWriterInput?
    var systemAudioFile: AVAudioFile?

    var firstFrame: CMSampleBuffer?
    var startTime: Date?
    var pauseStartDate: Date?
    var pauseStartHostTime: CMTime?
    var accumulatedPause: CMTime = .zero
    var totalPausedSeconds: TimeInterval = 0
    var timePassed: TimeInterval = 0
    var isPaused = false
    var isStopping = false
    var sessionStarted = false
    var writerFailed = false
    var writerFailureReason: String?
    var lastVideoPTS: CMTime?
    var frameQueue = FixedLengthArray<CMTime>(maxLength: 20)

    init(
        streamType: StreamType,
        filePath: String,
        filePath1: String = "",
        filePath2: String = "",
        audioFormatRaw: String,
        videoFormatRaw: String,
        recordWinSound: Bool,
        remuxAudio: Bool,
        recordsMic: Bool
    ) {
        self.streamType = streamType
        self.filePath = filePath
        self.filePath1 = filePath1
        self.filePath2 = filePath2
        self.audioFormatRaw = audioFormatRaw
        self.videoFormatRaw = videoFormatRaw
        self.recordWinSound = recordWinSound
        self.remuxAudio = remuxAudio
        self.recordsMic = recordsMic
    }
}

class SCContext {
    static var trimingList = [URL]()
    static var firstFrame: CMSampleBuffer?
    static var autoStop = 0
    static var recordCam = ""
    static var recordDevice = ""
    static var captureSession: AVCaptureSession?
    static var previewSession: AVCaptureSession?
    static var frameCache: CMSampleBuffer?
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    static var isSkipFrame = false
    static var lastPTS: CMTime?
    static var timeOffset = CMTime.zero
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
    static let sessionQueue = DispatchQueue(label: "com.kahlilhazel.longtake.recordingSession")
    private static let uniquePathLock = NSLock()
    static var activeSession: RecordingSession?
    static var isTerminating = false
    static var currentPreviewID = UUID()

    static var vW: AVAssetWriter?
    static var vwInput, awInput, micInput: AVAssetWriterInput?
    static var startTime: Date?
    static var pauseStartTime: Date?
    static var totalMicPausedSeconds: TimeInterval = 0
    static var timePassed: TimeInterval = 0
    static var stream: SCStream?
    static var screen: SCDisplay?
    static var window: [SCWindow]?
    static var application: [SCRunningApplication]?
    static var streamType: StreamType?
    static var availableContent: SCShareableContent?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]

    private static var isShowingPermissionAlert = false

    static var isRecordingActive: Bool {
        sessionQueue.sync {
            activeSession != nil || stream != nil || streamType != nil
        }
    }

    static var currentStream: SCStream? {
        sessionQueue.sync { activeSession?.stream ?? stream }
    }

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
            guard let displays = availableContent?.displays, !displays.isEmpty else {
                print("There needs to be at least one display connected!".local)
                return
            }
            completion()
        }
    }

    static func getSelf() -> SCRunningApplication? {
        return availableContent?.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }

    static func getSelfWindows() -> [SCWindow]? {
        return availableContent?.windows.filter {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != "Mouse Pointer".local
            && title != "Screen Magnifier".local
            && title != "Camera Overlayer".local
            && title != "iDevice Overlayer".local
        }
    }

    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).compactMap({ $0.owningApplication }) {
            if !apps.contains(app) { apps.append(app) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") {
            apps = apps.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        }
        return apps
    }

    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        guard let content = availableContent else { return [] }
        var windows = content.windows.filter {
            guard let app = $0.owningApplication,
                  let title = $0.title else {
                return false
            }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
        }
        if isOnScreen { windows = windows.filter { $0.isOnScreen == true } }
        if hideSelf && ud.bool(forKey: "hideSelf") {
            windows = windows.filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
        }
        return windows
    }

    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon?.size = NSSize(width: 69, height: 69)
        return icon
    }

    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    static func getSCDisplayWithMouse() -> SCDisplay? {
        guard let displays = availableContent?.displays,
              let currentDisplayID = getScreenWithMouse()?.displayID else {
            return nil
        }
        return displays.first(where: { $0.displayID == currentDisplayID })
    }

    static func defaultSaveDirectory() -> String {
        if let saved = ud.string(forKey: "saveDirectory"), !saved.isEmpty {
            return saved
        }
        return (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true)).first ?? NSHomeDirectory()
    }

    static func getFilePath(capture: Bool = false) -> String {
        return allocateUniqueFilePath(capture: capture, extensions: ["m4a", "mp3", "mp4", "mov", "qma", "flac", "caf", "png"])
    }

    /// 原子分配全局唯一输出基路径，避免同一秒内连续录制覆盖已完成文件
    static func allocateUniqueFilePath(in directory: String? = nil, capture: Bool = false, extensions: [String]) -> String {
        uniquePathLock.lock()
        defer { uniquePathLock.unlock() }
        let dir = directory ?? defaultSaveDirectory()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        let prefix = dir + (capture ? "/Capturing at ".local : "/Recording at ".local) + dateFormatter.string(from: Date())

        func hasCollision(_ base: String) -> Bool {
            if fd.fileExists(atPath: base) { return true }
            for ext in extensions where !ext.isEmpty {
                if fd.fileExists(atPath: "\(base).\(ext)") { return true }
            }
            return false
        }

        if !hasCollision(prefix) { return prefix }
        for idx in 1...9999 {
            let candidate = "\(prefix)-\(idx)"
            if !hasCollision(candidate) { return candidate }
        }
        return "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    /// 为目标输出路径分配不覆盖既有文件的新路径（用于自动导出，避免覆盖历史录音）
    static func nonCollidingDestinationURL(for preferredURL: URL) -> URL {
        uniquePathLock.lock()
        defer { uniquePathLock.unlock() }
        if !fd.fileExists(atPath: preferredURL.path) { return preferredURL }
        let dir = preferredURL.deletingLastPathComponent()
        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent
        for idx in 1...9999 {
            let candidate = dir.appendingPathComponent("\(stem)-\(idx)").appendingPathExtension(ext)
            if !fd.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8))").appendingPathExtension(ext)
    }

    /// 纯音频格式 -> 真实文件扩展名与 AVFileType 统一映射
    static func audioContainerSpec(for formatRaw: String) -> (fileExtension: String, fileType: AVFileType, encoderKey: String) {
        switch formatRaw {
        case AudioFormat.mp3.rawValue:
            return ("m4a", .m4a, AudioFormat.aac.rawValue)
        case AudioFormat.aac.rawValue:
            return ("m4a", .m4a, AudioFormat.aac.rawValue)
        case AudioFormat.alac.rawValue:
            return ("m4a", .m4a, AudioFormat.alac.rawValue)
        case AudioFormat.flac.rawValue:
            return ("flac", .caf, AudioFormat.flac.rawValue)
        case AudioFormat.opus.rawValue:
            // macOS AVFoundation 原生支持 CAF 容器封装 Opus，避免误用未实现的 .ogg 扩展名或被视频容器覆盖成 AAC
            return ("caf", .caf, AudioFormat.opus.rawValue)
        default:
            return ("m4a", .m4a, AudioFormat.aac.rawValue)
        }
    }

    static func updateAudioSettings(format: String = ud.string(forKey: "audioFormat") ?? AudioFormat.aac.rawValue, rate: Int = 48000, forVideo: Bool = false, videoFormatRaw: String? = nil) -> [String: Any] {
        var audioSettings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        let qualityKbps = ud.integer(forKey: "audioQuality")
        var bitRate = (qualityKbps > 0 ? qualityKbps : AudioQuality.high.rawValue) * 1000
        if rate < 44100 { bitRate = min(64000, bitRate / 2) }
        switch format {
        case AudioFormat.mp3.rawValue, AudioFormat.aac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        case AudioFormat.alac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case AudioFormat.flac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatFLAC
        case AudioFormat.opus.rawValue:
            let effectiveVideoFmt = videoFormatRaw ?? (ud.string(forKey: "videoFormat") ?? VideoFormat.mp4.rawValue)
            if forVideo && effectiveVideoFmt == VideoFormat.mp4.rawValue {
                audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            } else {
                audioSettings[AVFormatIDKey] = kAudioFormatOpus
            }
            audioSettings[AVEncoderBitRateKey] = bitRate
        default:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        }
        return audioSettings
    }

    static func getBackgroundColor() -> CGColor {
        guard let color = ud.string(forKey: "background") else { return CGColor.black }
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

    static func performMicCheck() async -> Bool {
        guard ud.bool(forKey: "recordMic") == true else { return false }
        if await AVCaptureDevice.requestAccess(for: .audio) { return true }

        ud.setValue(false, forKey: "recordMic")
        DispatchQueue.main.async {
            let alert = createAlert(
                title: "Permission Required",
                message: "LongTake needs permission to record your microphone.",
                button1: "Open Settings",
                button2: "Cancel"
            )
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
        return false
    }

    private static func requestPermissions() {
        DispatchQueue.main.async {
            guard !isShowingPermissionAlert else { return }
            isShowingPermissionAlert = true
            defer { isShowingPermissionAlert = false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = createAlert(
                title: "Permission Required",
                message: "LongTake needs screen recording permissions, even if you only intend on recording audio.",
                button1: "Open Settings",
                button2: "Cancel"
            )
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
                let alert = createAlert(
                    title: "Permission Required",
                    message: "LongTake needs this permission to record your camera or mobile device.",
                    button1: "Open Settings",
                    button2: "Cancel"
                )
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
            return try NSImage(data: Data(contentsOf: url))
        } catch {
            print("load wallpaper error: \(error)")
            return nil
        }
    }

    static func getRecordingSize() -> String {
        guard let path = filePath else { return "Unknown".local }
        do {
            let fileAttr = try fd.attributesOfItem(atPath: path)
            let byteFormat = ByteCountFormatter()
            byteFormat.allowedUnits = [.useMB]
            byteFormat.countStyle = .file
            if let size = fileAttr[FileAttributeKey.size] as? Int64 {
                return byteFormat.string(fromByteCount: size)
            }
        } catch {
            print(String(format: "failed to fetch file for size indicator: %@".local, error.localizedDescription))
        }
        return "Unknown".local
    }

    static func getRecordingLength() -> String {
        let elapsed: TimeInterval = sessionQueue.sync {
            if let session = activeSession {
                if session.isPaused {
                    return session.timePassed
                }
                if let start = session.startTime {
                    session.timePassed = max(0, Date.now.timeIntervalSince(start) - session.totalPausedSeconds)
                    return session.timePassed
                }
                return 0
            }
            if isPaused { return timePassed }
            if let start = startTime {
                timePassed = max(0, Date.now.timeIntervalSince(start))
                return timePassed
            }
            return 0
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = elapsed >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        return formatter.string(from: elapsed) ?? "00:00"
    }

    static func isCameraRunning() -> Bool {
        return AVOutputClass.shared.isAnyCameraOrDeviceActive()
    }

    // MARK: - 音频导出保护与崩溃恢复（单一临界区，杜绝 TOCTOU 竞态）

    private static let audioExportQueue = DispatchQueue(label: "quickrecorder.audioExport")
    private static var _audioExportCount = 0
    private static var _audioExportWaiters: [() -> Void] = []
    private static let pendingRemuxDefaultsKey = "longTakePendingRemuxPaths"

    static var audioExportsInProgress: Int {
        audioExportQueue.sync { _audioExportCount }
    }

    static func beginAudioExport() {
        audioExportQueue.sync { _audioExportCount += 1 }
    }

    static func endAudioExport() {
        var callbacks: [() -> Void] = []
        var reachedZero = false
        audioExportQueue.sync {
            _audioExportCount = max(0, _audioExportCount - 1)
            if _audioExportCount == 0 {
                reachedZero = true
                callbacks = _audioExportWaiters
                _audioExportWaiters = []
            }
        }
        for cb in callbacks { DispatchQueue.main.async { cb() } }
        if reachedZero {
            SparkleUpdaterDelegate.shared.tryResumePendingInstallIfIdle()
        }
    }

    /// 原子检查与登记等待者，消除最终导出结束与等待登记之间的丢失通知窗口
    static func whenAudioExportsFinished(_ callback: @escaping () -> Void) {
        var invokeImmediately = false
        audioExportQueue.sync {
            if _audioExportCount == 0 {
                invokeImmediately = true
            } else {
                _audioExportWaiters.append(callback)
            }
        }
        if invokeImmediately {
            DispatchQueue.main.async { callback() }
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
            let parentDir = fileURL.deletingLastPathComponent().path
            // 若外置磁盘或目录暂时离线，保留待恢复记录，等磁盘重新挂载后再恢复
            guard fd.fileExists(atPath: parentDir) else {
                continue
            }
            guard fd.fileExists(atPath: qmaPath),
                  let info = try? qmaPackageHandle.loadInfo(from: fileURL) else {
                clearPendingRemux(qmaPath: qmaPath)
                continue
            }
            let format = info.exportMP3 ? "mp3" : info.format
            let saveURL = fileURL.deletingPathExtension().appendingPathExtension(format)
            if fd.fileExists(atPath: saveURL.path),
               let existing = try? AVAudioFile(forReading: saveURL),
               existing.length > 0 {
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

    // MARK: - 统一单调时钟暂停 / 恢复（画面、系统音、麦克风共享同一偏移）

    static func pauseRecording() {
        var newPausedState: Bool?
        sessionQueue.sync {
            guard let session = activeSession, !session.isStopping else { return }
            let nowHost = CMClockGetTime(CMClockGetHostTimeClock())
            if !session.isPaused {
                if let start = session.startTime {
                    session.timePassed = max(0, Date.now.timeIntervalSince(start) - session.totalPausedSeconds)
                }
                session.pauseStartDate = Date.now
                session.pauseStartHostTime = nowHost
                session.isPaused = true
            } else {
                if let pHost = session.pauseStartHostTime {
                    let delta = CMTimeSubtract(nowHost, pHost)
                    if delta.isValid && CMTimeGetSeconds(delta) > 0 {
                        session.accumulatedPause = CMTimeAdd(session.accumulatedPause, delta)
                    }
                }
                if let pDate = session.pauseStartDate {
                    session.totalPausedSeconds += max(0, Date.now.timeIntervalSince(pDate))
                }
                session.pauseStartDate = nil
                session.pauseStartHostTime = nil
                session.isPaused = false
            }
            isPaused = session.isPaused
            timeOffset = session.accumulatedPause
            totalMicPausedSeconds = CMTimeGetSeconds(session.accumulatedPause)
            timePassed = session.timePassed
            newPausedState = session.isPaused
        }
        guard let paused = newPausedState else { return }
        DispatchQueue.main.async {
            PopoverState.shared.isPaused = paused
            updateStatusBar()
        }
    }

    // MARK: - 线程安全、排空生产者后再封存的停止流程

    static func stopRecording(completion: (() -> Void)? = nil) {
        var detachedSession: RecordingSession?
        sessionQueue.sync {
            guard let session = activeSession, !session.isStopping else { return }
            session.isStopping = true
            detachedSession = session
            activeSession = nil
            stream = nil
            isPaused = false
            pauseStartTime = nil
            totalMicPausedSeconds = 0
            timeOffset = .zero
        }

        guard let session = detachedSession else {
            completion?()
            return
        }

        // 整个停止 + writer.finishWriting 纳入导出计数，保证 Quit 绝不会在封存完成前退出
        beginAudioExport()

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                endAudioExport()
                if let completion = completion {
                    DispatchQueue.main.async { completion() }
                }
            }

            // 1. 先清理 UI 辅助态与睡眠锁
            if ud.bool(forKey: "preventSleep") { SleepPreventer.shared.allowSleep() }
            autoStop = 0
            recordCam = ""
            recordDevice = ""
            isMagnifierEnabled = false
            hideMousePointer = false

            DispatchQueue.main.async {
                mousePointer.orderOut(nil)
                screenMagnifier.orderOut(nil)
                AppDelegate.shared.stopGlobalMouseMonitor()
                for w in NSApp.windows where w.title == "Area Overlayer".local { w.close() }
                controlPanel.orderOut(nil)
                AVOutputClass.shared.stopAuxiliaryOverlays()
                PopoverState.shared.isPaused = false
            }

            // 2. 先停止全部采集生产者，并等待回调队列彻底排空后，再执行 markAsFinished / finishWriting / 关闭文件
            if let activeStream = session.stream {
                let stopStreamGroup = DispatchGroup()
                stopStreamGroup.enter()
                activeStream.stopCapture { _ in
                    stopStreamGroup.leave()
                }
                _ = stopStreamGroup.wait(timeout: .now() + 5.0)
            }

            switch session.micBackend {
            case .avCapture:
                AudioRecorder.shared.stop()
            case .audioEngine:
                audioEngine.inputNode.removeTap(onBus: 0)
                if audioEngine.isRunning { audioEngine.stop() }
            case .aec:
                try? AECEngine.stopAudioUnit()
            case .none:
                break
            }

            // 同步屏障：确保所有已经入队到 sessionQueue 的样本写入回调全部返回
            let capturedFirstFrame: NSImage? = sessionQueue.sync {
                let frameImage = session.firstFrame?.nsImage
                session.firstFrame = nil
                session.systemAudioFile = nil
                audioFile = nil
                audioFile2 = nil
                vW = nil
                vwInput = nil
                awInput = nil
                micInput = nil
                activeSessionRecordsMic = false
                lastPTS = nil
                firstFrame = nil
                return frameImage
            }

            // 3. 封存 AVAssetWriter（所有 append 已 100% 返回）
            if session.streamType != .systemaudio {
                if let writer = session.writer {
                    if writer.status == .writing {
                        session.vwInput?.markAsFinished()
                        if #available(macOS 13, *) { session.awInput?.markAsFinished() }
                        if session.recordsMic { session.micInput?.markAsFinished() }

                        let shouldRemuxVideoAudio = session.recordsMic && session.recordWinSound && session.remuxAudio
                        if shouldRemuxVideoAudio {
                            beginAudioExport()
                        }

                        let finishGroup = DispatchGroup()
                        finishGroup.enter()
                        writer.finishWriting {
                            if writer.status != .completed || session.writerFailed {
                                if shouldRemuxVideoAudio { endAudioExport() }
                                let err = session.writerFailureReason ?? writer.error?.localizedDescription ?? "Unknow Error"
                                print("Video writing failed with status: \(writer.status), error: \(err)")
                                showNotification(title: "Failed to save file".local, body: "\(err)", id: "quickrecorder.error.\(UUID().uuidString)")
                            } else if shouldRemuxVideoAudio {
                                mixAudioTracks(videoURL: session.filePath.url, videoFormatRaw: session.videoFormatRaw) { result in
                                    defer { endAudioExport() }
                                    switch result {
                                    case .success(let url):
                                        print("Exported video to \(url.path)")
                                        if !ud.bool(forKey: "showPreview") {
                                            showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, url.path), id: "quickrecorder.completed.\(UUID().uuidString)")
                                        }
                                        DispatchQueue.main.async {
                                            if ud.bool(forKey: "trimAfterRecord") {
                                                AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
                                            } else {
                                                showPreview(path: url.path, image: capturedFirstFrame)
                                            }
                                        }
                                    case .failure(let error):
                                        print("Failed to export video: \(error.localizedDescription)")
                                        showNotification(
                                            title: "Failed to save file".local,
                                            body: "\(error.localizedDescription)\n原始视频保留于：\(session.filePath)",
                                            id: "quickrecorder.error.\(UUID().uuidString)"
                                        )
                                    }
                                }
                            }
                            finishGroup.leave()
                        }
                        finishGroup.wait()

                        if !shouldRemuxVideoAudio && writer.status == .completed && !session.writerFailed {
                            DispatchQueue.main.async {
                                if !ud.bool(forKey: "showPreview") {
                                    showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, session.filePath), id: "quickrecorder.completed.\(UUID().uuidString)")
                                } else {
                                    showPreview(path: session.filePath, image: capturedFirstFrame)
                                }
                                trimVideo(path: session.filePath)
                            }
                        }
                    } else if writer.status == .failed {
                        let err = session.writerFailureReason ?? writer.error?.localizedDescription ?? "Unknow Error"
                        showNotification(title: "Failed to save file".local, body: err, id: "quickrecorder.error.\(UUID().uuidString)")
                    }
                }
            } else {
                // 纯系统音频（含可选双轨麦克风）
                var micWriterCompleted = true
                if session.recordsMic, let writer = session.writer {
                    if writer.status == .writing {
                        session.micInput?.markAsFinished()
                        let micGroup = DispatchGroup()
                        micGroup.enter()
                        writer.finishWriting {
                            micGroup.leave()
                        }
                        micGroup.wait()
                    }
                    micWriterCompleted = (writer.status == .completed) && !session.writerFailed
                }

                if session.audioFormatRaw == AudioFormat.mp3.rawValue && !session.recordsMic {
                    beginAudioExport()
                    Task {
                        defer { endAudioExport() }
                        let preferredOut = URL(fileURLWithPath: session.filePath).deletingPathExtension().appendingPathExtension("mp3")
                        let outPutUrl = nonCollidingDestinationURL(for: preferredOut)
                        let stagingUrl = outPutUrl.deletingLastPathComponent().appendingPathComponent(".longtake-staging-\(UUID().uuidString).mp3")
                        defer { try? fd.removeItem(at: stagingUrl) }
                        do {
                            try await m4a2mp3(inputUrl: session.filePath1.url, outputUrl: stagingUrl)
                            let verified = try AVAudioFile(forReading: stagingUrl)
                            guard verified.length > 0 else {
                                throw NSError(domain: "LongTakeExportError", code: 18, userInfo: [NSLocalizedDescriptionKey: "Encoded MP3 audio has zero readable frames."])
                            }
                            try fd.moveItem(at: stagingUrl, to: outPutUrl)
                            try? fd.removeItem(atPath: session.filePath1)
                            if !ud.bool(forKey: "showPreview") {
                                let title = "Recording Completed".local
                                let body = String(format: "File saved to: %@".local, outPutUrl.path.removingPercentEncoding ?? outPutUrl.path)
                                showNotification(title: title, body: body, id: "quickrecorder.completed.\(UUID().uuidString)")
                            } else {
                                DispatchQueue.main.async { showPreview(path: outPutUrl.path, image: NSImage(named: "audioIcon")) }
                            }
                        } catch {
                            showNotification(title: "Failed to save file".local, body: "\(error.localizedDescription)", id: "quickrecorder.error.\(UUID().uuidString)")
                        }
                    }
                } else if session.remuxAudio && session.recordsMic {
                    if !micWriterCompleted {
                        showNotification(
                            title: "Failed to save file".local,
                            body: "麦克风音轨写入异常，原始 .qma 素材已保留于：\(session.filePath)",
                            id: "quickrecorder.error.\(UUID().uuidString)"
                        )
                    } else {
                        let fileURL = session.filePath.url
                        if let info = try? qmaPackageHandle.loadInfo(from: fileURL) {
                            markPendingRemux(qmaPath: session.filePath)
                            let audioPlayerManager = AudioPlayerManager(forOfflineExportOnly: true)
                            audioPlayerManager.loadAudioFiles(format: info.format, package: fileURL, encoder: info.encoder, saveMP3: info.exportMP3)
                            audioPlayerManager.sysVol = info.sysVol
                            audioPlayerManager.micVol = info.micVol
                            let exportMP3 = info.exportMP3
                            let format = exportMP3 ? "mp3" : info.format
                            let preferredSaveURL = fileURL.deletingPathExtension().appendingPathExtension(format)
                            let saveURL = nonCollidingDestinationURL(for: preferredSaveURL)
                            audioPlayerManager.saveFile(saveURL, saveAsMP3: exportMP3, sourceQMAPath: session.filePath)
                        } else {
                            showNotification(title: "Failed to save file".local, body: "Unable to read .qma metadata.", id: "quickrecorder.error.\(UUID().uuidString)")
                        }
                    }
                } else {
                    if session.recordsMic {
                        clearPendingRemux(qmaPath: session.filePath)
                    }
                    if !ud.bool(forKey: "showPreview") {
                        let title = "Recording Completed".local
                        let body = String(format: "File saved to: %@".local, session.filePath)
                        showNotification(title: title, body: body, id: "quickrecorder.completed.\(UUID().uuidString)")
                    } else {
                        DispatchQueue.main.async {
                            showPreview(path: session.filePath, image: NSImage(named: session.recordsMic ? "qmaIcon" : "audioIcon"))
                        }
                    }
                }
            }

            // 4. 复位全局展示状态
            sessionQueue.sync {
                window = nil
                screen = nil
                application = nil
                startTime = nil
                timePassed = 0
                streamType = nil
            }
            DispatchQueue.main.async {
                AppDelegate.shared.presenterType = "OFF"
                updateStatusBar()
                SparkleUpdaterDelegate.shared.tryResumePendingInstallIfIdle()
            }
        }
    }

    static func showPreview(path: String, image: NSImage? = nil) {
        if !ud.bool(forKey: "showPreview") { return }
        DispatchQueue.main.async {
            let previewImage = image ?? NSImage(named: "audioIcon") ?? NSImage(systemSymbolName: "film", accessibilityDescription: "Preview")
            guard let finalImage = previewImage, let screen = getScreenWithMouse() ?? NSScreen.main else { return }
            let previewID = UUID()
            currentPreviewID = previewID
            let contentView = NSHostingView(rootView: PreviewView(frame: finalImage, filePath: path, previewID: previewID))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFrontRegardless()
        }
    }

    static func m4a2mp3(inputUrl: URL, outputUrl: URL) async throws {
        let progress = Progress()
        let quality = ud.integer(forKey: "audioQuality")
        let bitrate = Int32(quality > 0 ? quality : AudioQuality.high.rawValue)
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(bitrate),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }

    static func trimVideo(path: String? = nil) {
        if ud.bool(forKey: "trimAfterRecord"), let targetPath = path ?? filePath {
            let fileURL = targetPath.url
            DispatchQueue.main.async {
                AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: fileURL), title: fileURL.lastPathComponent, only: false)
            }
        }
    }

    static func getCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified)
        return discoverySession.devices
    }

    static func getMicrophone() -> [AVCaptureDevice] {
        let discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        }
        return discoverySession.devices.filter { !$0.localizedName.contains("CADefaultDeviceAggregate") }
    }

    static func getiDevice() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .muxed, position: .unspecified)
        return discoverySession.devices
    }

    /// 优先按 uniqueID 匹配麦克风，兼容旧版按 localizedName 保存的偏好并自动迁移
    static func getCurrentMic() -> AVCaptureDevice? {
        guard let saved = ud.string(forKey: "micDevice"), saved != "default" else { return nil }
        let devices = getMicrophone()
        if let byID = devices.first(where: { $0.uniqueID == saved }) {
            return byID
        }
        let matchingByName = devices.filter { $0.localizedName == saved }
        if matchingByName.count == 1, let single = matchingByName.first {
            ud.set(single.uniqueID, forKey: "micDevice")
            return single
        }
        return matchingByName.first
    }

    static func getSampleRate() -> Int? {
        if let device = getCurrentMic() {
            let description = device.activeFormat.formatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee, asbd.mSampleRate > 0 {
                return Int(asbd.mSampleRate)
            }
        }
        return getDefaultSampleRate()
    }

    static func getDefaultSampleRate() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))

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

        guard sampleRateStatus == noErr, sampleRate > 0 else {
            print("Failed to get sample rate for the default input device")
            return nil
        }

        return Int(sampleRate)
    }

    /// 严格按 Core Media 返回的实际 timing 条目数重写 PTS/DTS，并校验全部返回状态
    static func adjustTime(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetFormatDescription(sample) != nil, offset.isValid else { return nil }
        if CMTimeCompare(offset, .zero) == 0 { return sample }

        var count: CMItemCount = 0
        let queryStatus = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard queryStatus == noErr, count > 0 else { return nil }

        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
        var actualCount: CMItemCount = 0
        let fillStatus = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &actualCount)
        guard fillStatus == noErr, actualCount > 0 else { return nil }

        let validCount = min(Int(actualCount), timingInfo.count)
        for i in 0..<validCount {
            if timingInfo[i].decodeTimeStamp.isValid {
                timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, offset)
            }
            if timingInfo[i].presentationTimeStamp.isValid {
                timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, offset)
            }
        }

        var outSampleBuffer: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: validCount,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &outSampleBuffer
        )
        guard copyStatus == noErr else { return nil }
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

    /// 修复：按各源轨真实 timeRange 插入、给 compositionAudioTrack 设置 mix 参数、passthrough 不附带无效 audioMix、采用原子暂存
    static func mixAudioTracks(videoURL: URL, videoFormatRaw: String? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        showNotification(title: "Still Processing".local, body: "Mixing audio track...".local, id: "quickrecorder.processing.\(UUID().uuidString)")

        let asset = AVAsset(url: videoURL)
        let dir = videoURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let preferredFinalURL = videoURL.deletingPathExtension().deletingPathExtension()
        let finalOutputURL = nonCollidingDestinationURL(for: preferredFinalURL)

        let effectiveFormat = (videoFormatRaw ?? finalOutputURL.pathExtension).lowercased()
        let fileType: AVFileType = (effectiveFormat == VideoFormat.mov.rawValue) ? .mov : .mp4
        let stagingAudioURL = dir.appendingPathComponent(".longtake-mix-audio-\(token).\(effectiveFormat)")
        let stagingVideoURL = dir.appendingPathComponent(".longtake-mix-video-\(token).\(effectiveFormat)")

        let cleanupStaging: () -> Void = {
            try? fd.removeItem(at: stagingAudioURL)
            try? fd.removeItem(at: stagingVideoURL)
        }

        let audioOnlyComposition = AVMutableComposition()
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            cleanupStaging()
            completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
            return
        }

        var inputParameters: [AVMutableAudioMixInputParameters] = []
        for audioTrack in audioTracks {
            let tr = audioTrack.timeRange
            guard tr.duration.isValid && CMTimeGetSeconds(tr.duration) > 0 else { continue }
            guard let compAudioTrack = audioOnlyComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            do {
                let insertAt = tr.start.isValid && CMTimeCompare(tr.start, .zero) >= 0 ? tr.start : .zero
                try compAudioTrack.insertTimeRange(tr, of: audioTrack, at: insertAt)
                let params = AVMutableAudioMixInputParameters(track: compAudioTrack)
                params.trackID = compAudioTrack.trackID
                inputParameters.append(params)
            } catch {
                cleanupStaging()
                completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                return
            }
        }

        guard !inputParameters.isEmpty else {
            cleanupStaging()
            completion(.failure(NSError(domain: "AudioTrackError", code: -2, userInfo: [NSLocalizedDescriptionKey: "No valid audio time ranges found."])))
            return
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters

        guard let audioExportSession = AVAssetExportSession(asset: audioOnlyComposition, presetName: AVAssetExportPresetHighestQuality) else {
            cleanupStaging()
            completion(.failure(NSError(domain: "AudioExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio export session."])))
            return
        }
        audioExportSession.outputURL = stagingAudioURL
        audioExportSession.outputFileType = fileType
        audioExportSession.audioMix = audioMix

        audioExportSession.exportAsynchronously {
            switch audioExportSession.status {
            case .completed:
                let audioAsset = AVAsset(url: stagingAudioURL)
                let composition = AVMutableComposition()

                guard let videoTrack = asset.tracks(withMediaType: .video).first,
                      let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    cleanupStaging()
                    completion(.failure(NSError(domain: "VideoTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get video track."])))
                    return
                }

                do {
                    let vRange = videoTrack.timeRange
                    let vStart = vRange.start.isValid && CMTimeCompare(vRange.start, .zero) >= 0 ? vRange.start : .zero
                    try compVideoTrack.insertTimeRange(vRange, of: videoTrack, at: vStart)
                } catch {
                    cleanupStaging()
                    completion(.failure(NSError(domain: "VideoTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert video track: \(error.localizedDescription)"])))
                    return
                }

                let mixedAudioTracks = audioAsset.tracks(withMediaType: .audio)
                guard !mixedAudioTracks.isEmpty else {
                    cleanupStaging()
                    completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mixed audio output contains no audio tracks."])))
                    return
                }

                for mixedTrack in mixedAudioTracks {
                    let aRange = mixedTrack.timeRange
                    guard aRange.duration.isValid && CMTimeGetSeconds(aRange.duration) > 0 else { continue }
                    if let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        do {
                            let aStart = aRange.start.isValid && CMTimeCompare(aRange.start, .zero) >= 0 ? aRange.start : .zero
                            try compAudioTrack.insertTimeRange(aRange, of: mixedTrack, at: aStart)
                        } catch {
                            cleanupStaging()
                            completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert mixed audio track: \(error.localizedDescription)"])))
                            return
                        }
                    }
                }

                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    cleanupStaging()
                    completion(.failure(NSError(domain: "ExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session."])))
                    return
                }

                exportSession.outputURL = stagingVideoURL
                exportSession.outputFileType = fileType

                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        do {
                            try fd.moveItem(at: stagingVideoURL, to: finalOutputURL)
                            try? fd.removeItem(at: stagingAudioURL)
                            try? fd.removeItem(at: videoURL)
                            completion(.success(finalOutputURL))
                        } catch {
                            cleanupStaging()
                            completion(.failure(error))
                        }
                    case .failed:
                        cleanupStaging()
                        completion(.failure(exportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
                    case .cancelled:
                        cleanupStaging()
                        completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
                    default:
                        cleanupStaging()
                        completion(.failure(NSError(domain: "ExportError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unexpected export status."])))
                    }
                }
            case .failed:
                cleanupStaging()
                completion(.failure(audioExportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio mix export failed."])))
            case .cancelled:
                cleanupStaging()
                completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio mix export was cancelled."])))
            default:
                cleanupStaging()
                completion(.failure(NSError(domain: "ExportError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unexpected audio export status."])))
            }
        }
    }
}
