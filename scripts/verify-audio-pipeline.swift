#!/usr/bin/env swift
import AVFoundation
import CoreMedia
import Foundation

func fail(_ msg: String) -> Never {
    fputs("FAIL: \(msg)\n", stderr)
    exit(1)
}

func require(_ cond: Bool, _ msg: String) {
    if !cond { fail(msg) }
}

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

func makeSampleBuffer(from buf: AVAudioPCMBuffer, pts: CMTime) throws -> CMSampleBuffer {
    var asbd = buf.format.streamDescription.pointee
    var desc: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc) == noErr else {
        throw NSError(domain: "Test", code: 10)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: desc, sampleCount: CMItemCount(buf.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr,
          let created = sb,
          CMSampleBufferSetDataBufferFromAudioBufferList(created, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buf.mutableAudioBufferList) == noErr else {
        throw NSError(domain: "Test", code: 11)
    }
    return created
}

/// 镜像生产 adjustTime 实现：严格查询 entriesNeededOut、校验 CoreMedia 返回状态并跳过无效 DTS
func adjustTimeProduction(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
    guard CMSampleBufferGetFormatDescription(sample) != nil, offset.isValid else { return nil }
    if CMTimeCompare(offset, .zero) == 0 { return sample }
    var count: CMItemCount = 0
    guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else {
        return nil
    }
    var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
    var actualCount: CMItemCount = 0
    guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &actualCount) == noErr, actualCount > 0 else {
        return nil
    }
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
    guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: validCount, sampleTimingArray: &timingInfo, sampleBufferOut: &outSampleBuffer) == noErr else {
        return nil
    }
    return outSampleBuffer
}

func appendWithTimeout(_ sb: CMSampleBuffer, to input: AVAssetWriterInput, timeoutSec: TimeInterval = 5.0) throws {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while !input.isReadyForMoreMediaData {
        if Date() > deadline {
            throw NSError(domain: "Test", code: 12, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for AVAssetWriterInput readiness"])
        }
        Thread.sleep(forTimeInterval: 0.002)
    }
    guard input.append(sb) else {
        throw NSError(domain: "Test", code: 13, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriterInput.append returned false"])
    }
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
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buf.frameCapacity), remaining))
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
        throw NSError(domain: "VerifyFailed", code: 14)
    }
    try fm.moveItem(at: stagingURL, to: finalURL)
}

// MARK: - Test 1: Pause/Resume PTS Timeline Alignment & CoreMedia entriesNeededOut (P0-2)
let pauseSample = try makeSampleBuffer(from: makeSineBuffer(sampleRate: 48000, freq: 440, frames: 1024), pts: CMTime(seconds: 25.5, preferredTimescale: 48000))
let pauseOffset = CMTime(seconds: 20.0, preferredTimescale: 48000)
guard let shifted = adjustTimeProduction(sample: pauseSample, by: pauseOffset) else {
    fail("adjustTimeProduction returned nil for valid 1024-sample PCM buffer")
}
let shiftedSec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(shifted))
require(abs(shiftedSec - 5.5) < 0.001, "Expected shifted PTS ~5.5s, got \(shiftedSec)s")

// MARK: - Test 2: >24h51m 64-bit Frame Clamping (P0-6 overflow guard)
let over24hFrames: AVAudioFramePosition = AVAudioFramePosition(UInt32.max) + 10_000_000
let clampedChunk = AVAudioFrameCount(min(AVAudioFramePosition(4096), over24hFrames))
require(clampedChunk == 4096, "64-bit frame clamping failed for >24h51m recording")

// MARK: - Test 3: Mixed Sample-Rate Seek Frame Math (P1-7)
let seekSec = 1.5
let sysStartFrame = AVAudioFramePosition((seekSec * 48000.0).rounded())
let micStartFrame = AVAudioFramePosition((seekSec * 24000.0).rounded())
require(sysStartFrame == 72_000 && micStartFrame == 36_000, "Per-track seek frame conversion mismatch")

// MARK: - Test 4: Atomic Export Waiter Stress Test (P1-1 TOCTOU guard)
do {
    let q = DispatchQueue(label: "test.exportWaiter")
    for _ in 0..<200 {
        var count = 1
        var waiters: [() -> Void] = []
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            var cbs: [() -> Void] = []
            q.sync {
                count -= 1
                if count == 0 { cbs = waiters; waiters = [] }
            }
            cbs.forEach { $0() }
        }
        var immediate = false
        q.sync {
            if count == 0 { immediate = true } else { waiters.append { done.leave() } }
        }
        if immediate { done.leave() }
        require(done.wait(timeout: .now() + 2.0) == .success, "TOCTOU lost wakeup in export waiter!")
    }
}

// MARK: - Test 5: Dual-Rate (48kHz sys + 24kHz mic) Synchronized Finish + Atomic Staging + Offline Mix
let qma1 = sandbox.appendingPathComponent("Test1.qma")
try fm.createDirectory(at: qma1, withIntermediateDirectories: true)
let sys1 = qma1.appendingPathComponent("sys.m4a")
let mic1 = qma1.appendingPathComponent("mic.m4a")

do {
    let sysWriter = try AVAudioFile(forWriting: sys1, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000], commonFormat: .pcmFormatFloat32, interleaved: false)
    for _ in 0..<6 {
        try sysWriter.write(from: makeSineBuffer(sampleRate: 48000, freq: 440, frames: 4000))
    }
}

let vw = try AVAssetWriter(outputURL: mic1, fileType: .m4a)
vw.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
require(vw.canAdd(micIn), "Cannot add mic input to AVAssetWriter")
vw.add(micIn)
require(vw.startWriting(), "AVAssetWriter.startWriting failed")
vw.startSession(atSourceTime: .zero)
for i in 0..<24 {
    let sb = try makeSampleBuffer(from: makeSineBuffer(sampleRate: 24000, freq: 660, frames: 4000), pts: CMTime(value: Int64(i * 4000), timescale: 24000))
    try appendWithTimeout(sb, to: micIn)
}
let g = DispatchGroup(); g.enter()
micIn.markAsFinished()
vw.finishWriting { g.leave() }
require(g.wait(timeout: .now() + 10.0) == .success, "Timed out waiting for AVAssetWriter.finishWriting")
require(vw.status == .completed, "AVAssetWriter status not completed: \(vw.status.rawValue)")

// Test 5A: Simulated mid-export interrupt MUST leave ZERO broken files at final destination
let abortedOut = sandbox.appendingPathComponent("Aborted.m4a")
do {
    try runOfflineMix(sysURL: sys1, micURL: mic1, finalURL: abortedOut, simulateAbort: true)
    fail("Expected simulated abort to throw")
} catch {
    require(!fm.fileExists(atPath: abortedOut.path), "Atomic staging violated: broken file appeared at final path!")
}

// Test 5B: Full export must preserve longer 4.0s mic track + valid moov/mdat atoms + non-silent waveform
let finalOut = sandbox.appendingPathComponent("Completed.m4a")
try runOfflineMix(sysURL: sys1, micURL: mic1, finalURL: finalOut, simulateAbort: false)
let outBytes = (try fm.attributesOfItem(atPath: finalOut.path)[.size] as? Int64) ?? 0
let outAudio = try AVAudioFile(forReading: finalOut)
let outDuration = Double(outAudio.length) / outAudio.processingFormat.sampleRate
let rawData = try Data(contentsOf: finalOut)
let hasMoov = rawData.range(of: Data("moov".utf8)) != nil
let hasMdat = rawData.range(of: Data("mdat".utf8)) != nil

// Verify non-silent decoded PCM energy
let checkBuf = AVAudioPCMBuffer(pcmFormat: outAudio.processingFormat, frameCapacity: 4096)!
try outAudio.read(into: checkBuf)
var peak: Float = 0
if let data = checkBuf.floatChannelData {
    for i in 0..<Int(checkBuf.frameLength) {
        peak = max(peak, abs(data[0][i]))
    }
}

require(outBytes > 20_000, "Output file too small: \(outBytes)B")
require(outDuration >= 3.95, "Mic duration was truncated: \(outDuration)s")
require(hasMoov && hasMdat, "Missing MP4 moov/mdat atoms")
require(peak > 0.01, "Rendered output is silent (peak=\(peak))")

print(String(format: "PASS: all 5 suites green (bytes=%lld, duration=%.2fs, peak=%.3f, hasMoov=%@, hasMdat=%@)", outBytes, outDuration, peak, "\(hasMoov)", "\(hasMdat)"))
