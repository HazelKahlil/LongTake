//
//  QuickRecorderApp.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AppKit
import SwiftUI
import AVFAudio
import AVFoundation
import ScreenCaptureKit
import UserNotifications
import KeyboardShortcuts
import ServiceManagement
import CoreMediaIO
import Sparkle

let isMacOS12 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 12
let isMacOS14 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14
let isMacOS15 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15
var scPerm = false
let fd = FileManager.default
let ud = UserDefaults.standard
var statusBarItem: NSStatusItem!
var mouseMonitor: Any?
var keyMonitor: Any?
var hideMousePointer = false
var hideScreenMagnifier = false
let updateTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
final class FloatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

let mousePointer = NSWindow(contentRect: NSRect(x: -70, y: -70, width: 70, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
let screenMagnifier = NSWindow(contentRect: NSRect(x: -402, y: -402, width: 402, height: 348), styleMask: [.borderless], backing: .buffered, defer: false)
let camWindow = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 200), styleMask: [.fullSizeContentView, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
let deviceWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 200), styleMask: [.fullSizeContentView, .resizable], backing: .buffered, defer: false)
let controlPanel = FloatingHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let countdownPanel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
let previewWindow = FloatingHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 266, height: 156), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let savingHUDPanel = FloatingHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
var updaterController: SPUStandardUpdaterController!

@main
struct QuickRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
        
    init() {
        // 本地定制版禁用 Sparkle 自动启动轮询, 防止被上游 QuickRecorder 覆盖导致 28B 缺陷复活
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }
    
    var body: some Scene {
        DocumentGroup(newDocument: qmaPackageHandle()) { file in
            //if SCContext.stream == nil {
                if let fileURL = file.fileURL {
                    qmaPlayerView(document: file.$document, fileURL: fileURL)
                        .frame(minWidth: 400, minHeight: 100, maxHeight: 100)
                        .focusable(false)
                }
            //}
        }
        .myWindowIsContentResizable()
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .textEditing) {}
        }
        
        Settings {
            SettingsView()
                .background(
                    WindowAccessor(
                        onWindowOpen: { w in
                            if let w = w {
                                //w.level = .floating
                                w.titlebarSeparatorStyle = .none
                                guard let nsSplitView = findNSSplitVIew(view: w.contentView),
                                      let controller = nsSplitView.delegate as? NSSplitViewController else { return }
                                controller.splitViewItems.first?.canCollapse = false
                                controller.splitViewItems.first?.minimumThickness = 140
                                controller.splitViewItems.first?.maximumThickness = 140
                                w.orderFront(nil)
                            }
                        })
                )
        }
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

extension Scene {
    func myWindowIsContentResizable() -> some Scene {
        if #available(macOS 13.0, *) {
            return self.windowResizability(.contentSize)
        }
        else {
            return self
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, SCStreamDelegate, SCStreamOutput, AVCaptureVideoDataOutputSampleBufferDelegate  {
    static let shared = AppDelegate()
    var mainPanelWindow: EscPanel?
    var filter: SCContentFilter?
    var isCameraReady = false
    var isPresenterON = false
    var isResizing = false
    var presenterType = "OFF"
    var frameQueue = FixedLengthArray<CMTime>(maxLength: 20)
    
    @AppStorage("showOnDock")       var showOnDock: Bool = true
    @AppStorage("showMenubar")      var showMenubar: Bool = true
    @AppStorage("enableAEC")        var enableAEC: Bool = false
    @AppStorage("recordMic")        var recordMic: Bool = false
    @AppStorage("micDevice")        var micDevice: String = "default"
    @AppStorage("remuxAudio")       var remuxAudio: Bool = true
    @AppStorage("recordWinSound")   var recordWinSound: Bool = true
    @AppStorage("recordHDR")        var recordHDR: Bool = false
    @AppStorage("encoder")          var encoder: Encoder = .h265
    @AppStorage("highRes")          var highRes: Int = 2
    @AppStorage("AECLevel")         var AECLevel: String = "mid"
    @AppStorage("withAlpha")        var withAlpha: Bool = false
    @AppStorage("saveDirectory")    var saveDirectory: String?
    @AppStorage("countdown")        var countdown: Int = 0
    @AppStorage("poSafeDelay")      var poSafeDelay: Int = 1
    @AppStorage("highlightMouse")   var highlightMouse: Bool = false
    @AppStorage("includeMenuBar")   var includeMenuBar: Bool = true
    @AppStorage("hideDesktopFiles") var hideDesktopFiles: Bool = false
    @AppStorage("trimAfterRecord")  var trimAfterRecord: Bool = false
    @AppStorage("miniStatusBar")    var miniStatusBar: Bool = false
    @AppStorage("hideSelf")         var hideSelf: Bool = true
    @AppStorage("preventSleep")     var preventSleep: Bool = true
    @AppStorage("showPreview")      var showPreview: Bool = true
    @AppStorage("background")       var background: BackgroundType = .wallpaper
    @AppStorage("showMouse")        var showMouse: Bool = true
    @AppStorage("frameRate")        var frameRate: Int = 60
    @AppStorage("videoQuality")     var videoQuality: Double = 1.0
    @AppStorage("videoFormat")      var videoFormat: VideoFormat = .mp4
    @AppStorage("audioFormat")      var audioFormat: AudioFormat = .aac
    @AppStorage("audioQuality")     var audioQuality: AudioQuality = .high
    @AppStorage("pixelFormat")      var pixelFormat: PixFormat = .delault
    @AppStorage("hideCCenter")      var hideCCenter: Bool = false
    
    func mousePointerReLocation(event: NSEvent) {
        if event.type == .scrollWheel { return }
        if !highlightMouse || hideMousePointer || SCContext.stream == nil || SCContext.streamType == .window {
            mousePointer.orderOut(nil)
            return
        }
        let mouseLocation = event.locationInWindow
        var windowFrame = mousePointer.frame
        windowFrame.origin = NSPoint(x: mouseLocation.x - windowFrame.width / 2, y: mouseLocation.y - windowFrame.height / 2)
        mousePointer.contentView = NSHostingView(rootView: MousePointerView(event: event))
        mousePointer.setFrameOrigin(windowFrame.origin)
        mousePointer.orderFront(nil)
    }
    
    func screenMagnifierReLocation(event: NSEvent) {
        if !SCContext.isMagnifierEnabled || hideScreenMagnifier { screenMagnifier.orderOut(nil); return }
        let mouseLocation = event.locationInWindow
        var windowFrame = screenMagnifier.frame
        windowFrame.origin = NSPoint(x: mouseLocation.x - windowFrame.width / 2, y: mouseLocation.y - windowFrame.height / 2)
        guard let image = NSImage.createScreenShot() else { return }
        let rect = NSRect(x: mouseLocation.x - 67, y: mouseLocation.y - 58, width: 134, height: 116)
        let croppedImage = image.trim(rect: rect)
        screenMagnifier.contentView = NSHostingView(rootView: ScreenMagnifier(screenShot: croppedImage, event: event))
        screenMagnifier.setFrameOrigin(windowFrame.origin)
        screenMagnifier.orderFront(nil)
    }
    
    func registerGlobalMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .rightMouseUp, .rightMouseDown, .rightMouseDragged, .leftMouseUp,  .leftMouseDown, .leftMouseDragged, .otherMouseUp, .otherMouseDown, .otherMouseDragged]) { event in
            self.mousePointerReLocation(event: event)
            self.screenMagnifierReLocation(event: event)
        }
    }
        
    func stopGlobalMouseMonitor() {
        mousePointer.orderOut(nil)
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor); mouseMonitor = nil }
    }
    
    // MARK: - 退出保护与可见封存提示
    private var pendingTermination = false

    private func showSavingHUD() {
        DispatchQueue.main.async {
            let hudLabel = HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在封存录音母带，完成后自动退出…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            let rootHUD: AnyView
            if #available(macOS 26.0, *) {
                rootHUD = AnyView(
                    hudLabel
                        .glassEffect(.regular, in: Capsule())
                        .padding(8)
                )
            } else {
                rootHUD = AnyView(
                    hudLabel
                        .background(
                            Capsule()
                                .fill(.regularMaterial)
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        )
                )
            }

            let hosting = NSHostingView(rootView: rootHUD)
            let size = hosting.fittingSize
            savingHUDPanel.setContentSize(NSSize(width: max(300, size.width), height: max(48, size.height)))
            savingHUDPanel.contentView = hosting
            savingHUDPanel.backgroundColor = .clear
            savingHUDPanel.isOpaque = false
            if #available(macOS 26.0, *) {
                savingHUDPanel.hasShadow = false
            } else {
                savingHUDPanel.hasShadow = true
            }
            savingHUDPanel.level = .statusBar
            savingHUDPanel.hidesOnDeactivate = false
            savingHUDPanel.sharingType = .none
            savingHUDPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if let screen = SCContext.getScreenWithMouse() ?? NSScreen.main {
                let x = screen.frame.midX - savingHUDPanel.frame.width / 2
                let y = screen.visibleFrame.maxY - savingHUDPanel.frame.height - 24
                savingHUDPanel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            savingHUDPanel.orderFrontRegardless()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pendingTermination { return .terminateNow }

        let isRecording = SCContext.stream != nil || SCContext.streamType != nil
        let exporting = SCContext.audioExportsInProgress > 0
        if !isRecording && !exporting { return .terminateNow }

        pendingTermination = true
        showSavingHUD()
        SCContext.showNotification(title: "正在保存录音",
                                   body: "母带合成落盘后将自动退出，请勿强制关闭。",
                                   id: "quickrecorder.saving.onquit")
        if isRecording {
            SCContext.stopRecording()
        }

        var replied = false
        let finishQuit: () -> Void = {
            guard !replied else { return }
            replied = true
            savingHUDPanel.orderOut(nil)
            sender.reply(toApplicationShouldTerminate: true)
        }
        SCContext.whenAudioExportsFinished(finishQuit)
        // 安全阀: 最多等 10 分钟, 绝不无限期卡住退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            finishQuit()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if SCContext.stream != nil { SCContext.stopRecording() }
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if SCContext.trimingList.contains(url) { continue }
            createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, random: true, only: false)
            closeMainWindow()
        }
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        if ud.string(forKey: "saveDirectory") == nil,
           let legacy = UserDefaults(suiteName: "com.lihaoyun6.QuickRecorder.fixed") {
            let keysToMigrate = [
                "audioFormat", "audioQuality", "background", "frameRate", "highRes",
                "hideSelf", "highlightMouse", "hideDesktopFiles", "includeMenuBar",
                "videoQuality", "countdown", "videoFormat", "pixelFormat", "encoder",
                "poSafeDelay", "saveDirectory", "showMouse", "recordMic", "remuxAudio",
                "recordWinSound", "trimAfterRecord", "showOnDock", "showMenubar",
                "enableAEC", "recordHDR", "preventSleep", "showPreview", "savedArea",
                "micDevice", "miniStatusBar", "neverRemindMe"
            ]
            for key in keysToMigrate {
                if let val = legacy.object(forKey: key) {
                    ud.set(val, forKey: key)
                }
            }
        }

        scPerm = SCContext.updateAvailableContentSync() != nil
        
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.kahlilhazel.LongTake"
        let process = NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == selfBundleID })
        if process.count > 1 {
            DispatchQueue.main.async {
                let button = createAlert(title: "LongTake is Running".local, message: "Please do not run multiple instances!".local, button1: "Quit".local).runModal()
                if button == .alertFirstButtonReturn { NSApp.terminate(self) }
            }
        }
        
        lazy var userDesktop = (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true) as [String]).first!
        
        ud.register( // default defaults (used if not set)
            defaults: [
                "audioFormat": AudioFormat.aac.rawValue,
                "audioQuality": AudioQuality.high.rawValue,
                "background": BackgroundType.wallpaper.rawValue,
                "frameRate": 60,
                "highRes": 2,
                "hideSelf": true,
                "highlightMouse" : false,
                "hideDesktopFiles": false,
                "includeMenuBar": true,
                "videoQuality": 1.0,
                "countdown": 0,
                "videoFormat": VideoFormat.mp4.rawValue,
                "pixelFormat": PixFormat.delault.rawValue,
                "encoder": Encoder.h264.rawValue,
                "poSafeDelay": 1,
                "saveDirectory": userDesktop as NSString,
                "showMouse": true,
                "recordMic": false,
                "remuxAudio": isMacOS12 ? false : true,
                "recordWinSound": isMacOS12 ? false : true,
                "trimAfterRecord": false,
                "showOnDock": true,
                "showMenubar": true,
                "enableAEC": false,
                "recordHDR": false,
                "preventSleep": true,
                "showPreview": isMacOS12 ? false : true,
                "panelOpacity": 0.86,
                "savedArea": [String: [String: CGFloat]]()
            ]
        )
        
        // 清理旧版频繁切换 NSStatusItem.isVisible = false 导致系统控制中心写入的隐藏标记, 并为 v1.5 默认开启顶部菜单栏常驻图标
        for pollutedKey in ["NSStatusItem VisibleCC Item-0", "NSStatusItem VisibleCC Item-1", "NSStatusItem VisibleCC Item-2",
                            "NSStatusItem Visible Item-0", "NSStatusItem Visible Item-1", "NSStatusItem Visible Item-2"] {
            ud.removeObject(forKey: pollutedKey)
        }
        if !ud.bool(forKey: "longTakeDidInitMenuBarV15") {
            ud.set(true, forKey: "longTakeDidInitMenuBarV15")
            ud.set(true, forKey: "showMenubar")
        }

        if highRes == 0 { highRes = 2 }
        if showOnDock { NSApp.setActivationPolicy(.regular) }
        if isMacOS12 { showPreview = false; remuxAudio = false }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error { print("Notification authorization denied: \(error.localizedDescription)") }
        }
        
        var allow : UInt32 = 1
        let dataSize : UInt32 = 4
        let zero : UInt32 = 0
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, zero, nil, dataSize, &allow)

        StatusBarController.shared.ensureItemsInitialized()

        mousePointer.title = "Mouse Pointer".local
        mousePointer.level = .screenSaver
        mousePointer.ignoresMouseEvents = true
        mousePointer.isReleasedWhenClosed = false
        mousePointer.backgroundColor = NSColor.clear
        
        screenMagnifier.title = "Screen Magnifier".local
        screenMagnifier.level = .floating
        screenMagnifier.ignoresMouseEvents = true
        screenMagnifier.isReleasedWhenClosed = false
        screenMagnifier.backgroundColor = NSColor.clear
        
        camWindow.title = "Camera Overlayer".local
        camWindow.level = .floating
        camWindow.isReleasedWhenClosed = false
        camWindow.isMovableByWindowBackground = true
        camWindow.backgroundColor = NSColor.clear
        camWindow.collectionBehavior = [.canJoinAllSpaces]
        
        countdownPanel.title = "Countdown Panel".local
        countdownPanel.level = .floating
        countdownPanel.isReleasedWhenClosed = false
        countdownPanel.isMovableByWindowBackground = false
        countdownPanel.backgroundColor = NSColor.clear
        
        deviceWindow.title = "iDevice Overlayer".local
        deviceWindow.level = .floating
        deviceWindow.isReleasedWhenClosed = false
        deviceWindow.isMovableByWindowBackground = true
        deviceWindow.backgroundColor = NSColor.clear
        
        controlPanel.title = "Recording Controller".local
        controlPanel.level = .statusBar
        controlPanel.isOpaque = false
        controlPanel.hasShadow = false
        controlPanel.hidesOnDeactivate = false
        controlPanel.sharingType = hideSelf ? .none : .readOnly
        controlPanel.backgroundColor = NSColor.clear
        controlPanel.isReleasedWhenClosed = false
        controlPanel.isMovableByWindowBackground = true
        controlPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        previewWindow.level = .statusBar
        previewWindow.isOpaque = false
        previewWindow.hasShadow = true
        previewWindow.hidesOnDeactivate = false
        previewWindow.isReleasedWhenClosed = false
        previewWindow.backgroundColor = .clear
        previewWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        KeyboardShortcuts.onKeyDown(for: .showPanel) {
            _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
            if SCContext.stream == nil { NSApp.activate(ignoringOtherApps: true) }
        }
        KeyboardShortcuts.onKeyDown(for: .saveFrame) { if SCContext.stream != nil { SCContext.saveFrame = true }}
        KeyboardShortcuts.onKeyDown(for: .screenMagnifier) { if SCContext.stream != nil { SCContext.isMagnifierEnabled.toggle() }}
        KeyboardShortcuts.onKeyDown(for: .stop) { if SCContext.stream != nil { SCContext.stopRecording() }}
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { if SCContext.stream != nil { SCContext.pauseRecording() }}
        KeyboardShortcuts.onKeyDown(for: .startWithAudio) {[self] in
            if SCContext.streamType != nil { return }
            closeAllWindow()
            prepRecord(type: "audio", screens: SCContext.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
        }
        KeyboardShortcuts.onKeyDown(for: .startWithScreen) {[self] in
            if SCContext.stream != nil { return }
            closeAllWindow()
            prepRecord(type: "display", screens: SCContext.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
        }
        KeyboardShortcuts.onKeyDown(for: .startWithArea) {[self] in
            if SCContext.stream != nil { return }
            closeAllWindow()
            showAreaSelector(size: NSSize(width: 600, height: 450))
        }
        KeyboardShortcuts.onKeyDown(for: .startWithWindow) { [self] in
            if SCContext.stream != nil { return }
            closeAllWindow()
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            if let pid = frontmostApp?.processIdentifier {
                guard let scWindow = SCContext.getWindows().first(where: { $0.owningApplication?.processID == pid && $0.title != "" && $0.isOnScreen }) else { return }
                prepRecord(type: "window", screens: SCContext.getSCDisplayWithMouse(), windows: [scWindow], applications: nil, fastStart: true)
                return
            }
        }
        updateStatusBar()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        closeAllWindow()
        if showOnDock { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) }
        SCContext.recoverPendingRemuxesIfNeeded()
        tips("Would you like to use H.265 format for better video quality and smaller file size?",
             id: "qr.switch-to-h265.note", buttonTitle: "Use H.265", switchButton: true) {
            ud.setValue(Encoder.h265.rawValue, forKey: "encoder")
        }
    }
    
    func presentMainPanel(belowSettings: Bool = false, activateApp: Bool = true) {
        guard SCContext.stream == nil && SCContext.streamType == nil else {
            StatusBarController.shared.revealRecordingBarOnCurrentScreen()
            return
        }
        PopoverState.shared.isShowing = false

        let targetScreen = SCContext.getScreenWithMouse() ?? NSScreen.main
        let hosting = NSHostingView(rootView: ContentView())
        let fit = hosting.fittingSize
        let panelWidth = max(880, fit.width)
        let panelHeight = max(96, fit.height)

        let panel: EscPanel
        if let existing = mainPanelWindow {
            panel = existing
            panel.contentView = hosting
            panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))
        } else {
            panel = EscPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hosting
            panel.title = "LongTake"
            panel.isOpaque = false
            panel.hasShadow = false
            // 关键根因修复: NSPanel 默认 hidesOnDeactivate = true! 未激活或双屏点击其他应用时会立刻自动隐藏(“点不开直接消失”)
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.isRestorable = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            mainPanelWindow = panel
        }

        if let screen = targetScreen {
            let visible = screen.visibleFrame
            let wX = visible.minX + (visible.width - panelWidth) / 2
            let wY = belowSettings
                ? max(visible.minY + 28, visible.midY - 310)
                : visible.minY + (visible.height - panelHeight) / 2
            // 若面板已在当前屏幕上且并非首次定位或设置页预览，则保留用户拖拽后的位置（安全钳制在可见区域内）
            if !belowSettings, panel.screen == screen, panel.frame.origin != .zero,
               visible.intersects(panel.frame) {
                let clampedX = min(max(panel.frame.origin.x, visible.minX + 8), visible.maxX - panelWidth - 8)
                let clampedY = min(max(panel.frame.origin.y, visible.minY + 8), visible.maxY - panelHeight - 8)
                panel.setFrame(NSRect(x: clampedX, y: clampedY, width: panelWidth, height: panelHeight), display: true)
            } else {
                panel.setFrame(NSRect(x: wX, y: wY, width: panelWidth, height: panelHeight), display: true)
            }
        }

        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(self)
    }

    func toggleMainPanel() {
        if SCContext.stream != nil || SCContext.streamType != nil {
            StatusBarController.shared.revealRecordingBarOnCurrentScreen()
            return
        }
        if let panel = mainPanelWindow, panel.isVisible {
            panel.orderOut(nil)
        } else {
            presentMainPanel(belowSettings: false, activateApp: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SCContext.stream != nil || SCContext.streamType != nil {
            StatusBarController.shared.revealRecordingBarOnCurrentScreen()
            return false
        }
        let selectorTitles: Set<String> = [
            "Screen Selector".local,
            "App Selector".local,
            "Window Selector".local,
            "Area Selector".local,
            "Start Recording".local
        ]
        if let selectorWin = NSApp.windows.first(where: { $0.isVisible && selectorTitles.contains($0.title) }) {
            NSApp.activate(ignoringOtherApps: true)
            selectorWin.makeKeyAndOrderFront(self)
            return false
        }
        presentMainPanel(belowSettings: false, activateApp: true)
        return false
    }
    
    func openSettingPanel() {
        NSApp.activate(ignoringOtherApps: true)
        if let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
            settingsItem.performAction()
        } else if #available(macOS 13, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
    
    class EscPanel: NSPanel {
        override func cancelOperation(_ sender: Any?) {
            self.orderOut(nil)
        }
        override var canBecomeKey: Bool {
            return true
        }
    }
}

func closeMainWindow() {
    PopoverState.shared.isShowing = false
    AppDelegate.shared.mainPanelWindow?.orderOut(nil)
    for w in NSApp.windows.filter({ $0.title == "LongTake" || $0.title == "QuickRecorder".local }) {
        w.orderOut(nil)
    }
}

func closeAllWindow(except: String = "") {
    AppDelegate.shared.mainPanelWindow?.orderOut(nil)
    for w in NSApp.windows.filter({
        $0.title != "Item-0" && $0.title != ""
        && $0.title != "Recording Controller".local
        && !$0.title.lowercased().contains(".qma")
        && !$0.title.contains(except) }) {
        if w === AppDelegate.shared.mainPanelWindow || w === controlPanel || w === previewWindow || w === savingHUDPanel {
            w.orderOut(nil)
        } else {
            w.close()
        }
    }
}

func findNSSplitVIew(view: NSView?) -> NSSplitView? {
    var queue = [NSView]()
    if let root = view { queue.append(root) }
    
    while !queue.isEmpty {
        let current = queue.removeFirst()
        if current is NSSplitView { return current as? NSSplitView }
        for subview in current.subviews { queue.append(subview) }
    }
    return nil
}

func getStatusBarWidth() -> CGFloat {
    @AppStorage("miniStatusBar") var miniStatusBar: Bool = false
    var width = 158.0
    switch SCContext.streamType {
    case nil: width = miniStatusBar ? 36.0 : 36.0
    case .idevice: width = miniStatusBar ? 68.0 : 138.0
    case .systemaudio: width = miniStatusBar ? 68.0 : 114.0
    default: width = miniStatusBar ? 78.0 : 158.0
    }
    return width
}

func process(path: String, arguments: [String]) -> String? {
    let task = Process()
    task.launchPath = path
    task.arguments = arguments
    task.standardError = Pipe()
    
    let outputPipe = Pipe()
    defer {
        outputPipe.fileHandleForReading.closeFile()
    }
    task.standardOutput = outputPipe
    
    do {
        try task.run()
    } catch let error {
        print("\(error.localizedDescription)")
        return nil
    }
    
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: outputData, as: UTF8.self)
    
    if output.isEmpty {
        return nil
    }
    
    return output.trimmingCharacters(in: .newlines)
}

func tips(_ message: String, title: String? = nil, id: String, buttonTitle: String = "OK", switchButton: Bool = false, width: Int? = nil, action: (() -> Void)? = nil) {
    let never = (ud.object(forKey: "neverRemindMe") as? [String]) ?? []
    if !never.contains(id) {
        if switchButton {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: buttonTitle, button2: "Don't remind me again", width: width).runModal()
            if alert == .alertSecondButtonReturn { ud.setValue(never + [id], forKey: "neverRemindMe") }
            if alert == .alertFirstButtonReturn { action?() }
        } else {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: "Don't remind me again", button2: buttonTitle, width: width).runModal()
            if alert == .alertFirstButtonReturn { ud.setValue(never + [id], forKey: "neverRemindMe") }
            if alert == .alertSecondButtonReturn { action?() }
        }
    }
}

func createAlert(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "", width: Int? = nil) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title.local
    alert.informativeText = message.local
    alert.addButton(withTitle: button1.local)
    if button2 != "" { alert.addButton(withTitle: button2.local) }
    alert.alertStyle = level
    if let width = width {
        alert.accessoryView = NSView(frame: NSMakeRect(0, 0, Double(width), 0))
    }
    return alert
}

func showAlertSyncOnMainThread(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "", width: Int? = nil) -> NSApplication.ModalResponse {
    var response: NSApplication.ModalResponse = .abort
    let semaphore = DispatchSemaphore(value: 0)
    
    DispatchQueue.main.async {
        let alert = createAlert(level: level, title: title, message: message, button1: button1, button2: button2, width: width)
        response = alert.runModal()
        semaphore.signal()
    }
    
    semaphore.wait()
    return response
}

extension Bundle {
    var appName: String {
        let appName = self.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                     ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                     ?? "Unknown App Name"
        return appName
    }
}

extension String {
    var local: String { return NSLocalizedString(self, comment: "") }
    var deletingPathExtension: String {
        return (self as NSString).deletingPathExtension
    }
    var pathExtension: String {
        return (self as NSString).pathExtension
    }
    var lastPathComponent: String {
        return (self as NSString).lastPathComponent
    }
    var url: URL { return URL(fileURLWithPath: self) }
}

extension NSMenuItem {
    func performAction() {
        guard let menu else {
            return
        }
        menu.performActionForItem(at: menu.index(of: self))
    }
}

extension NSImage {
    static func createScreenShot() -> NSImage? {
        var excludedAppBundleIDs = ["com.lihaoyun6.QuickRecorder"]
        if let bid = Bundle.main.bundleIdentifier { excludedAppBundleIDs.append(bid) }
        var exclusionPIDs = [Int]()
        for app in NSWorkspace.shared.runningApplications {
            if excludedAppBundleIDs.contains(app.bundleIdentifier ?? "") {
                exclusionPIDs.append(Int(app.processIdentifier))
            }
        }
        
        let windowDescriptions = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var windowIDs = [CGWindowID]()
        for windowDict in windowDescriptions {
            if let windowProcessID = windowDict[kCGWindowOwnerPID as String] as? Int,
               !exclusionPIDs.contains(windowProcessID),
               let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID {
                windowIDs.append(windowID)
            }
        }
        let pointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: windowIDs.count)
        for (index, window) in windowIDs.enumerated() { pointer[index] = UnsafeRawPointer(bitPattern: UInt(window)) }
        let cWindowIDArray: CFArray = CFArrayCreate(kCFAllocatorDefault, pointer, windowIDs.count, nil)

        guard let imageRef = CGImage(windowListFromArrayScreenBounds: CGRect.infinite, windowArray: cWindowIDArray, imageOption: []) else {
            print("No image available")
            return nil
        }
        let factor = SCContext.getScreenWithMouse()?.backingScaleFactor ?? 1.0
        return NSImage(cgImage: imageRef, size: NSSize(width: CGFloat(imageRef.width)/factor, height: CGFloat(imageRef.height)/factor))
    }
    
    func saveToFile(_ url: URL, type: NSBitmapImageRep.FileType = .png) {
        if let tiffData = self.tiffRepresentation,
           let imageRep = NSBitmapImageRep(data: tiffData) {
            let pngData = imageRep.representation(using: type, properties: [:])
            do {
                try pngData?.write(to: url)
            } catch {
                print("Error saving image: \(error.localizedDescription)")
            }
        }
    }
    
    func trim(rect: CGRect) -> NSImage {
        let result = NSImage(size: rect.size)
        result.lockFocus()

        let destRect = CGRect(origin: .zero, size: result.size)
        self.draw(in: destRect, from: rect, operation: .copy, fraction: 1.0)

        result.unlockFocus()
        return result
    }
}

class NNSWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
}

struct FixedLengthArray<T> {
    private var array: [T] = []
    private let maxLength: Int

    init(maxLength: Int) {
        self.maxLength = maxLength
    }

    mutating func append(_ element: T) {
        if array.count >= maxLength {
            array.removeFirst()
        }
        array.append(element)
    }

    func getArray() -> [T] {
        return array
    }
}

extension utsname {
    static var sMachine: String {
        var utsname = utsname()
        uname(&utsname)
        return withUnsafePointer(to: &utsname.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }
    static var isAppleSilicon: Bool {
        sMachine == "arm64"
    }
}

enum AudioQuality: Int { case normal = 128, good = 192, high = 256, extreme = 320 }

enum AudioFormat: String { case aac, alac, flac, opus, mp3 }

enum VideoFormat: String { case mov, mp4 }

enum PixFormat: String { case delault, yuv420p8v, yuv420p8f, yuv420p10v, yuv420p10f, bgra32 }

enum ColSpace: String { case delault, srgb, p3, bt709, bt2020 }

enum Encoder: String { case h264, h265 }

enum StreamType: Int { case screen, window, windows, application, screenarea, systemaudio, idevice, camera }

enum BackgroundType: String { case wallpaper, clear, black, white, red, green, yellow, orange, gray, blue, custom }
