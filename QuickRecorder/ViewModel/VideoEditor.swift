import UniformTypeIdentifiers
import UserNotifications
import SwiftUI
import AVKit

class RecorderPlayerModel: NSObject, ObservableObject {
    @Published var playerView: AVPlayerView
    var asset: AVAsset?
    var fileUrl: URL?
    var playerItem: AVPlayerItem?
    weak var nsWindow: NSWindow?
    private var isObservingStatus = false
    private var timeJumpedObserver: NSObjectProtocol?

    override init() {
        self.playerView = AVPlayerView()
        super.init()
        self.playerView.player = AVPlayer()
    }

    deinit {
        cleanup()
    }

    func loadVideo(fromUrl: URL, completion: @escaping () -> Void) {
        removeObservers()
        fileUrl = fromUrl
        let newAsset = AVAsset(url: fromUrl)
        asset = newAsset
        let item = AVPlayerItem(asset: newAsset)
        playerItem = item
        playerView.player?.replaceCurrentItem(with: item)
        playerView.controlsStyle = .inline

        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.new], context: nil)
        isObservingStatus = true

        // 持有观察者令牌并使用 [weak self]，防止关闭裁剪窗后泄漏模型、窗口和 playerItem（P2-3）
        timeJumpedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.playerView.canBeginTrimming {
                completion()
            }
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let item = object as? AVPlayerItem, keyPath == #keyPath(AVPlayerItem.status) else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if item.status == .readyToPlay {
            if isObservingStatus {
                item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
                isObservingStatus = false
            }

            if self.playerView.canBeginTrimming {
                self.playerView.beginTrimming { [weak self] result in
                    guard let self = self else { return }
                    if result == .okButton {
                        guard let fileUrl = self.fileUrl, let asset = self.asset else { return }
                        let startTime = item.reversePlaybackEndTime
                        let endTime = item.forwardPlaybackEndTime
                        let timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)
                        let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
                        let dateFormatter = DateFormatter()
                        let fileEnding = fileUrl.pathExtension.lowercased()
                        let fileType: AVFileType = (fileEnding == VideoFormat.mov.rawValue) ? .mov : .mp4
                        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
                        let stem = fileUrl.deletingPathExtension().path
                        let preferredPath = (stem.removingPercentEncoding ?? stem) + " (Cropped in ".local + "\(dateFormatter.string(from: Date())))." + fileEnding
                        let finalURL = SCContext.nonCollidingDestinationURL(for: preferredPath.url)
                        exportSession?.outputURL = finalURL
                        exportSession?.outputFileType = fileType
                        exportSession?.timeRange = timeRange
                        exportSession?.exportAsynchronously {
                            if let error = exportSession?.error {
                                print("Error: \(error.localizedDescription)")
                            } else {
                                SCContext.showNotification(
                                    title: "Clip Saved".local,
                                    body: String(format: "File saved to: %@".local, finalURL.path),
                                    id: "quickrecorder.completed.\(UUID().uuidString)"
                                )
                            }
                        }
                        self.nsWindow?.close()
                    } else {
                        self.nsWindow?.close()
                    }
                }
            }
        }
    }

    private func removeObservers() {
        if isObservingStatus, let item = playerItem {
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
            isObservingStatus = false
        }
        if let token = timeJumpedObserver {
            NotificationCenter.default.removeObserver(token)
            timeJumpedObserver = nil
        }
    }

    func cleanup() {
        removeObservers()
        playerView.player?.pause()
        playerView.player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        playerItem = nil
        asset = nil
    }
}

struct RecorderPlayerView: NSViewRepresentable {
    typealias NSViewType = AVPlayerView
    var playerView: AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView {
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

struct VideoTrimmerView: View {
    let videoURL: URL
    @StateObject var playerViewModel: RecorderPlayerModel = .init()

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 13, weight: .bold))
                    .offset(y: 0.5)
                Text(videoURL.lastPathComponent)
                    .font(.system(size: 13, weight: .bold))
            }
            ZStack {
                RecorderPlayerView(playerView: playerViewModel.playerView)
                    .onAppear { playerViewModel.loadVideo(fromUrl: videoURL) {} }
                    .padding(4)
                    .background(
                        Rectangle()
                            .foregroundStyle(.black)
                            .cornerRadius(5)
                    )
            }.padding([.bottom, .leading, .trailing])
        }
        .padding(.top, -22)
        .background(WindowAccessor(onWindowOpen: { window in
            window?.styleMask.insert(.resizable)
            playerViewModel.nsWindow = window
            if !SCContext.trimingList.contains(videoURL) {
                SCContext.trimingList.append(videoURL)
            }
        }, onWindowClose: {
            playerViewModel.cleanup()
            SCContext.trimingList.removeAll(where: { $0 == videoURL })
        }))
    }
}
