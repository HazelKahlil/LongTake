//
//  qmaPlayer.swift
//  QuickRecorder
//
//  Created by apple on 2024/6/28.
//

import Foundation
import AVFoundation
import SwiftUI

struct qmaPlayerView: View {
    @Binding var document: qmaPackageHandle
    @State var fileURL: URL
    @State private var overPlay: Bool = false
    @State private var overStop: Bool = false
    @State private var overSave: Bool = false
    @State private var overExport: Bool = false
    @StateObject private var audioPlayerManager = AudioPlayerManager()
    
    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectView().ignoresSafeArea()
            VStack(spacing: 3) {
                Button {} label: {
                    PlayerSlider(percentage: $audioPlayerManager.progress, audioLength: $audioPlayerManager.audioLength){ editing in
                        if !editing {
                            let newTime = audioPlayerManager.progress * audioPlayerManager.getPlayerDuration()
                            audioPlayerManager.seek(to: newTime)
                            audioPlayerManager.shouldPlay = false
                        } else {
                            if audioPlayerManager.isPlaying {
                                audioPlayerManager.pause()
                                audioPlayerManager.shouldPlay = true
                            }
                        }
                    }.frame(height: 30)
                }
                .buttonStyle(.plain)
                .disabled(audioPlayerManager.exporting)
                
                HStack(spacing: 4) {
                    Rectangle().opacity(0.00001).frame(width: 30)
                    Spacer()
                    Button {
                        audioPlayerManager.stop()
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overStop ? 0.1 : 0.00001))
                            Image(systemName: "stop.fill")
                                .font(.system(size: 20))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop Play")
                    .frame(width: 30, height: 30)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overStop = hovering }
                    
                    Button {
                        if audioPlayerManager.isPlaying {
                            audioPlayerManager.pause()
                        } else {
                            audioPlayerManager.play()
                        }
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overPlay ? 0.1 : 0.00001))
                            Image(systemName: audioPlayerManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Play / Pause")
                    .frame(width: 35, height: 35)
                    .padding(.leading, 2)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overPlay = hovering }
                    
                    Button {
                        saveQMA()
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overSave ? 0.1 : 0.00001))
                            Image("save")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16.5)
                                .foregroundColor(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Save Changes")
                    .frame(width: 30, height: 30)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overSave = hovering }
                    
                    Spacer()
                    
                    Button {
                        saveQMA()
                        audioPlayerManager.export()
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overExport ? 0.1 : 0.00001))
                            if audioPlayerManager.exporting {
                                ActivityIndicator()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18))
                                    .foregroundColor(.secondary)
                                    .offset(y: -2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Export")
                    .frame(width: 30, height: 30)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overExport = hovering }
                }
                
                Button {} label: {
                    HStack(spacing: 14) {
                        HStack(spacing: 2) {
                            Image(systemName: "speaker.wave.2.fill")
                            Text("\(Int(audioPlayerManager.sysVol * 100))%").foregroundColor(.secondary).frame(width: 40)
                            VolumeSlider(percentage: $audioPlayerManager.sysVol, maxValue: 4){ editing in }
                                .frame(height: 16)
                                .disabled(audioPlayerManager.exporting)
                        }
                        HStack(spacing: 2) {
                            Image(systemName: "mic.fill")
                            Text("\(Int(audioPlayerManager.micVol * 100))%").foregroundColor(.secondary).frame(width: 40)
                            VolumeSlider(percentage: $audioPlayerManager.micVol, maxValue: 4){ editing in }
                                .frame(height: 16)
                                .disabled(audioPlayerManager.exporting)
                        }
                    }
                }.buttonStyle(.plain)
            }.padding().padding(.top, -14)
        }
        .onAppear {
            audioPlayerManager.loadAudioFiles(format: document.info.format, package: fileURL, encoder: document.info.encoder, saveMP3: document.info.exportMP3)
                audioPlayerManager.sysVol = document.info.sysVol
                audioPlayerManager.micVol = document.info.micVol
        }
        .background(WindowAccessor(onWindowOpen: { w in
            guard let w = w else { return }
            w.setContentSize(CGSize(width: 400, height: 100))
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
        }, onWindowActive: { w in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { w?.titlebarAppearsTransparent = true }
        }, onWindowDeactivate: { w in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { w?.titlebarAppearsTransparent = true }
        }, onWindowClose: { audioPlayerManager.reset() }))
    }
    
    func saveQMA() {
        var save = 0
        if document.info.sysVol != audioPlayerManager.sysVol {
            document.info.sysVol = audioPlayerManager.sysVol
            save += 1
        }
        if document.info.micVol != audioPlayerManager.micVol {
            document.info.micVol = audioPlayerManager.micVol
            save += 1
        }
        if save != 0 {
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.state = .active
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    }
}

struct VolumeSlider: View {
    @Binding var percentage: Float
    @State var maxValue: Float = 1.0
    @State private var isDragging = false
    @State private var isHover = false

    var onEditingChanged: (Bool) -> Void // Callback for editing changes

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Group {
                    Rectangle()
                        .foregroundColor(.secondary.opacity(0.2))
                    Rectangle()
                        .foregroundColor(.accentColor)
                        .frame(width: geometry.size.width * CGFloat(min(1.0, self.percentage / maxValue)))
                }.frame(height: 5).cornerRadius(12)
                Circle()
                    .shadow(radius: 1)
                    .foregroundColor(.white)
                    .opacity(isHover || isDragging ? 1.0 : 0.00001)
                    .frame(width: 16, height: 16)
                    .offset(x: geometry.size.width * CGFloat(min(1.0, self.percentage / maxValue)) - 8)
            }.onHover { hovering in isHover = hovering }
                .compositingGroup()
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        self.percentage = min(max(0, Float(value.location.x / geometry.size.width) * maxValue), maxValue)
                        self.isDragging = true // Indicate dragging
                        self.onEditingChanged(true) // Notify that editing started
                    }
                    .onEnded { value in
                        // Update the bound percentage value when dragging ends
                        self.percentage = min(max(0, Float(value.location.x / geometry.size.width) * maxValue), maxValue)
                        self.isDragging = false // Indicate dragging ended
                        self.onEditingChanged(false) // Notify that editing ended
                    }
                )
        }
    }
}

struct PlayerSlider: View {
    @Binding var percentage: Double
    @Binding var audioLength: TimeInterval
    @State private var isDragging = false
    @State private var isHover = false
    @State private var temporaryPercentage: Double = 0.0 // Temporary value during dragging

    var onEditingChanged: (Bool) -> Void // Callback for editing changes

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 2) {
                HStack {
                    Text("\(String(format: "%.2d:%.2d:%.2d", isDragging ? Int(temporaryPercentage * audioLength) / 3600 : Int(percentage * audioLength) / 3600, isDragging ? Int(temporaryPercentage * audioLength) / 60 : Int(percentage * audioLength) / 60, isDragging ? Int(temporaryPercentage * audioLength) % 60 : Int(percentage * audioLength) % 60))"
                    ).foregroundColor(.secondary)
                    Spacer()
                    Text("\(String(format: "%.2d:%.2d:%.2d", Int(audioLength) / 3600, Int(audioLength) / 60, Int(audioLength) % 60))")
                        .foregroundColor(.secondary)
                }
                ZStack(alignment: .leading) {
                    Group {
                        Rectangle()
                            .foregroundColor(.secondary.opacity(0.5))
                        Rectangle()
                            .foregroundColor(.secondary)
                            .frame(width: geometry.size.width * CGFloat(min(1.0, self.isDragging ? self.temporaryPercentage : self.percentage)))
                    }.frame(height: 4).cornerRadius(12)
                    if isHover || isDragging {
                        Rectangle()
                            .foregroundColor(.black)
                            .blendMode(.destinationOut)
                            .frame(width: 6, height: 10)
                            .offset(x: geometry.size.width * CGFloat(min(1.0, self.isDragging ? self.temporaryPercentage : self.percentage)) - 3)
                    }
                    Rectangle()
                        .cornerRadius(12)
                        .foregroundColor(.primary)
                        .opacity(isHover || isDragging ? 1.0 : 0.00001)
                        .frame(width: 4, height: 12)
                        .offset(x: geometry.size.width * CGFloat(min(1.0, self.isDragging ? self.temporaryPercentage : self.percentage)) - 2)
                }.onHover { hovering in isHover = hovering }
                    .compositingGroup()
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Update temporary percentage during dragging
                            self.temporaryPercentage = min(max(0, Double(value.location.x / geometry.size.width)), 1)
                            self.isDragging = true // Indicate dragging
                            self.onEditingChanged(true) // Notify that editing started
                        }
                        .onEnded { value in
                            // Update the bound percentage value when dragging ends
                            self.percentage = self.temporaryPercentage
                            self.isDragging = false // Indicate dragging ended
                            self.onEditingChanged(false) // Notify that editing ended
                        }
                    )
            }
        }
    }
}

struct qmaPackageHandle: FileDocument {
    static var readableContentTypes: [UTType] { [UTType.qma] }
    
    var info: Info
    var sysAudio: Data
    var micAudio: Data
    
    struct Info: Codable {
        var format: String
        var encoder: String
        var exportMP3: Bool
        var sysVol: Float
        var micVol: Float
    }
    
    init(info: Info = Info(format: "m4a", encoder: "aac", exportMP3: false, sysVol: 1.0, micVol: 1.0), sysAudio: Data = Data(), micAudio: Data = Data()) {
        self.info = info
        self.sysAudio = sysAudio
        self.micAudio = micAudio
    }

    init(configuration: ReadConfiguration) throws {
        guard let fileWrappers = configuration.file.fileWrappers else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        guard let infoFileWrapper = fileWrappers["info.json"],
              let infoData = infoFileWrapper.regularFileContents,
              let info = try? JSONDecoder().decode(Info.self, from: infoData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        self.info = info
        
        guard let sysAudioFileWrapper = fileWrappers["sys.\(info.format)"],
              let sysAudio = sysAudioFileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        self.sysAudio = sysAudio
        
        guard let micAudioFileWrapper = fileWrappers["mic.\(info.format)"],
              let micAudio = micAudioFileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        self.micAudio = micAudio
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let infoData = try JSONEncoder().encode(info)
        let infoFileWrapper = FileWrapper(regularFileWithContents: infoData)
        infoFileWrapper.preferredFilename = "info.json"
        
        let sysAudioFileWrapper = FileWrapper(regularFileWithContents: sysAudio)
        sysAudioFileWrapper.preferredFilename = "sys.\(info.format)"
        
        let micAudioFileWrapper = FileWrapper(regularFileWithContents: micAudio)
        micAudioFileWrapper.preferredFilename = "mic.\(info.format)"
        
        let fileWrapper = FileWrapper(directoryWithFileWrappers: [
            "info.json": infoFileWrapper,
            "sys.\(info.format)": sysAudioFileWrapper,
            "mic.\(info.format)": micAudioFileWrapper
        ])
        
        return fileWrapper
    }
}

extension qmaPackageHandle {
    static func loadInfo(from url: URL) throws -> Info {
        let infoURL = url.appendingPathComponent("info.json")
        let infoData = try Data(contentsOf: infoURL)
        return try JSONDecoder().decode(Info.self, from: infoData)
    }

    static func load(from url: URL) throws -> qmaPackageHandle {
        let fileWrapper = try FileWrapper(url: url, options: .immediate)
        guard let infoFileWrapper = fileWrapper.fileWrappers?["info.json"],
              let infoData = infoFileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let info = try JSONDecoder().decode(Info.self, from: infoData)

        guard let sysAudioFileWrapper = fileWrapper.fileWrappers?["sys.\(info.format)"],
              let sysAudio = sysAudioFileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard let micAudioFileWrapper = fileWrapper.fileWrappers?["mic.\(info.format)"],
              let micAudio = micAudioFileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return qmaPackageHandle(info: info, sysAudio: sysAudio, micAudio: micAudio)
    }
}

class AudioPlayerManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var isPlaying: Bool = false
    @Published var shouldPlay: Bool = false
    @Published var exporting: Bool = false
    @Published var audioLength: TimeInterval = 0
    @Published var sysVol: Float = 1.0 {
        didSet {
            updateSysVol()
        }
    }
    @Published var micVol: Float = 1.0 {
        didSet {
            updateMicVol()
        }
    }
    
    private var engine = AVAudioEngine()
    private var playerNode1 = AVAudioPlayerNode()
    private var playerNode2 = AVAudioPlayerNode()
    private var mixerNode = AVAudioMixerNode()
    private var timer: Timer?
    private var lastStartFramePosition = AVAudioFramePosition(0.0)
    private var audioFile1: AVAudioFile?
    private var audioFile2: AVAudioFile?
    private var isSeeking = false
    private var exportMP3 = false
    private var fileFormat = "m4a"
    private var fileEncoder = "aac"
    private var packageURL: URL?
    private var seekTime: Double = 0
    private var panel = NSSavePanel()
    private let offlineExportOnly: Bool
    
    init(forOfflineExportOnly: Bool = false) {
        self.offlineExportOnly = forOfflineExportOnly
        if !forOfflineExportOnly {
            setupAudioEngine()
        }
    }
    
    private func setupAudioEngine() {
        engine.attach(playerNode1)
        engine.attach(playerNode2)
        engine.attach(mixerNode)
        
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        engine.connect(playerNode1, to: mixerNode, format: outputFormat)
        engine.connect(playerNode2, to: mixerNode, format: outputFormat)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: outputFormat)
        
        do {
            try engine.start()
        } catch {
            print("Audio engine start error: \(error)")
        }
    }
    
    func loadAudioFiles(format: String, package: URL, encoder: String, saveMP3: Bool) {
        do {
            fileFormat = format
            fileEncoder = encoder
            exportMP3 = saveMP3
            packageURL = package
            audioFile1 = try AVAudioFile(forReading: package.appendingPathComponent("sys.\(format)"))
            audioFile2 = try AVAudioFile(forReading: package.appendingPathComponent("mic.\(format)"))
            
            audioLength = Double(audioFile1?.length ?? 0) / (audioFile1?.processingFormat.sampleRate ?? 48000.0)
            
            updateSysVol()
            updateMicVol()
        } catch {
            print("Error loading audio data: \(error)")
        }
    }
    
    func play() {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else { return }
        playerNode1.scheduleFile(audioFile1, at: nil, completionHandler: nil)
        playerNode2.scheduleFile(audioFile2, at: nil, completionHandler: nil)
        playerNode1.play()
        playerNode2.play()
        stopProgressTimer()
        startProgressTimer()
        isPlaying = true
    }
    
    func pause() {
        playerNode1.pause()
        playerNode2.pause()
        stopProgressTimer()
        isPlaying = false
    }
    
    func stop() {
        playerNode1.stop()
        playerNode2.stop()
        stopProgressTimer()
        lastStartFramePosition = AVAudioFramePosition(0.0)
        progress = 0.0
        isPlaying = false
    }
    
    func seek(to time: Double) {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else { return }
        playerNode1.stop()
        playerNode2.stop()
        stopProgressTimer()
        
        seekTime = time
        isSeeking = true
        
        let startFrame = AVAudioFramePosition(seekTime * audioFile1.processingFormat.sampleRate)
        let frameCount = AVAudioFrameCount(audioFile1.length - startFrame)
        
        if frameCount > 0 {
            lastStartFramePosition = startFrame
            playerNode1.scheduleSegment(audioFile1, startingFrame: startFrame, frameCount: frameCount, at: nil, completionHandler: nil)
            playerNode2.scheduleSegment(audioFile2, startingFrame: startFrame, frameCount: frameCount, at: nil, completionHandler: nil)
            progress = time / audioLength
            if isPlaying || shouldPlay {
                playerNode1.play()
                playerNode2.play()
                startProgressTimer()
                isPlaying = true
            }
        } else {
            stop()
        }
        
        
    }
    
    private func startProgressTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let lastRenderTime = self.playerNode1.lastRenderTime, let playerTime = self.playerNode1.playerTime(forNodeTime: lastRenderTime) {
                let currentTime = Double(self.lastStartFramePosition + playerTime.sampleTime) / playerTime.sampleRate
                self.progress = currentTime / self.audioLength
                if currentTime > self.audioLength {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.stop()
                    }
                }
            }
        }
    }
    
    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    func getPlayerDuration() -> TimeInterval {
        return audioLength
    }
    
    func reset() {
        stop()
        playerNode1.reset()
        playerNode2.reset()
        audioFile1 = nil
        audioFile2 = nil
    }
    
    func export() {
        guard let packageURL = packageURL else { return }
        stop()
        let format = exportMP3 ? "mp3" : self.fileFormat
        showSavePanel(defaultFileName: "\(packageURL.deletingPathExtension().appendingPathExtension(format).lastPathComponent)", exportMP3: exportMP3) { url, saveAsMP3 in
            if let url = url { self.saveFile(url, saveAsMP3: saveAsMP3) }
        }
    }
    
    func saveFile(_ url: URL, saveAsMP3: Bool = false, sourceQMAPath: String? = nil, isRecovery: Bool = false) {
        var baseTargetURL = url
        if baseTargetURL.pathExtension.lowercased() == "mp3" {
            baseTargetURL = baseTargetURL.deletingPathExtension()
        }
        if baseTargetURL.pathExtension.lowercased() != self.fileFormat.lowercased() {
            baseTargetURL = baseTargetURL.appendingPathExtension(self.fileFormat)
        }
        let finalM4AURL = baseTargetURL
        let finalMP3URL = baseTargetURL.deletingPathExtension().appendingPathExtension("mp3")
        let finalDestinationURL = saveAsMP3 ? finalMP3URL : finalM4AURL

        let sysURLSnapshot = self.packageURL?.appendingPathComponent("sys.\(self.fileFormat)") ?? self.audioFile1?.url
        let micURLSnapshot = self.packageURL?.appendingPathComponent("mic.\(self.fileFormat)") ?? self.audioFile2?.url
        let sysVolSnapshot = self.sysVol
        let micVolSnapshot = self.micVol
        let encoderSnapshot = self.fileEncoder
        let formatExtSnapshot = self.fileFormat

        // 同步登记, 保证 stopRecording() 返回时退出流程一定能看到整个导出链路 (含 MP3 二阶段转码)
        SCContext.beginAudioExport()
        Thread.detachNewThread {
            defer {
                SCContext.endAudioExport()
                DispatchQueue.main.async { self.exporting = false }
            }
            DispatchQueue.main.async { self.exporting = true }

            let targetDir = finalDestinationURL.deletingLastPathComponent()
            let token = UUID().uuidString
            let stagingAudioURL = targetDir.appendingPathComponent(".longtake-staging-\(token).\(formatExtSnapshot)")
            let stagingMP3URL = targetDir.appendingPathComponent(".longtake-staging-\(token).mp3")
            defer {
                try? fd.removeItem(at: stagingAudioURL)
                try? fd.removeItem(at: stagingMP3URL)
            }

            do {
                guard let sysURL = sysURLSnapshot, let micURL = micURLSnapshot else {
                    throw NSError(domain: "LongTakeExportError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing source audio track paths."])
                }
                let sysFile = try AVAudioFile(forReading: sysURL)
                let micFile = try AVAudioFile(forReading: micURL)

                let renderSampleRate: Double = 48000.0
                guard let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: renderSampleRate, channels: 2, interleaved: false) else {
                    throw NSError(domain: "LongTakeExportError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create offline render format."])
                }

                // 使用完全独立的离线 AVAudioEngine, 不触碰系统物理音频输出设备, 杜绝耳机插拔或设备切换导致死循环
                let offlineEngine = AVAudioEngine()
                let nodeSys = AVAudioPlayerNode()
                let nodeMic = AVAudioPlayerNode()
                let mixer = AVAudioMixerNode()
                offlineEngine.attach(nodeSys)
                offlineEngine.attach(nodeMic)
                offlineEngine.attach(mixer)

                offlineEngine.connect(nodeSys, to: mixer, format: sysFile.processingFormat)
                offlineEngine.connect(nodeMic, to: mixer, format: micFile.processingFormat)
                offlineEngine.connect(mixer, to: offlineEngine.mainMixerNode, format: renderFormat)

                nodeSys.volume = sysVolSnapshot
                nodeMic.volume = micVolSnapshot

                let maxFrames: AVAudioFrameCount = 4096
                try offlineEngine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
                try offlineEngine.start()

                if sysFile.length > 0 {
                    nodeSys.scheduleFile(sysFile, at: nil, completionHandler: nil)
                }
                if micFile.length > 0 {
                    nodeMic.scheduleFile(micFile, at: nil, completionHandler: nil)
                }
                nodeSys.play()
                nodeMic.play()

                let sysFramesAt48k = AVAudioFramePosition((Double(sysFile.length) * renderSampleRate / max(1.0, sysFile.processingFormat.sampleRate)).rounded(.up))
                let micFramesAt48k = AVAudioFramePosition((Double(micFile.length) * renderSampleRate / max(1.0, micFile.processingFormat.sampleRate)).rounded(.up))
                let totalFrames = max(AVAudioFramePosition(1024), max(sysFramesAt48k, micFramesAt48k))

                let audioSettings = SCContext.updateAudioSettings(format: encoderSnapshot, rate: Int(renderSampleRate))

                // 内部作用域确保 outputFile 在原子替换前彻底释放并完成 moov 索引写入
                do {
                    let outputFile = try AVAudioFile(forWriting: stagingAudioURL, settings: audioSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: offlineEngine.manualRenderingFormat, frameCapacity: offlineEngine.manualRenderingMaximumFrameCount) else {
                        throw NSError(domain: "LongTakeExportError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate offline PCM buffer."])
                    }

                    var stalledCount = 0
                    while offlineEngine.manualRenderingSampleTime < totalFrames {
                        let remaining = totalFrames - offlineEngine.manualRenderingSampleTime
                        let framesToRender = min(UInt32(buffer.frameCapacity), UInt32(remaining))
                        let status = try offlineEngine.renderOffline(framesToRender, to: buffer)
                        switch status {
                        case .success:
                            stalledCount = 0
                            try outputFile.write(from: buffer)
                        case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                            stalledCount += 1
                            if stalledCount > 120 {
                                throw NSError(domain: "LongTakeExportError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Offline audio rendering stalled."])
                            }
                            Thread.sleep(forTimeInterval: 0.005)
                        case .error:
                            throw NSError(domain: "LongTakeExportError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Offline audio engine returned an error."])
                        @unknown default:
                            throw NSError(domain: "LongTakeExportError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unknown offline audio render status."])
                        }
                    }
                }

                offlineEngine.stop()
                offlineEngine.disableManualRenderingMode()

                // 校验临时文件完整性: 绝不允许 28 字节残缺头进入目标目录
                let stagedSize = (try? fd.attributesOfItem(atPath: stagingAudioURL.path)[.size] as? Int64) ?? 0
                let verifyFile = try? AVAudioFile(forReading: stagingAudioURL)
                guard stagedSize > 64, let verified = verifyFile, verified.length > 0 else {
                    throw NSError(domain: "LongTakeExportError", code: 7, userInfo: [NSLocalizedDescriptionKey: "Rendered audio verification failed (size: \(stagedSize)B)."])
                }

                if saveAsMP3 {
                    let mp3Done = DispatchSemaphore(value: 0)
                    var mp3Error: Error?
                    Task.detached(priority: .userInitiated) {
                        do {
                            try await SCContext.m4a2mp3(inputUrl: stagingAudioURL, outputUrl: stagingMP3URL)
                        } catch {
                            mp3Error = error
                        }
                        mp3Done.signal()
                    }
                    mp3Done.wait()
                    if let err = mp3Error { throw err }
                    let mp3Size = (try? fd.attributesOfItem(atPath: stagingMP3URL.path)[.size] as? Int64) ?? 0
                    guard mp3Size > 128 else {
                        throw NSError(domain: "LongTakeExportError", code: 8, userInfo: [NSLocalizedDescriptionKey: "Encoded MP3 verification failed."])
                    }
                    if fd.fileExists(atPath: finalMP3URL.path) {
                        _ = try fd.replaceItemAt(finalMP3URL, withItemAt: stagingMP3URL)
                    } else {
                        try fd.moveItem(at: stagingMP3URL, to: finalMP3URL)
                    }
                } else {
                    if fd.fileExists(atPath: finalM4AURL.path) {
                        _ = try fd.replaceItemAt(finalM4AURL, withItemAt: stagingAudioURL)
                    } else {
                        try fd.moveItem(at: stagingAudioURL, to: finalM4AURL)
                    }
                }

                if let qmaPath = sourceQMAPath {
                    SCContext.clearPendingRemux(qmaPath: qmaPath)
                }

                if !isRecovery && ud.bool(forKey: "showPreview") {
                    let finalPath = finalDestinationURL.path
                    DispatchQueue.main.async {
                        SCContext.showPreview(path: finalPath, image: NSImage(named: "audioIcon"))
                    }
                }
                let title = isRecovery ? "已自动恢复未完成的录音" : "Recording Completed".local
                let body = String(format: "File saved to: %@".local, finalDestinationURL.path.removingPercentEncoding ?? finalDestinationURL.path)
                SCContext.showNotification(title: title, body: body, id: "quickrecorder.completed.\(UUID().uuidString)")
            } catch {
                SCContext.showNotification(title: "Failed to save file".local, body: "\(error.localizedDescription)", id: "quickrecorder.error.\(UUID().uuidString)")
            }
        }
    }
    
    private func updateSysVol() {
        playerNode1.volume = sysVol
    }
    
    private func updateMicVol() {
        playerNode2.volume = micVol
    }
    
    private func showSavePanel(defaultFileName: String, exportMP3: Bool, completion: @escaping (URL?, Bool) -> Void) {
        panel.isReleasedWhenClosed = true
        panel.nameFieldStringValue = defaultFileName
        panel.canCreateDirectories = true
        panel.title = "Export Recording".local
        
        let checkBox = NSButton(checkboxWithTitle: "Export as MP3".local, target: self, action: #selector(checkBoxToggled(_:)))
        checkBox.state = exportMP3 ? .on : .off
        
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: checkBox.frame.width, height: checkBox.frame.height))
        accessoryView.addSubview(checkBox)
        
        panel.accessoryView = accessoryView
        
        panel.begin { response in
            if response == .OK {
                let exportAsMP3 = (checkBox.state == .on)
                completion(self.panel.url, exportAsMP3)
            } else {
                completion(nil, false)
            }
        }
    }
    
    @objc private func checkBoxToggled(_ sender: NSButton) {
        panel.close()
        panel = NSSavePanel()
        exportMP3.toggle()
        export()
    }
}

extension UTType {
    static let qma = UTType(exportedAs: "com.lihaoyun6.QuickRecorder.qma")
}
