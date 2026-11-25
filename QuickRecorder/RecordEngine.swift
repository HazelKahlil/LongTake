//
//  RecordEngine.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/17.
//

import Foundation
import UserNotifications
import ScreenCaptureKit
import AVFoundation
import AVFAudio
import VideoToolbox
import AECAudioStream

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        return deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
    var isMainScreen: Bool {
        guard let id = self.displayID else { return false }
        return (CGDisplayIsMain(id) == 1)
    }
}

extension SCDisplay {
    var nsScreen: NSScreen? {
        return NSScreen.screens.first(where: { $0.displayID == self.displayID })
    }
}

extension AppDelegate {
    @objc func prepRecord(type: String, screens: SCDisplay?, windows: [SCWindow]?, applications: [SCRunningApplication]?, fastStart: Bool = false) {
        if SCContext.isTerminating { return }
        if SCContext.isRecordingActive {
            print("Recording already in progress, ignoring duplicate prepRecord.")
            return
        }

        let targetStreamType: StreamType
        switch type {
        case "window":      targetStreamType = .window
        case "windows":     targetStreamType = .windows
        case "display":     targetStreamType = .screen
        case "application": targetStreamType = .application
        case "area":        targetStreamType = .screenarea
        case "audio":       targetStreamType = .systemaudio
        default:            return
        }

        var isDirectory: ObjCBool = false
        let outputPath = SCContext.defaultSaveDirectory()
        if fd.fileExists(atPath: outputPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                DispatchQueue.main.async {
                    _ = createAlert(title: "Failed to Record".local, message: "The output path is a file instead of a folder!".local, button1: "OK").runModal()
                }
                return
            }
        } else {
            do {
                try fd.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                DispatchQueue.main.async {
                    _ = createAlert(title: "Failed to Record".local, message: "Unable to create output folder!".local, button1: "OK").runModal()
                }
                return
            }
        }

        guard let content = SCContext.availableContent else {
            SCContext.updateAvailableContent {
                DispatchQueue.main.async {
                    self.prepRecord(type: type, screens: screens, windows: windows, applications: applications, fastStart: fastStart)
                }
            }
            return
        }

        // 按 displayID / windowID / processID 从当前快照安全解析目标，杜绝陈旧选区越界或强制解包崩溃
        guard let requestedDisplay = screens ?? SCContext.getSCDisplayWithMouse() ?? content.displays.first,
              let resolvedScreen = content.displays.first(where: { $0.displayID == requestedDisplay.displayID }) ?? content.displays.first else {
            DispatchQueue.main.async {
                _ = createAlert(title: "Failed to Record".local, message: "There needs to be at least one display connected!".local, button1: "OK").runModal()
            }
            return
        }

        var resolvedWindows: [SCWindow]? = nil
        if let windows = windows {
            let wantedIDs = Set(windows.map { $0.windowID })
            resolvedWindows = content.windows.filter { wantedIDs.contains($0.windowID) }
        }
        if (targetStreamType == .window || targetStreamType == .windows) && (resolvedWindows?.isEmpty ?? true) {
            DispatchQueue.main.async {
                _ = createAlert(title: "Failed to Record".local, message: "No such window!".local, button1: "OK").runModal()
            }
            return
        }

        var resolvedApps: [SCRunningApplication]? = nil
        if let applications = applications {
            let wantedPIDs = Set(applications.map { $0.processID })
            resolvedApps = content.applications.filter { wantedPIDs.contains($0.processID) }
        }
        if targetStreamType == .application && (resolvedApps?.isEmpty ?? true) {
            DispatchQueue.main.async {
                _ = createAlert(title: "Failed to Record".local, message: "No such application!".local, button1: "OK").runModal()
            }
            return
        }

        let qrSelf = SCContext.getSelf()
        let qrWindows = SCContext.getSelfWindows()
        let dockApp = content.applications.first(where: { $0.bundleIdentifier == "com.apple.dock" })
        let wallpaper = content.windows.filter {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title != "LPSpringboard" && title != "Dock"
        }
        let desktop = content.windows.filter {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "" && title == "Desktop"
        }
        let dockWindow = content.windows.filter {
            guard let title = $0.title else { return true }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title == "Dock"
        }
        let desktopFiles = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.finder"
            && $0.title == "" && $0.frame == resolvedScreen.frame
        }
        let controlCenterWindow = content.applications.filter { $0.bundleIdentifier == "com.apple.controlcenter" }
        let mouseWindow = content.windows.filter { $0.title == "Mouse Pointer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        let camLayer = content.windows.filter { $0.title == "Camera Overlayer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }

        var appBlackList = [String]()
        if let savedData = ud.data(forKey: "hiddenApps"),
           let decodedApps = try? JSONDecoder().decode([AppInfo].self, from: savedData) {
            appBlackList = decodedApps.map { $0.bundleID }
        }
        let excludedBlacklistedApps = content.applications.filter { appBlackList.contains($0.bundleIdentifier) }

        var effectiveStreamType = targetStreamType
        let filter: SCContentFilter
        switch targetStreamType {
        case .window, .windows:
            guard var includ = resolvedWindows, !includ.isEmpty else { return }
            if includ.count > 1 {
                if highlightMouse { includ += mouseWindow }
                if background.rawValue == BackgroundType.wallpaper.rawValue, dockApp != nil { includ += wallpaper }
                filter = SCContentFilter(display: resolvedScreen, including: includ + camLayer)
                if #available(macOS 14.2, *) { filter.includeMenuBar = includeMenuBar }
                effectiveStreamType = .windows
            } else {
                effectiveStreamType = .window
                filter = SCContentFilter(desktopIndependentWindow: includ[0])
            }
        case .screen, .screenarea:
            if targetStreamType == .screenarea {
                if let area = SCContext.screenArea, let name = resolvedScreen.nsScreen?.localizedName {
                    let a = ["x": area.origin.x, "y": area.origin.y, "width": area.width, "height": area.height]
                    var allAreas = (ud.object(forKey: "savedArea") as? [String: [String: CGFloat]]) ?? [:]
                    allAreas[name] = a
                    ud.set(allAreas, forKey: "savedArea")
                }
            }
            var excluded = [SCRunningApplication]()
            var except = [SCWindow]()
            excluded += excludedBlacklistedApps
            if hideCCenter { excluded += controlCenterWindow }
            if hideSelf, let qrWindows = qrWindows { except += qrWindows }
            if background.rawValue != BackgroundType.wallpaper.rawValue, dockApp != nil {
                except += wallpaper
                except += desktop
            }
            if hideDesktopFiles { except += desktopFiles }
            filter = SCContentFilter(display: resolvedScreen, excludingApplications: excluded, exceptingWindows: except)
            if #available(macOS 14.2, *) { filter.includeMenuBar = includeMenuBar }
        case .application:
            guard var includ = resolvedApps, !includ.isEmpty else { return }
            var except = [SCWindow]()
            if let qrSelf = qrSelf { includ.append(qrSelf) }
            let withFinder = includ.contains(where: { $0.bundleIdentifier == "com.apple.finder" })
            if withFinder && hideDesktopFiles { except += desktopFiles }
            if hideSelf, let qrWindows = qrWindows { except += qrWindows }
            if background.rawValue == BackgroundType.wallpaper.rawValue, let dock = dockApp {
                includ.append(dock)
                except += dockWindow
            }
            filter = SCContentFilter(display: resolvedScreen, including: includ, exceptingWindows: except)
            if #available(macOS 14.2, *) { filter.includeMenuBar = includeMenuBar }
        case .systemaudio:
            filter = SCContentFilter(display: resolvedScreen, excludingApplications: [], exceptingWindows: [])
        default:
            return
        }

        SCContext.screen = resolvedScreen
        SCContext.window = resolvedWindows
        SCContext.application = resolvedApps
        SCContext.filter = filter

        Task {
            await record(
                streamType: effectiveStreamType,
                screen: resolvedScreen,
                windows: resolvedWindows,
                filter: filter,
                fastStart: fastStart
            )
        }
    }

    func record(streamType: StreamType, screen: SCDisplay, windows: [SCWindow]?, filter: SCContentFilter, fastStart: Bool = true) async {
        if SCContext.isTerminating { return }

        let audioOnly = (streamType == .systemaudio)
        let frozenAudioFormat = audioFormat.rawValue
        let frozenVideoFormat = videoFormat.rawValue
        let frozenRecordWinSound = recordWinSound
        let frozenRemuxAudio = remuxAudio
        var wantMic = recordMic

        // 启动前等待实际麦克风授权，避免未授权时进入 audioEngine.start() 崩溃或静默缺轨
        if wantMic {
            let granted = await SCContext.performMicCheck()
            if !granted {
                wantMic = false
            } else if micDevice != "default" && SCContext.getCurrentMic() == nil {
                // 指定麦克风已被拔出时明确提示并回退到系统默认或关闭
                wantMic = false
                DispatchQueue.main.async {
                    SCContext.showNotification(
                        title: "Failed to Record".local,
                        body: "所选麦克风设备已断开，本轮仅录制系统声音。",
                        id: "quickrecorder.mic.missing.\(UUID().uuidString)"
                    )
                }
            }
        }

        let conf: SCStreamConfiguration
#if compiler(>=6.0)
        if recordHDR && !audioOnly {
            if #available(macOS 15, *) {
                conf = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
            } else {
                conf = SCStreamConfiguration()
            }
        } else {
            conf = SCStreamConfiguration()
        }
#else
        conf = SCStreamConfiguration()
#endif
        conf.width = 2
        conf.height = 2

        if !audioOnly {
            if #available(macOS 14.0, *) {
                conf.width = max(2, Int(filter.contentRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1))
                conf.height = max(2, Int(filter.contentRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1))
            } else {
                guard let scale = screen.nsScreen?.backingScaleFactor else { return }
                let rect: CGRect
                if streamType == .window, let win = windows?.first {
                    rect = win.frame
                } else if streamType == .screenarea, let area = SCContext.screenArea {
                    rect = area
                } else {
                    rect = screen.frame
                }
                conf.width = max(2, Int(rect.width) * (highRes == 2 ? Int(scale) : 1))
                conf.height = max(2, Int(rect.height) * (highRes == 2 ? Int(scale) : 1))
            }

            // 修复 P1-4：快捷录屏与选择器遵循同一份光标和系统声音偏好，fastStart 不再绕过用户设置
            conf.showsCursor = showMouse

            if background.rawValue != BackgroundType.wallpaper.rawValue {
                conf.backgroundColor = SCContext.getBackgroundColor()
            }
            if !recordHDR {
                conf.pixelFormat = kCVPixelFormatType_32BGRA
                conf.colorSpaceName = CGColorSpace.sRGB
            } else {
                conf.colorSpaceName = CGColorSpace.itur_2100_PQ
                conf.queueDepth = 8
            }
        }

        if #available(macOS 13, *) {
            conf.capturesAudio = frozenRecordWinSound || audioOnly
            conf.sampleRate = 48000
            conf.channelCount = 2
        }

        conf.minimumFrameInterval = CMTime(value: 1, timescale: audioOnly ? CMTimeScale.max : (frameRate >= 60 ? 0 : CMTimeScale(frameRate)))

        if streamType == .screenarea, let nsRect = SCContext.screenArea {
            let newY = screen.frame.height - nsRect.size.height - nsRect.origin.y
            conf.sourceRect = CGRect(x: nsRect.origin.x, y: newY, width: nsRect.size.width, height: nsRect.size.height)
            if #available(macOS 14.0, *) {
                conf.width = max(2, Int(conf.sourceRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1))
                conf.height = max(2, Int(conf.sourceRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1))
            } else if let scale = screen.nsScreen?.backingScaleFactor {
                conf.width = max(2, Int(conf.sourceRect.width) * (highRes == 2 ? Int(scale) : 1))
                conf.height = max(2, Int(conf.sourceRect.height) * (highRes == 2 ? Int(scale) : 1))
            }
        }

        let encoderIsH265 = (encoder.rawValue == Encoder.h265.rawValue) || recordHDR
        if !audioOnly && !encoderIsH265 {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(conf.width),
                height: Int32(conf.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            if status != noErr {
                let button = showAlertSyncOnMainThread(
                    level: .critical,
                    title: "Encoder Warning",
                    message: "VideoToolbox H.264 hardware encoder doesn't support the current resolution.\nContinue with a software encoder will significantly increase the CPU usage.\n\nWould you like to use H.265 instead?".local,
                    button1: "Use H.265",
                    button2: "Continue with H.264"
                )
                if button == .alertFirstButtonReturn { ud.setValue(Encoder.h265.rawValue, forKey: "encoder") }
            }
        }

        // 创建并初始化独立录制会话（全部资源 do/catch，任何失败立即回滚并提示）
        let session: RecordingSession
        do {
            if audioOnly {
                session = try buildAudioSession(
                    audioFormatRaw: frozenAudioFormat,
                    videoFormatRaw: frozenVideoFormat,
                    remuxAudio: frozenRemuxAudio,
                    recordsMic: wantMic
                )
            } else {
                session = try buildVideoSession(
                    streamType: streamType,
                    conf: conf,
                    audioFormatRaw: frozenAudioFormat,
                    videoFormatRaw: frozenVideoFormat,
                    recordWinSound: frozenRecordWinSound,
                    remuxAudio: frozenRemuxAudio,
                    recordsMic: wantMic
                )
            }
        } catch {
            print("Failed to initialize recording session: \(error)")
            DispatchQueue.main.async {
                SCContext.showNotification(title: "Failed to Record".local, body: error.localizedDescription, id: "quickrecorder.initfail.\(UUID().uuidString)")
                updateStatusBar()
            }
            return
        }

        let newStream = SCStream(filter: filter, configuration: conf, delegate: self)
        session.stream = newStream

        // 原子登记会话，同时将 SCStream 回调绑定到串行 sessionQueue
        let registered: Bool = SCContext.sessionQueue.sync {
            if SCContext.activeSession != nil || SCContext.isTerminating {
                return false
            }
            SCContext.activeSession = session
            SCContext.stream = newStream
            SCContext.streamType = streamType
            SCContext.filePath = session.filePath
            SCContext.filePath1 = session.filePath1
            SCContext.filePath2 = session.filePath2
            SCContext.vW = session.writer
            SCContext.vwInput = session.vwInput
            SCContext.awInput = session.awInput
            SCContext.micInput = session.micInput
            SCContext.audioFile = session.systemAudioFile
            SCContext.activeSessionRecordsMic = session.recordsMic
            SCContext.isPaused = false
            SCContext.isResume = false
            SCContext.timeOffset = .zero
            SCContext.totalMicPausedSeconds = 0
            SCContext.timePassed = 0
            SCContext.startTime = nil
            return true
        }
        guard registered else {
            rollbackFailedSession(session)
            return
        }

        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: SCContext.sessionQueue)
            if #available(macOS 13, *) {
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: SCContext.sessionQueue)
            }
            if session.recordsMic {
                try startMicRecording(for: session)
            }
            try await newStream.startCapture()
        } catch {
            print("capture failed: \(error.localizedDescription)")
            rollbackFailedSession(session)
            DispatchQueue.main.async {
                SCContext.showNotification(title: "Failed to Record".local, body: error.localizedDescription, id: "quickrecorder.capturefail.\(UUID().uuidString)")
                updateStatusBar()
            }
            return
        }

        DispatchQueue.main.async {
            PopoverState.shared.isPaused = false
            if !audioOnly { AppDelegate.shared.registerGlobalMouseMonitor() }
            updateStatusBar()
        }
        if preventSleep { SleepPreventer.shared.preventSleep(reason: "Screen recording in progress") }
    }

    private func rollbackFailedSession(_ session: RecordingSession) {
        // 原子争抢会话所有权：若 stopRecording() 已接管该会话，则绝不重复取消 writer 或删除输出文件
        let claimedOwnership: Bool = SCContext.sessionQueue.sync {
            if session.isStopping { return false }
            session.isStopping = true
            session.systemAudioFile = nil
            if SCContext.activeSession?.id == session.id {
                SCContext.activeSession = nil
                SCContext.stream = nil
                SCContext.streamType = nil
                SCContext.vW = nil
                SCContext.vwInput = nil
                SCContext.awInput = nil
                SCContext.micInput = nil
                SCContext.audioFile = nil
                SCContext.activeSessionRecordsMic = false
            }
            return true
        }
        guard claimedOwnership else { return }

        switch session.micBackend {
        case .avCapture:
            AudioRecorder.shared.stop()
        case .audioEngine:
            SCContext.audioEngine.inputNode.removeTap(onBus: 0)
            if SCContext.audioEngine.isRunning { SCContext.audioEngine.stop() }
        case .aec:
            try? SCContext.AECEngine.stopAudioUnit()
        case .none:
            break
        }
        session.writer?.cancelWriting()
        if session.streamType == .systemaudio && session.recordsMic {
            SCContext.clearPendingRemux(qmaPath: session.filePath)
        }
        try? fd.removeItem(atPath: session.filePath)
    }

    private func buildAudioSession(audioFormatRaw: String, videoFormatRaw: String, remuxAudio: Bool, recordsMic: Bool) throws -> RecordingSession {
        let spec = SCContext.audioContainerSpec(for: audioFormatRaw)
        let basePath = SCContext.allocateUniqueFilePath(extensions: [spec.fileExtension, "qma", "mp3"])
        let sysSettings = SCContext.updateAudioSettings(format: spec.encoderKey, rate: 48000, forVideo: false)

        if recordsMic {
            let qmaPath = "\(basePath).qma"
            let sysPath = "\(qmaPath)/sys.\(spec.fileExtension)"
            let micPath = "\(qmaPath)/mic.\(spec.fileExtension)"
            try fd.createDirectory(at: qmaPath.url, withIntermediateDirectories: true, attributes: nil)

            let info = qmaPackageHandle.Info(
                format: spec.fileExtension,
                encoder: spec.encoderKey,
                exportMP3: audioFormatRaw == AudioFormat.mp3.rawValue,
                sysVol: 1.0,
                micVol: 1.0
            )
            let infoData = try JSONEncoder().encode(info)
            try infoData.write(to: "\(qmaPath)/info.json".url, options: .atomic)

            let sysFile = try AVAudioFile(forWriting: sysPath.url, settings: sysSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let sampleRate = SCContext.getSampleRate() ?? 48000
            let micSettings = SCContext.updateAudioSettings(format: spec.encoderKey, rate: sampleRate, forVideo: false)
            let writer = try AVAssetWriter(outputURL: micPath.url, fileType: spec.fileType)
            writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(micInput) else {
                throw NSError(domain: "LongTakeRecordError", code: 101, userInfo: [NSLocalizedDescriptionKey: "Cannot add microphone audio input to writer."])
            }
            writer.add(micInput)
            guard writer.startWriting() else {
                throw writer.error ?? NSError(domain: "LongTakeRecordError", code: 102, userInfo: [NSLocalizedDescriptionKey: "Microphone writer failed to start."])
            }

            let session = RecordingSession(
                streamType: .systemaudio,
                filePath: qmaPath,
                filePath1: sysPath,
                filePath2: micPath,
                audioFormatRaw: audioFormatRaw,
                videoFormatRaw: videoFormatRaw,
                recordWinSound: true,
                remuxAudio: remuxAudio,
                recordsMic: true
            )
            session.systemAudioFile = sysFile
            session.writer = writer
            session.micInput = micInput

            // Write-ahead 登记待恢复清单，即使录制中异常崩溃也可在下次启动接续恢复
            if remuxAudio {
                SCContext.markPendingRemux(qmaPath: qmaPath)
            }
            return session
        } else {
            let outPath = "\(basePath).\(spec.fileExtension)"
            let sysFile = try AVAudioFile(forWriting: outPath.url, settings: sysSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let session = RecordingSession(
                streamType: .systemaudio,
                filePath: outPath,
                filePath1: outPath,
                filePath2: "",
                audioFormatRaw: audioFormatRaw,
                videoFormatRaw: videoFormatRaw,
                recordWinSound: true,
                remuxAudio: remuxAudio,
                recordsMic: false
            )
            session.systemAudioFile = sysFile
            return session
        }
    }

    private func buildVideoSession(
        streamType: StreamType,
        conf: SCStreamConfiguration,
        audioFormatRaw: String,
        videoFormatRaw: String,
        recordWinSound: Bool,
        remuxAudio: Bool,
        recordsMic: Bool
    ) throws -> RecordingSession {
        let fileEnding = videoFormatRaw == VideoFormat.mov.rawValue ? VideoFormat.mov.rawValue : VideoFormat.mp4.rawValue
        let fileType: AVFileType = (fileEnding == VideoFormat.mov.rawValue) ? .mov : .mp4
        let basePath = SCContext.allocateUniqueFilePath(extensions: [fileEnding, "\(fileEnding).\(fileEnding).\(fileEnding)"])
        let filePath: String
        if remuxAudio && recordsMic && recordWinSound {
            filePath = "\(basePath).\(fileEnding).\(fileEnding).\(fileEnding)"
        } else {
            filePath = "\(basePath).\(fileEnding)"
        }

        let writer = try AVAssetWriter(outputURL: filePath.url, fileType: fileType)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let encoderIsH265 = (encoder.rawValue == Encoder.h265.rawValue) || recordHDR
        let fpsMultiplier = Double(max(1, frameRate)) / 8.0
        let encoderMultiplier = encoderIsH265 ? 0.5 : 0.9
        let resolution = Double(max(600, conf.width)) * Double(max(600, conf.height))
        var qualityMultiplier = 1.0 - (log10(sqrt(resolution) * fpsMultiplier) / 5.0)
        switch videoQuality {
        case 0.3: qualityMultiplier = max(0.1, qualityMultiplier)
        case 0.7: qualityMultiplier = max(0.4, min(0.6, qualityMultiplier * 3.0))
        default:  qualityMultiplier = 1.0
        }
        let h264Level = AVVideoProfileLevelH264HighAutoLevel
        let h265Level = recordHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        let targetBitrate = resolution * fpsMultiplier * encoderMultiplier * qualityMultiplier * (recordHDR ? 2.0 : 1.0)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: encoderIsH265 ? ((withAlpha && !recordHDR) ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc) : AVVideoCodecType.h264,
            AVVideoWidthKey: conf.width,
            AVVideoHeightKey: conf.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: encoderIsH265 ? h265Level : h264Level,
                AVVideoAverageBitRateKey: max(200000, Int(targetBitrate)),
                AVVideoExpectedSourceFrameRateKey: frameRate
            ] as [String: Any]
        ]

        if !recordHDR {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ] as [String: Any]
        }

        let vwInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vwInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vwInput) else {
            throw NSError(domain: "LongTakeRecordError", code: 201, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input to writer."])
        }
        writer.add(vwInput)

        var awInput: AVAssetWriterInput?
        if #available(macOS 13, *), recordWinSound {
            let sysAudioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: SCContext.updateAudioSettings(format: audioFormatRaw, rate: 48000, forVideo: true, videoFormatRaw: fileEnding)
            )
            sysAudioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(sysAudioInput) {
                writer.add(sysAudioInput)
                awInput = sysAudioInput
            }
        }

        var micInput: AVAssetWriterInput?
        if recordsMic {
            let sampleRate = SCContext.getSampleRate() ?? 48000
            let micSettings = SCContext.updateAudioSettings(format: audioFormatRaw, rate: sampleRate, forVideo: true, videoFormatRaw: fileEnding)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw NSError(domain: "LongTakeRecordError", code: 202, userInfo: [NSLocalizedDescriptionKey: "Cannot add microphone input to video writer."])
            }
            writer.add(input)
            micInput = input
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "LongTakeRecordError", code: 203, userInfo: [NSLocalizedDescriptionKey: "Video writer failed to start."])
        }

        let session = RecordingSession(
            streamType: streamType,
            filePath: filePath,
            audioFormatRaw: audioFormatRaw,
            videoFormatRaw: fileEnding,
            recordWinSound: recordWinSound,
            remuxAudio: remuxAudio,
            recordsMic: recordsMic
        )
        session.writer = writer
        session.vwInput = vwInput
        session.awInput = awInput
        session.micInput = micInput
        return session
    }

    func startMicRecording(for session: RecordingSession) throws {
        let sessionID = session.id
        if micDevice == "default" {
            if enableAEC {
                var level = AUVoiceIOOtherAudioDuckingLevel.mid
                switch AECLevel {
                case "min": level = .min
                case "max": level = .max
                default:    level = .mid
                }
                session.micBackend = .aec
                try SCContext.AECEngine.startAudioStream(enableAEC: true, duckingLevel: level, audioBufferHandler: { pcmBuffer in
                    let captureHostPTS = CMClockGetTime(CMClockGetHostTimeClock())
                    // 离开 Audio Unit 渲染回调前深拷贝 PCM 缓冲，防止下一次渲染复用底层内存导致人声损坏
                    guard let ownedCopy = pcmBuffer.deepCopy() else { return }
                    SCContext.sessionQueue.async {
                        guard let active = SCContext.activeSession,
                              active.id == sessionID,
                              !active.isStopping,
                              !active.isPaused,
                              active.sessionStarted,
                              let micInput = active.micInput,
                              micInput.isReadyForMoreMediaData else { return }
                        let adjustedPTS = CMTimeSubtract(captureHostPTS, active.accumulatedPause)
                        guard let sb = ownedCopy.asSampleBuffer(at: adjustedPTS) else { return }
                        if !micInput.append(sb) {
                            active.writerFailed = true
                            active.writerFailureReason = active.writer?.error?.localizedDescription ?? "Failed to append AEC mic sample."
                        }
                    }
                })
            } else {
                let input = SCContext.audioEngine.inputNode
                input.removeTap(onBus: 0)
                let inputFormat = input.inputFormat(forBus: 0)
                guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
                    throw NSError(domain: "LongTakeRecordError", code: 301, userInfo: [NSLocalizedDescriptionKey: "Default microphone input format is unavailable."])
                }
                session.micBackend = .audioEngine
                input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, audioTime in
                    // 优先使用实际采集时间戳 audioTime.hostTime，消除回调调度延迟引入的音画漂移
                    let preciseHostPTS: CMTime = audioTime.isHostTimeValid
                        ? CMClockMakeHostTimeFromSystemUnits(audioTime.hostTime)
                        : CMClockGetTime(CMClockGetHostTimeClock())
                    guard let ownedCopy = buffer.deepCopy() else { return }
                    SCContext.sessionQueue.async {
                        guard let active = SCContext.activeSession,
                              active.id == sessionID,
                              !active.isStopping,
                              !active.isPaused,
                              active.sessionStarted,
                              let micInput = active.micInput,
                              micInput.isReadyForMoreMediaData else { return }
                        let adjustedPTS = CMTimeSubtract(preciseHostPTS, active.accumulatedPause)
                        guard let sb = ownedCopy.asSampleBuffer(at: adjustedPTS) else { return }
                        if !micInput.append(sb) {
                            active.writerFailed = true
                            active.writerFailureReason = active.writer?.error?.localizedDescription ?? "Failed to append mic sample."
                        }
                    }
                }
                try SCContext.audioEngine.start()
            }
        } else {
            session.micBackend = .avCapture
            try AudioRecorder.shared.setupAudioCapture(sessionID: sessionID)
            AudioRecorder.shared.start()
        }
    }

    func outputVideoEffectDidStart(for stream: SCStream) {
        DispatchQueue.main.async { camWindow.close() }
        print("[Presenter Overlay ON]")
        isPresenterON = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
            self.isCameraReady = true
        }
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        print("[Presenter Overlay OFF]")
        presenterType = "OFF"
        isPresenterON = false
        isCameraReady = false
        DispatchQueue.main.async {
            if SCContext.currentStream != nil { camWindow.orderFront(self) }
        }
    }

    // 回调已运行在串行 SCContext.sessionQueue 上，彻底避免与 stopRecording / finishWriting 并发交错
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard let session = SCContext.activeSession,
              !session.isStopping,
              session.stream === stream else { return }

        if SCContext.saveFrame, let imageBuffer = sampleBuffer.imageBuffer {
            SCContext.saveFrame = false
            saveSnapshotFrame(sampleBuffer: sampleBuffer, imageBuffer: imageBuffer)
        }

        if session.isPaused { return }
        guard sampleBuffer.isValid else { return }

        let pauseOffset = session.accumulatedPause
        let shiftedSample: CMSampleBuffer
        if CMTimeCompare(pauseOffset, .zero) > 0 {
            guard let adjusted = SCContext.adjustTime(sample: sampleBuffer, by: pauseOffset) else {
                // 时间轴重映射失败时宁可丢弃该帧，绝不提交未扣减偏移的错位时间戳
                return
            }
            shiftedSample = adjusted
        } else {
            shiftedSample = sampleBuffer
        }

        switch outputType {
        case .screen:
            if session.streamType == .systemaudio { break }
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(shiftedSample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first,
                  let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(shiftedSample)
            guard pts.isValid else { return }

            if !session.sessionStarted, let writer = session.writer, writer.status == .writing {
                session.startTime = Date.now
                SCContext.startTime = session.startTime
                writer.startSession(atSourceTime: pts)
                session.sessionStarted = true
            }
            guard session.sessionStarted else { return }

            var endPTS = pts
            let dur = CMSampleBufferGetDuration(shiftedSample)
            if dur.isValid && CMTimeGetSeconds(dur) > 0 {
                endPTS = CMTimeAdd(pts, dur)
            }
            if session.frameQueue.getArray().contains(where: { CMTimeCompare($0, endPTS) >= 0 }) {
                return
            }
            session.frameQueue.append(endPTS)
            session.lastVideoPTS = endPTS
            SCContext.lastPTS = endPTS

            if let vwInput = session.vwInput, vwInput.isReadyForMoreMediaData {
                if #available(macOS 14.2, *), let rect = attachments[.presenterOverlayContentRect] as? [String: Any], let rectX = rect["X"] as? CGFloat {
                    let type: String = (rectX == .infinity) ? "OFF" : (rectX == 0.0 ? "Small" : "Big")
                    if type != presenterType {
                        isCameraReady = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
                            self.isCameraReady = true
                        }
                        presenterType = type
                    }
                }
                if isPresenterON && !isCameraReady { break }
                if session.firstFrame == nil {
                    session.firstFrame = shiftedSample
                    SCContext.firstFrame = shiftedSample
                }
                if !vwInput.append(shiftedSample) {
                    session.writerFailed = true
                    session.writerFailureReason = session.writer?.error?.localizedDescription ?? "Video append failed."
                }
            }

        case .audio:
            if session.streamType == .systemaudio {
                hideMousePointer = true
                let rawPTS = CMSampleBufferGetPresentationTimeStamp(shiftedSample)
                if !session.sessionStarted {
                    if let writer = session.writer, writer.status == .writing, rawPTS.isValid {
                        writer.startSession(atSourceTime: rawPTS)
                    }
                    session.startTime = Date.now
                    SCContext.startTime = session.startTime
                    session.sessionStarted = true
                }
                guard let file = session.systemAudioFile else { return }
                // 在 withAudioBufferList 作用域内同步写入或拷贝后写入，消除借用缓冲区失效风险（P0-5）
                shiftedSample.writePCM(to: file)
            } else {
                guard session.sessionStarted, let awInput = session.awInput, awInput.isReadyForMoreMediaData else { return }
                if !awInput.append(shiftedSample) {
                    session.writerFailed = true
                    session.writerFailureReason = session.writer?.error?.localizedDescription ?? "System audio append failed."
                }
            }
#if compiler(>=6.0)
        case .microphone:
            break
#endif
        @unknown default:
            break
        }
    }

    private func saveSnapshotFrame(sampleBuffer: CMSampleBuffer, imageBuffer: CVImageBuffer) {
        let url = "\(SCContext.allocateUniqueFilePath(capture: true, extensions: ["png"])).png".url
        if !recordHDR {
            sampleBuffer.nsImage?.saveToFile(url)
        } else {
            var ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let context = CIContext()
            let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
            ciImage = ciImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.0])
            do {
                if #available(macOS 14.0, *) {
                    try context.writePNGRepresentation(of: ciImage, to: url, format: .RGB10, colorSpace: colorSpace)
                } else {
                    try context.writePNGRepresentation(of: ciImage, to: url, format: .RGBA8, colorSpace: colorSpace)
                }
            } catch {
                print("Error saving HDR snapshot: \(error)")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("closing stream with error:\n".local, error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui".local)
        // 严格校验出错流是否为当前活跃会话，防止旧流延迟报错误杀新录制（P0-1）
        let isCurrent = SCContext.sessionQueue.sync { SCContext.activeSession?.stream === stream }
        guard isCurrent else { return }
        DispatchQueue.main.async {
            SCContext.stopRecording()
        }
    }
}

class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = AudioRecorder()
    private var captureSession: AVCaptureSession?
    private var audioInput: AVCaptureDeviceInput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var boundSessionID: UUID?
    private let audioQueue = DispatchQueue(label: "com.kahlilhazel.longtake.explicitMicQueue")

    func setupAudioCapture(sessionID: UUID) throws {
        stop()
        let session = AVCaptureSession()
        guard let audioDevice = SCContext.getCurrentMic() else {
            throw NSError(domain: "LongTakeRecordError", code: 302, userInfo: [NSLocalizedDescriptionKey: "Selected microphone device not found."])
        }

        let input = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(input) else {
            throw NSError(domain: "LongTakeRecordError", code: 303, userInfo: [NSLocalizedDescriptionKey: "Unable to add microphone input to capture session."])
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "LongTakeRecordError", code: 304, userInfo: [NSLocalizedDescriptionKey: "Unable to add audio output to capture session."])
        }
        session.addOutput(output)

        captureSession = session
        audioInput = input
        audioDataOutput = output
        boundSessionID = sessionID
    }

    func start() {
        captureSession?.startRunning()
    }

    func stop() {
        boundSessionID = nil
        if let session = captureSession {
            if session.isRunning { session.stopRunning() }
        }
        captureSession = nil
        audioInput = nil
        audioDataOutput = nil
        // 排空 explicitMicQueue 上仍在飞行的回调
        audioQueue.sync {}
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let expectedID = boundSessionID, sampleBuffer.isValid else { return }
        SCContext.sessionQueue.async {
            guard let active = SCContext.activeSession,
                  active.id == expectedID,
                  !active.isStopping,
                  !active.isPaused,
                  active.sessionStarted,
                  let micInput = active.micInput,
                  micInput.isReadyForMoreMediaData else { return }

            let bufferToWrite: CMSampleBuffer
            if CMTimeCompare(active.accumulatedPause, .zero) > 0 {
                guard let shifted = SCContext.adjustTime(sample: sampleBuffer, by: active.accumulatedPause) else {
                    return
                }
                bufferToWrite = shifted
            } else {
                bufferToWrite = sampleBuffer
            }

            if !micInput.append(bufferToWrite) {
                active.writerFailed = true
                active.writerFailureReason = active.writer?.error?.localizedDescription ?? "Failed to append explicit mic sample."
            }
        }
    }
}

extension CMSampleBuffer {
    /// 在 withAudioBufferList 借用作用域内完成安全 PCM 拷贝并直接落盘（杜绝 P0-5 悬空内存读取）
    func writePCM(to file: AVAudioFile) {
        do {
            try self.withAudioBufferList { audioBufferList, _ in
                guard var asbd = self.formatDescription?.audioStreamBasicDescription,
                      let format = AVAudioFormat(streamDescription: &asbd) else { return }
                let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
                guard frameCount > 0,
                      let ownedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
                ownedBuffer.frameLength = frameCount
                let srcList = audioBufferList
                let dstList = UnsafeMutableAudioBufferListPointer(ownedBuffer.mutableAudioBufferList)
                let count = min(srcList.count, dstList.count)
                for i in 0..<count {
                    guard let srcData = srcList[i].mData, let dstData = dstList[i].mData else { continue }
                    let bytes = min(Int(srcList[i].mDataByteSize), Int(dstList[i].mDataByteSize))
                    if bytes > 0 {
                        memcpy(dstData, srcData, bytes)
                        dstList[i].mDataByteSize = UInt32(bytes)
                    }
                }
                try file.write(from: ownedBuffer)
            }
        } catch {
            print("System audio write error: \(error.localizedDescription)")
        }
    }

    var nsImage: NSImage? {
        return autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let ciContext = CIContext()
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                return NSImage(cgImage: cgImage, size: .zero)
            }
            return nil
        }
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.frameLength) else { return nil }
        copy.frameLength = self.frameLength
        let srcList = UnsafeMutableAudioBufferListPointer(self.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let count = min(srcList.count, dstList.count)
        for i in 0..<count {
            guard let srcData = srcList[i].mData, let dstData = dstList[i].mData else { continue }
            let bytes = min(Int(srcList[i].mDataByteSize), Int(dstList[i].mDataByteSize))
            if bytes > 0 {
                memcpy(dstData, srcData, bytes)
                dstList[i].mDataByteSize = UInt32(bytes)
            }
        }
        return copy
    }

    func asSampleBuffer(at presentationTime: CMTime) -> CMSampleBuffer? {
        let asbd = self.format.streamDescription
        var sampleBuffer: CMSampleBuffer? = nil
        var format: CMFormatDescription? = nil

        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(max(1, asbd.pointee.mSampleRate))),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sb = sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: self.mutableAudioBufferList
        ) == noErr else { return nil }

        return sb
    }
}
