#!/usr/bin/env swift
import AVFoundation
import Foundation

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("longtake-pipeline-test-\(UUID().uuidString)")
try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }

func makeSineBuffer(sampleRate: Double, freq: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<2 {
        let ptr = buf.floatChannelData![ch]
        for i in 0..<Int(frames) {
            ptr[i] = Float(sin(2.0 * .pi * freq * Double(i) / sampleRate) * 0.25)
        }
    }
    return buf
}

func appendPCM(_ buf: AVAudioPCMBuffer, to input: AVAssetWriterInput, ptsSampleOffset: Int64) throws {
    var asbd = buf.format.streamDescription.pointee
    var desc: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc) == noErr else {
        throw NSError(domain: "Test", code: 10)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
        presentationTimeStamp: CMTime(value: ptsSampleOffset, timescale: Int32(asbd.mSampleRate)),
        decodeTimeStamp: .invalid
    )
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: desc, sampleCount: CMItemCount(buf.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr,
          CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buf.mutableAudioBufferList) == noErr else {
        throw NSError(domain: "Test", code: 11)
    }
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    input.append(sb!)
}

func runOfflineMix(sysURL: URL, micURL: URL, finalURL: URL, simulateAbort: Bool = false) throws {
    let targetDir = finalURL.deletingLastPathComponent()
    let stagingURL = targetDir.appendingPathComponent(".longtake-staging-\(UUID().uuidString).m4a")
    defer { try? fm.removeItem(at: stagingURL) }

    let sysFile = try AVAudioFile(forReading: sysURL)
    let micFile = try AVAudioFile(forReading: micURL)
    let renderRate = 48000.0
    let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: renderRate, channels: 2, interleaved: false)!

    let engine = AVAudioEngine()
    let pSys = AVAudioPlayerNode()
    let pMic = AVAudioPlayerNode()
    let mixer = AVAudioMixerNode()
    engine.attach(pSys); engine.attach(pMic); engine.attach(mixer)
    engine.connect(pSys, to: mixer, format: sysFile.processingFormat)
    engine.connect(pMic, to: mixer, format: micFile.processingFormat)
    engine.connect(mixer, to: engine.mainMixerNode, format: renderFormat)

    try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
    try engine.start()
    if sysFile.length > 0 { pSys.scheduleFile(sysFile, at: nil) }
    if micFile.length > 0 { pMic.scheduleFile(micFile, at: nil) }
    pSys.play(); pMic.play()

    let sysFrames = AVAudioFramePosition((Double(sysFile.length) * renderRate / sysFile.processingFormat.sampleRate).rounded(.up))
    let micFrames = AVAudioFramePosition((Double(micFile.length) * renderRate / micFile.processingFormat.sampleRate).rounded(.up))
    let totalFrames = max(AVAudioFramePosition(1024), max(sysFrames, micFrames))

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 256000
    ]

    do {
        let out = try AVAudioFile(forWriting: stagingURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while engine.manualRenderingSampleTime < totalFrames {
            if simulateAbort && engine.manualRenderingSampleTime >= 8192 {
                throw NSError(domain: "SimulatedInterrupt", code: 99)
            }
            let n = min(UInt32(buf.frameCapacity), UInt32(totalFrames - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(n, to: buf)
            if status == .success {
                try out.write(from: buf)
            } else {
                break
            }
        }
    }
    engine.stop()
    engine.disableManualRenderingMode()

    let size = (try fm.attributesOfItem(atPath: stagingURL.path)[.size] as? Int64) ?? 0
    let verify = try AVAudioFile(forReading: stagingURL)
    guard size > 64 && verify.length > 0 else {
        throw NSError(domain: "VerifyFailed", code: 12)
    }
    try fm.moveItem(at: stagingURL, to: finalURL)
}

// Test 1: Dual-rate (48kHz sys + 24kHz mic via AVAssetWriter) + synchronized finishWriting + offline mix
let qma1 = sandbox.appendingPathComponent("Test1.qma")
try fm.createDirectory(at: qma1, withIntermediateDirectories: true)
let sys1 = qma1.appendingPathComponent("sys.m4a")
let mic1 = qma1.appendingPathComponent("mic.m4a")

do {
    let sysWriter = try AVAudioFile(forWriting: sys1, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000], commonFormat: .pcmFormatFloat32, interleaved: false)
    // Short 0.5s system audio (24,000 frames)
    for _ in 0..<6 {
        try sysWriter.write(from: makeSineBuffer(sampleRate: 48000, freq: 440, frames: 4000))
    }
}

let vw = try AVAssetWriter(outputURL: mic1, fileType: .m4a)
vw.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
vw.add(micIn)
vw.startWriting()
vw.startSession(atSourceTime: .zero)
// Longer 4.0s mic audio at 24kHz (96,000 frames -> 192,000 frames at 48kHz!)
for i in 0..<24 {
    try appendPCM(makeSineBuffer(sampleRate: 24000, freq: 660, frames: 4000), to: micIn, ptsSampleOffset: Int64(i * 4000))
}
let g = DispatchGroup(); g.enter()
micIn.markAsFinished()
vw.finishWriting { g.leave() }
g.wait()

// Test 1A: Simulated mid-export interrupt MUST leave ZERO 28-byte files at final destination
let abortedOut = sandbox.appendingPathComponent("Aborted.m4a")
do {
    try runOfflineMix(sysURL: sys1, micURL: mic1, finalURL: abortedOut, simulateAbort: true)
    fatalError("Expected simulated abort to throw")
} catch {
    assert(!fm.fileExists(atPath: abortedOut.path), "Atomic staging violated: broken file appeared at final path!")
}

// Test 1B: Full export must preserve the longer 4.0s mic track (not truncate to 0.5s sys track!) and contain valid moov atom
let finalOut = sandbox.appendingPathComponent("Completed.m4a")
try runOfflineMix(sysURL: sys1, micURL: mic1, finalURL: finalOut, simulateAbort: false)
let outBytes = (try fm.attributesOfItem(atPath: finalOut.path)[.size] as? Int64) ?? 0
let outAudio = try AVAudioFile(forReading: finalOut)
let outDuration = Double(outAudio.length) / outAudio.processingFormat.sampleRate
let rawData = try Data(contentsOf: finalOut)
let hasMoov = rawData.range(of: Data("moov".utf8)) != nil
let hasMdat = rawData.range(of: Data("mdat".utf8)) != nil

print(String(format: "PASS: bytes=%lld, duration=%.2fs (expected ~4.00s), hasMoov=%@, hasMdat=%@", outBytes, outDuration, "\(hasMoov)", "\(hasMdat)"))
assert(outBytes > 20_000, "Output file too small!")
assert(outDuration >= 3.95, "Mic duration was truncated!")
assert(hasMoov && hasMdat, "Missing MP4 moov/mdat atoms!")
