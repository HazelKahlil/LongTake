//
//  StatusBar.swift
//  LongTake
//

import AppKit
import SwiftUI

class PopoverState: ObservableObject {
    static let shared = PopoverState()
    @Published var isShowing: Bool = false {
        didSet {
            if !isShowing {
                DispatchQueue.main.async {
                    StatusBarController.shared.closePopovers()
                }
            }
        }
    }
    @Published var isPaused: Bool = false {
        didSet {
            DispatchQueue.main.async {
                StatusBarController.shared.refresh()
            }
        }
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var tickTimer: Timer?
    private let cameraPopover = NSPopover()
    private let recordingMenu = NSMenu()
    private var wasRecording = false
    /// 用户是否在本轮录制中手动把顶部悬浮胶囊收起到了菜单栏
    private var userCollapsedRecordingBar = false

    private override init() {
        super.init()
        cameraPopover.behavior = .transient
        cameraPopover.animates = true
        recordingMenu.delegate = self
    }

    func ensureItemsInitialized() {
        if ud.bool(forKey: "showMenubar") || SCContext.streamType != nil {
            if statusBarItem == nil {
                statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
        }
    }

    private func teardownStatusItemIfNeeded() {
        if let item = statusBarItem {
            NSStatusBar.system.removeStatusItem(item)
            statusBarItem = nil
        }
    }

    func closePopovers() {
        if cameraPopover.isShown { cameraPopover.performClose(nil) }
    }

    func collapseRecordingBarToMenuBar() {
        userCollapsedRecordingBar = true
        controlPanel.orderOut(nil)
        refresh()
    }

    func revealRecordingBarOnCurrentScreen(recenter: Bool = false) {
        guard SCContext.streamType != nil else { return }
        userCollapsedRecordingBar = false
        presentRecordingBar(forceReposition: recenter || !controlPanel.isVisible)
        refresh()
    }

    func refresh() {
        let isRecording = (SCContext.streamType != nil)

        // 检测录制状态跳变：每次新开一轮录制时，自动在当前屏幕顶部展示无边框悬浮控制胶囊
        if isRecording && !wasRecording {
            userCollapsedRecordingBar = false
            presentRecordingBar(forceReposition: true)
        } else if !isRecording && wasRecording {
            userCollapsedRecordingBar = false
            controlPanel.orderOut(nil)
        }
        wasRecording = isRecording

        if !isRecording {
            stopTickTimer()
            controlPanel.orderOut(nil)
            closePopovers()

            if ud.bool(forKey: "showMenubar") {
                ensureItemsInitialized()
                guard let mainItem = statusBarItem, let mainButton = mainItem.button else { return }
                if !mainButton.subviews.isEmpty { mainButton.subviews.removeAll() }
                mainItem.menu = nil
                mainItem.length = NSStatusItem.squareLength
                let cfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
                let icon = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "LongTake")?.withSymbolConfiguration(cfg)
                icon?.isTemplate = true
                mainButton.image = icon
                mainButton.title = ""
                mainButton.imagePosition = .imageOnly
                mainButton.toolTip = "点击显示/隐藏 LongTake 主面板（右键打开菜单）"
                mainButton.target = self
                mainButton.action = #selector(handleIdleStatusBarClick(_:))
                mainButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
                mainButton.setAccessibilityLabel("LongTake")
            } else {
                // 关键修复：绝不设置 statusItem.isVisible = false（会写入 NSStatusItem VisibleCC = 0 导致控制中心永久吞图标）
                teardownStatusItemIfNeeded()
            }
            return
        }

        // MARK: - 录制中：单一原生菜单栏状态项（挂载原生 NSMenu，杜绝误点直接结束录制）+ 顶部无边框悬浮胶囊
        ensureItemsInitialized()
        if let mainItem = statusBarItem, let mainButton = mainItem.button {
            if !mainButton.subviews.isEmpty { mainButton.subviews.removeAll() }

            let isMini = ud.bool(forKey: "miniStatusBar")
            mainItem.length = isMini ? NSStatusItem.squareLength : NSStatusItem.variableLength

            if SCContext.isPaused {
                let pauseCfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
                    .applying(.init(paletteColors: [.white, NSColor.systemOrange]))
                let pauseIcon = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "已暂停录制")?.withSymbolConfiguration(pauseCfg)
                pauseIcon?.isTemplate = false
                mainButton.image = pauseIcon
                mainButton.title = isMini ? "" : " 暂停 " + SCContext.getRecordingLength()
            } else {
                let recCfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
                    .applying(.init(paletteColors: [.white, NSColor(srgbRed: 0.85, green: 0.24, blue: 0.19, alpha: 1.0)]))
                let recIcon = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "正在录制")?.withSymbolConfiguration(recCfg)
                recIcon?.isTemplate = false
                mainButton.image = recIcon
                mainButton.title = isMini ? "" : " " + SCContext.getRecordingLength()
            }
            mainButton.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
            mainButton.imagePosition = isMini ? .imageOnly : .imageLeading
            mainButton.toolTip = "点击打开录制控制菜单（暂停 / 停止）"
            mainButton.target = nil
            mainButton.action = nil
            mainItem.menu = recordingMenu
        }

        if !userCollapsedRecordingBar {
            if !controlPanel.isVisible {
                presentRecordingBar(forceReposition: true)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.syncRecordingBarSizeIfVisible()
                }
            }
        }

        startTickTimerIfNeeded()
    }

    func syncRecordingBarSizeIfVisible() {
        guard controlPanel.isVisible, let hosting = controlPanel.contentView else { return }
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let intrinsic = hosting.intrinsicContentSize
        let measuredW = max(fit.width, intrinsic.width)
        let measuredH = max(fit.height, intrinsic.height)
        let newWidth = ceil(max(326, measuredW)) + 6
        let newHeight = ceil(max(58, measuredH)) + 2
        if abs(controlPanel.frame.width - newWidth) > 1 || abs(controlPanel.frame.height - newHeight) > 1 {
            let midX = controlPanel.frame.midX
            var newOriginX = round(midX - newWidth / 2)
            var newOriginY = controlPanel.frame.origin.y
            if let visible = (controlPanel.screen ?? NSScreen.main)?.visibleFrame {
                newOriginX = min(max(newOriginX, visible.minX + 8), visible.maxX - newWidth - 8)
                newOriginY = min(max(newOriginY, visible.minY + 8), visible.maxY - newHeight - 4)
            }
            controlPanel.setFrame(NSRect(x: newOriginX, y: newOriginY, width: newWidth, height: newHeight), display: true)
        }
    }

    private func presentRecordingBar(forceReposition: Bool) {
        guard SCContext.streamType != nil else { return }
        controlPanel.sharingType = ud.bool(forKey: "hideSelf") ? .none : .readOnly
        controlPanel.hidesOnDeactivate = false
        controlPanel.hasShadow = false
        controlPanel.isOpaque = false
        controlPanel.backgroundColor = .clear

        let hosting = NSHostingView(rootView: FloatingRecordingPillView())
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.intrinsicContentSize]
        }
        controlPanel.contentView = hosting
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let intrinsic = hosting.intrinsicContentSize
        let width = ceil(max(326, max(fit.width, intrinsic.width))) + 6
        let height = ceil(max(58, max(fit.height, intrinsic.height))) + 2

        if let screen = SCContext.getScreenWithMouse() ?? NSScreen.main {
            let visible = screen.visibleFrame
            if forceReposition || controlPanel.screen != screen || !visible.intersects(controlPanel.frame) {
                let x = round(visible.midX - width / 2)
                let y = round(visible.maxY - height - 6)
                controlPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            } else {
                let clampedX = min(max(controlPanel.frame.origin.x, visible.minX + 8), visible.maxX - width - 8)
                let clampedY = min(max(controlPanel.frame.origin.y, visible.minY + 8), visible.maxY - height - 4)
                controlPanel.setFrame(NSRect(x: clampedX, y: clampedY, width: width, height: height), display: true)
            }
        }
        controlPanel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.syncRecordingBarSizeIfVisible()
        }
    }

    private func startTickTimerIfNeeded() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.handleTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func handleTick() {
        guard SCContext.streamType != nil else {
            refresh()
            return
        }
        if !ud.bool(forKey: "miniStatusBar"), let mainButton = statusBarItem?.button {
            mainButton.title = (SCContext.isPaused ? " 暂停 " : " ") + SCContext.getRecordingLength()
        }
        if let start = SCContext.startTime, !SCContext.isPaused, SCContext.autoStop != 0 {
            let elapsedMinutes = Date.now.timeIntervalSince(start) / 60.0
            if elapsedMinutes >= Double(SCContext.autoStop) {
                stopRecordingAction(nil)
                return
            }
        }
    }

    // MARK: - 菜单栏点击事件

    @objc private func handleIdleStatusBarClick(_ sender: Any?) {
        let eventType = NSApp.currentEvent?.type
        if eventType == .rightMouseUp || (NSApp.currentEvent?.modifierFlags.contains(.control) == true) {
            presentIdleContextMenu()
        } else {
            AppDelegate.shared.toggleMainPanel()
        }
    }

    private func presentIdleContextMenu() {
        guard let button = statusBarItem?.button else { return }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Main Panel".local, action: #selector(openMainPanelFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Preferences…".local, action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit".local, action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recordingMenu else { return }
        menu.removeAllItems()
        guard SCContext.streamType != nil else { return }

        let statusHeader = NSMenuItem(
            title: (SCContext.isPaused ? "⏸ 已暂停 · " : "● 正在录制 · ") + SCContext.getRecordingLength(),
            action: nil,
            keyEquivalent: ""
        )
        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        menu.addItem(.separator())

        if SCContext.streamType != .idevice {
            let pauseTitle = SCContext.isPaused ? "继续录制" : "暂停录制"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(pauseResumeAction(_:)), keyEquivalent: "")
            pauseItem.image = NSImage(systemSymbolName: SCContext.isPaused ? "play.fill" : "pause.fill", accessibilityDescription: pauseTitle)
            pauseItem.target = self
            menu.addItem(pauseItem)
        }

        let stopItem = NSMenuItem(title: "停止录制并保存", action: #selector(stopRecordingAction(_:)), keyEquivalent: "")
        stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止录制并保存")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let toggleBarTitle = controlPanel.isVisible ? "收起顶部悬浮控制条" : "显示顶部悬浮控制条"
        let toggleBarItem = NSMenuItem(title: toggleBarTitle, action: #selector(toggleFloatingBarFromMenu), keyEquivalent: "")
        toggleBarItem.target = self
        menu.addItem(toggleBarItem)

        if let st = SCContext.streamType, st != .systemaudio && st != .window && st != .idevice {
            let snapItem = NSMenuItem(title: "Save Current Frame".local, action: #selector(captureFrameFromMenu), keyEquivalent: "")
            snapItem.target = self
            menu.addItem(snapItem)
        }
    }

    @objc private func openMainPanelFromMenu() {
        AppDelegate.shared.presentMainPanel(belowSettings: false, activateApp: true)
    }

    @objc private func openSettingsFromMenu() {
        closeMainWindow()
        AppDelegate.shared.openSettingPanel()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func toggleFloatingBarFromMenu() {
        if controlPanel.isVisible {
            collapseRecordingBarToMenuBar()
        } else {
            revealRecordingBarOnCurrentScreen(recenter: true)
        }
    }

    @objc private func captureFrameFromMenu() {
        if SCContext.stream != nil { SCContext.saveFrame = true }
    }

    @objc func stopRecordingAction(_ sender: Any?) {
        closePopovers()
        if SCContext.streamType == .idevice {
            AVOutputClass.shared.stopRecording()
        } else {
            SCContext.stopRecording()
        }
        refresh()
    }

    @objc func pauseResumeAction(_ sender: Any?) {
        guard SCContext.streamType != nil && SCContext.streamType != .idevice else { return }
        SCContext.pauseRecording()
        refresh()
    }

    func toggleCameraAccessory(relativeTo view: NSView?) {
        if SCContext.streamType == .idevice {
            if deviceWindow.isVisible { deviceWindow.orderOut(nil) } else { deviceWindow.orderFront(nil) }
            refresh()
            return
        }
        if cameraPopover.isShown {
            cameraPopover.performClose(nil)
        } else if let anchorView = view ?? controlPanel.contentView {
            cameraPopover.contentViewController = NSHostingController(
                rootView: CameraPopoverView(closePopover: { [weak self] in self?.cameraPopover.performClose(nil) })
            )
            cameraPopover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        }
    }
}

/// 录制期间置顶展示的无边框单行高对比控制条（等字数固定槽位，杜绝换行、截断与宽度抖动）
struct FloatingRecordingPillView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var popoverState = PopoverState.shared
    @AppStorage("panelOpacity") private var panelOpacity: Double = 0.86
    @State private var lengthText = SCContext.getRecordingLength()
    @State private var gripHover = false
    @State private var pauseHover = false
    @State private var stopHover = false
    @State private var camHover = false
    @State private var hideHover = false
    private let pillTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var backingColor: Color {
        colorScheme == .dark
            ? Color(red: 0.125, green: 0.130, blue: 0.142)
            : Color(red: 0.976, green: 0.973, blue: 0.964)
    }

    var body: some View {
        let shape = Capsule()
        let content = pillContent

        Group {
            if #available(macOS 26.0, *) {
                content
                    .background {
                        shape
                            .inset(by: 0.5)
                            .fill(backingColor.opacity(max(0.92, panelOpacity)))
                    }
                    .overlay {
                        shape
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 0.8)
                            .allowsHitTesting(false)
                    }
                    .glassEffect(.regular, in: shape)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.38 : 0.18), radius: 10, x: 0, y: 4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                content
                    .background {
                        shape.fill(.thickMaterial)
                        shape.fill(backingColor.opacity(max(0.92, panelOpacity)))
                    }
                    .overlay {
                        shape
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 0.8)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.38 : 0.18), radius: 10, x: 0, y: 4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .onReceive(pillTimer) { _ in
            let updated = SCContext.getRecordingLength()
            let countChanged = (updated.count != lengthText.count)
            lengthText = updated
            if countChanged {
                DispatchQueue.main.async {
                    StatusBarController.shared.syncRecordingBarSizeIfVisible()
                }
            }
        }
    }

    private var pillContent: some View {
        HStack(alignment: .center, spacing: 8) {
            // 1. 左侧即时拖拽握把
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(gripHover ? 0.08 : 0.0001))
                VStack(spacing: 3.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 3.5) {
                            Circle().frame(width: 2.8, height: 2.8)
                            Circle().frame(width: 2.8, height: 2.8)
                        }
                    }
                }
                .foregroundStyle(Color.primary.opacity(gripHover ? 0.68 : 0.36))
                WindowDragHandle(isHovering: $gripHover)
            }
            .frame(width: 20, height: 28)
            .help("按住拖动控制条")

            // 2. 状态与计时槽位：「录制中」与「已暂停」同为 3 字，切换零跳动、绝不换行
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(popoverState.isPaused ? Color.orange : Color(red: 0.85, green: 0.23, blue: 0.18))
                    .frame(width: 8.5, height: 8.5)

                Text(popoverState.isPaused ? "已暂停" : "录制中")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(popoverState.isPaused ? Color.orange : Color.primary.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text(lengthText)
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 2)
            }
            .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            // 3. 明确的「暂停 / 继续」胶囊按钮（同为 2 字，位置恒定）
            if SCContext.streamType != .idevice {
                Button {
                    StatusBarController.shared.pauseResumeAction(nil)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: popoverState.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(popoverState.isPaused ? "继续" : "暂停")
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(
                        popoverState.isPaused
                            ? (colorScheme == .dark ? Color.orange : Color(red: 0.78, green: 0.38, blue: 0.0))
                            : Color.primary.opacity(0.92)
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        Capsule()
                            .fill(
                                popoverState.isPaused
                                    ? Color.orange.opacity(pauseHover ? 0.24 : 0.16)
                                    : Color.primary.opacity(pauseHover ? 0.13 : 0.075)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        popoverState.isPaused
                                            ? Color.orange.opacity(0.38)
                                            : Color.primary.opacity(0.10),
                                        lineWidth: 0.6
                                    )
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(SelectorTileButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .onHover { pauseHover = $0 }
                .help(popoverState.isPaused ? "继续录制" : "暂停录制")
            }

            // 4. 明确的「停止」按钮（朱砂实底白字，高可读对比）
            Button {
                StatusBarController.shared.stopRecordingAction(nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("停止")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(Color(red: 0.83, green: 0.23, blue: 0.17).opacity(stopHover ? 1.0 : 0.92))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(SelectorTileButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .onHover { stopHover = $0 }
            .help("停止录制并保存文件")

            // 5. 视频模式附加摄像头按钮
            if let st = SCContext.streamType, st != .systemaudio && st != .window {
                Button {
                    StatusBarController.shared.toggleCameraAccessory(relativeTo: nil)
                } label: {
                    Image(systemName: st == .idevice ? "ipad.and.iphone" : (SCContext.isCameraRunning() ? "video.fill" : "video"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.86))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(camHover ? 0.13 : 0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(SelectorTileButtonStyle())
                .fixedSize()
                .onHover { camHover = $0 }
                .help("摄像头与附加画面")
            }

            // 6. 收起至顶部菜单栏按钮
            Button {
                StatusBarController.shared.collapseRecordingBarToMenuBar()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(hideHover ? 0.90 : 0.52))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(hideHover ? 0.12 : 0.0001)))
                    .contentShape(Circle())
            }
            .buttonStyle(SelectorTileButtonStyle())
            .fixedSize()
            .onHover { hideHover = $0 }
            .help("收起悬浮条（可从顶部菜单栏随时呼出或停止）")
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: 42)
        .fixedSize(horizontal: true, vertical: true)
    }
}

func updateStatusBar() {
    DispatchQueue.main.async {
        StatusBarController.shared.refresh()
    }
}
