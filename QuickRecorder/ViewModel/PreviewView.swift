//
//  PreviewView.swift
//  QuickRecorder
//
//  Created by apple on 2024/12/10.
//

import SwiftUI
import Combine

struct PreviewView: View {
    let frame: NSImage
    let filePath: String
    let previewID: UUID
    private let sharingDelegate = SharingServicePickerDelegate()
    @State private var isHovered: Bool = false
    @State private var isHovered2: Bool = false
    @State private var isSharing: Bool = false
    @State private var nsWindow: NSWindow?
    @State private var opacity: Double = 0.0
    @State private var dismissWorkItem: DispatchWorkItem?
    @AppStorage("trimAfterRecord") private var trimAfterRecord: Bool = false

    private var isVideoFile: Bool {
        ["mp4", "mov"].contains(filePath.pathExtension.lowercased())
    }

    var body: some View {
        ZStack(alignment: Alignment(horizontal: .leading, vertical: .top)) {
            ZStack {
                Color.clear
                    .background(.ultraThickMaterial)
                    .environment(\.controlActiveState, .active)
                    .cornerRadius(6)
                ZStack {
                    Image(nsImage: frame)
                        .resizable().scaledToFit()
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1.5)
                    if isHovered2 {
                        Button(action: {
                            if fd.fileExists(atPath: filePath) {
                                NSWorkspace.shared.open(filePath.url)
                                closeWindow()
                            }
                        }, label: {
                            ZStack {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 49))
                                    .foregroundStyle(.black)
                                    .opacity(0.5)
                                Image(systemName: "play.circle")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }
                        }).buttonStyle(.plain)
                    }
                }
                .onHover(perform: { isHovered2 = $0 })
                .padding(8)
            }
            if isHovered {
                HoverButton(color: .buttonRed, secondaryColor: .buttonRedDark,
                            action: { closeWindow() }, label: {
                    ZStack {
                        Image(systemName: "circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                        Image(systemName: "circle.fill")
                            .font(.title2)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                    }
                }).padding(4)
            }
        }
        .opacity(opacity)
        .onHover(perform: { isHovered = $0 })
        .background(WindowAccessor(onWindowOpen: { w in nsWindow = w }))
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { opacity = 1.0 }
            scheduleAutoDismiss()
        }
        .onDisappear {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            sharingDelegate.onDidChooseService = nil
        }
        .onChange(of: isHovered) { newValue in
            if newValue {
                dismissWorkItem?.cancel()
                dismissWorkItem = nil
            } else {
                scheduleAutoDismiss()
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                if fd.fileExists(atPath: filePath) {
                    NSWorkspace.shared.activateFileViewerSelecting([filePath.url])
                }
                closeWindow()
            }
            Button("Delete") {
                do {
                    // 移至废纸篓而非永久 unlink，避免误删整包 .qma 母带（P1-8）
                    try fd.trashItem(at: filePath.url, resultingItemURL: nil)
                } catch {
                    print("Failed to move file to Trash: \(error.localizedDescription)")
                }
                closeWindow()
            }
            Divider()
            Button("Copy") {
                if fd.fileExists(atPath: filePath) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([filePath.url as NSURL])
                }
                closeWindow()
            }
            Button("共享...") { showSharingServicePicker(for: filePath.url) }
            Divider()
            if !trimAfterRecord && isVideoFile {
                Button("Trim") {
                    if fd.fileExists(atPath: filePath) {
                        AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: filePath.url), title: filePath.lastPathComponent, only: false)
                    }
                    closeWindow()
                }
            }
            if #available(macOS 13, *), isVideoFile {
                Button("Make GIF") {
                    if isAppInstalled(id: "com.sindresorhus.Gifski") {
                        makeGif()
                        closeWindow()
                    } else {
                        let alert = createAlert(title: "Gifski not found",
                                                message: "Please install \"Gifski\" first to make GIF!",
                                                button1: "Open App Store", button2: "Cancel").runModal()
                        if alert == .alertFirstButtonReturn { openURL("https://apps.apple.com/app/id1351639930") }
                    }
                }
                Divider()
            }
            Button("Open Main Panel") {
                closeWindow()
                AppDelegate.shared.presentMainPanel(belowSettings: false, activateApp: true)
            }
            Button("Close") { closeWindow() }
        }
    }

    private func scheduleAutoDismiss() {
        dismissWorkItem?.cancel()
        let currentID = previewID
        let work = DispatchWorkItem {
            guard SCContext.currentPreviewID == currentID else { return }
            if !isHovered && !isSharing {
                closeWindow()
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func closeWindow() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        let currentID = previewID
        withAnimation(.easeIn(duration: 0.2)) { opacity = 0.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // 仅在仍属于本次预览代际时隐藏复用窗口，绝不误关新弹出的预览（P1-8）
            guard SCContext.currentPreviewID == currentID else { return }
            nsWindow?.orderOut(nil)
        }
    }

    private func isAppInstalled(id: String) -> Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    private func makeGif() {
        let task = Process()
        task.arguments = ["-b", "com.sindresorhus.Gifski", filePath]
        task.launchPath = "/usr/bin/open"
        try? task.run()
    }

    private func showSharingServicePicker(for url: URL) {
        guard let window = nsWindow, let contentView = window.contentView else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isSharing = true
        sharingDelegate.onDidChooseService = { service in
            // 触发后立即解除回调，防止循环引用（P2-3）
            sharingDelegate.onDidChooseService = nil
            isSharing = false
            if service != nil {
                DispatchQueue.main.async { closeWindow() }
            } else {
                scheduleAutoDismiss()
            }
        }
        let sharingPicker = NSSharingServicePicker(items: [url])
        sharingPicker.delegate = sharingDelegate
        sharingPicker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}

class SharingServicePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    var onDidChooseService: ((NSSharingService?) -> Void)?

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let cb = onDidChooseService
        onDidChooseService = nil
        cb?(service)
    }
}
