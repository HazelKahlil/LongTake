//
//  ContentView.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct ContentView: View {
    var fromStatusBar = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var xmarkGlowing = false
    @State private var gripHovering = false
    @State private var isPopoverShowing = false
    @State private var micList = SCContext.getMicrophone()
    @AppStorage("enableAEC") private var enableAEC: Bool = false
    @AppStorage("recordMic") private var recordMic: Bool = false
    @AppStorage("micDevice") private var micDevice: String = "default"
    @AppStorage("showOnDock") private var showOnDock: Bool = true
    @AppStorage("showMenubar") private var showMenubar: Bool = true
    @AppStorage("panelOpacity") private var panelOpacity: Double = 0.86

    var appDelegate = AppDelegate.shared

    private var barBackingColor: Color {
        colorScheme == .dark
            ? Color(red: 0.135, green: 0.138, blue: 0.148)
            : Color(red: 0.968, green: 0.964, blue: 0.953)
    }

    var body: some View {
        let barShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    unifiedRowContent
                        .background {
                            barShape
                                .inset(by: 0.5)
                                .fill(barBackingColor.opacity(panelOpacity))
                        }
                        .overlay {
                            barShape
                                .strokeBorder(
                                    Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.11),
                                    lineWidth: 0.75
                                )
                                .allowsHitTesting(false)
                        }
                        .glassEffect(.regular, in: barShape)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.16), radius: 14, x: 0, y: 6)
                        .padding(fromStatusBar ? 6 : 12)
                }
            } else {
                unifiedRowContent
                    .background {
                        barShape.fill(.thickMaterial)
                        barShape.fill(barBackingColor.opacity(panelOpacity))
                    }
                    .overlay {
                        barShape
                            .strokeBorder(
                                Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.11),
                                lineWidth: 0.75
                            )
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.16), radius: 14, x: 0, y: 6)
                    .padding(fromStatusBar ? 6 : 12)
            }
        }
        .focusable(false)
        .onAppear {
            micList = SCContext.getMicrophone()
        }
    }

    /// 单行连贯主控制栏：[拖拽手柄] + [最前独立麦克风/输入源模块] + [6 项采集模式] + [偏好设置 / 退出 / 关闭]
    private var unifiedRowContent: some View {
        HStack(alignment: .center, spacing: 4) {
            if !fromStatusBar {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(gripHovering ? 0.08 : 0.0001))
                    VStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: 4) {
                                Circle().frame(width: 3.2, height: 3.2)
                                Circle().frame(width: 3.2, height: 3.2)
                            }
                        }
                    }
                    .foregroundStyle(Color.primary.opacity(gripHovering ? 0.62 : 0.32))
                    WindowDragHandle(isHovering: $gripHovering)
                }
                .frame(width: 22, height: 56)
                .help("Drag to move panel".local)
            }

            // 最前端独立音频输入模块（开关 + 系统默认/麦克风选择）
            MicGlassCapsule(
                recordMic: $recordMic,
                micDevice: $micDevice,
                enableAEC: enableAEC,
                micList: $micList
            )

            Divider()
                .frame(height: 36)
                .opacity(0.24)
                .padding(.horizontal, 3)

            // 6 项采集动作等高排布，零底部留白
            HStack(spacing: 2) {
                if #available(macOS 13, *) {
                    Button(action: startSystemAudio) {
                        SelectorView(title: "System Audio".local, symbol: "waveform", role: .primaryCapture, tileWidth: 88, tileHeight: 58)
                    }
                    .buttonStyle(SelectorTileButtonStyle())
                }
                Button(action: openScreenSelector) {
                    SelectorView(title: "Screen".local, symbol: "display", tileWidth: 88, tileHeight: 58)
                }
                .buttonStyle(SelectorTileButtonStyle())
                Button(action: openAreaSelector) {
                    SelectorView(title: "Screen Area".local, symbol: "viewfinder", tileWidth: 88, tileHeight: 58)
                }
                .buttonStyle(SelectorTileButtonStyle())
                Button(action: openAppSelector) {
                    SelectorView(title: "Application".local, symbol: "macwindow.on.rectangle", tileWidth: 88, tileHeight: 58)
                }
                .buttonStyle(SelectorTileButtonStyle())
                Button(action: openWinSelector) {
                    SelectorView(title: "Window".local, symbol: "macwindow", tileWidth: 88, tileHeight: 58)
                }
                .buttonStyle(SelectorTileButtonStyle())
                Button(action: { isPopoverShowing = true }) {
                    SelectorView(title: "Mobile Device".local, symbol: "ipad.and.iphone", tileWidth: 88, tileHeight: 58)
                }
                .buttonStyle(SelectorTileButtonStyle())
                .popover(isPresented: $isPopoverShowing, arrowEdge: .bottom) {
                    iDevicePopoverView(closePopover: { isPopoverShowing = false })
                }
            }

            Divider()
                .frame(height: 36)
                .opacity(0.24)
                .padding(.horizontal, 3)

            // 右侧连贯接入偏好设置与窗口控制
            HStack(spacing: 2) {
                Button(action: {
                    closeMainWindow()
                    appDelegate.openSettingPanel()
                }, label: {
                    SelectorView(title: "Preferences".local, symbol: "slider.horizontal.3", tileWidth: 80, tileHeight: 58)
                })
                .buttonStyle(SelectorTileButtonStyle())

                if fromStatusBar || (!showOnDock && !showMenubar) {
                    Button(action: {
                        NSApp.terminate(self)
                    }, label: {
                        SelectorView(title: "Quit".local, symbol: "power", role: .destructive, tileWidth: 72, tileHeight: 58)
                    })
                    .buttonStyle(SelectorTileButtonStyle())
                }
            }

            if !fromStatusBar {
                Button(action: {
                    closeMainWindow()
                }, label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(xmarkGlowing ? 0.92 : 0.48))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(xmarkGlowing ? 0.10 : 0.0001))
                        )
                        .contentShape(Circle())
                })
                .buttonStyle(SelectorTileButtonStyle())
                .onHover { xmarkGlowing = $0 }
                .padding(.leading, 2)
                .help("Close".local)
            }
        }
        .padding(.leading, fromStatusBar ? 10 : 8)
        .padding(.trailing, 10)
        .frame(height: 72)
    }

    private func startSystemAudio() {
        let begin: () -> Void = {
            if let display = SCContext.getSCDisplayWithMouse() ?? SCContext.availableContent?.displays.first {
                closeMainWindow()
                appDelegate.createCountdownPanel(screen: display) {
                    AppDelegate.shared.prepRecord(type: "audio", screens: display, windows: nil, applications: nil)
                }
            }
        }
        if SCContext.getSCDisplayWithMouse() != nil || SCContext.availableContent?.displays.first != nil {
            begin()
        } else {
            SCContext.updateAvailableContent {
                DispatchQueue.main.async { begin() }
            }
        }
    }

    private func openScreenSelector() {
        closeMainWindow()
        appDelegate.createNewWindow(view: ScreenSelector(), title: "Screen Selector".local)
    }

    private func openAreaSelector() {
        closeMainWindow()
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                appDelegate.showAreaSelector(size: NSSize(width: 600, height: 450))
                var currentDisplay = SCContext.getSCDisplayWithMouse()
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .rightMouseDown, .leftMouseDown, .otherMouseDown]) { event in
                    let display = SCContext.getSCDisplayWithMouse()
                    if display != currentDisplay {
                        currentDisplay = display
                        closeAllWindow()
                        appDelegate.showAreaSelector(size: NSSize(width: 600, height: 450))
                    }
                }
            }
        }
    }

    private func openAppSelector() {
        closeMainWindow()
        appDelegate.createNewWindow(view: AppSelector(), title: "App Selector".local)
    }

    private func openWinSelector() {
        closeMainWindow()
        appDelegate.createNewWindow(view: WinSelector(), title: "Window Selector".local)
    }
}

/// 原生 AppKit 即时拖拽手柄：在 `.nonactivatingPanel` 下无需先点激活窗口，首次按下即可丝滑拖动整条面板
struct WindowDragHandle: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> DragGripNSView {
        let view = DragGripNSView()
        view.onHoverChange = { hovering in
            DispatchQueue.main.async {
                isHovering = hovering
            }
        }
        return view
    }

    func updateNSView(_ nsView: DragGripNSView, context: Context) {}

    final class DragGripNSView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingAreaRef {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.openHand.set()
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
            NSCursor.openHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

enum SelectorRole {
    case primaryCapture
    case standard
    case destructive
}

struct SelectorTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((configuration.isPressed && !reduceMotion) ? 0.96 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct MicGlassCapsule: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var recordMic: Bool
    @Binding var micDevice: String
    var enableAEC: Bool
    @Binding var micList: [AVCaptureDevice]
    @State private var hoveringToggle = false

    static let vermilion = Color(red: 0.82, green: 0.25, blue: 0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button {
                    recordMic.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: recordMic ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(recordMic ? Self.vermilion : Color.primary.opacity(0.55))
                        Text("Microphone".local)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(recordMic ? 0.96 : 0.78))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(hoveringToggle ? 0.07 : 0.0001))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringToggle = $0 }
                .onChange(of: recordMic) { _ in Task { await SCContext.performMicCheck() } }
                .onAppear { if micList.isEmpty { recordMic = false } }
                .disabled(micList.isEmpty)

                Spacer(minLength: 0)

                if micDevice != "default" && enableAEC && recordMic {
                    Button {
                        let alert = createAlert(
                            title: "Compatibility Warning".local,
                            message: "The \"Acoustic Echo Cancellation\" is enabled, but it won't work on now.\n\nIf you need to use a specific input with AEC, set it to \"Default\" and select the device you want in System Preferences.\n\nOr you can start recording without AEC.".local,
                            button1: "OK".local, button2: "System Preferences".local)
                        if alert.runModal() == .alertSecondButtonReturn {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!)
                        }
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("", selection: $micDevice) {
                Text("Default".local).tag("default")
                ForEach(micList, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.localizedName)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 124, height: 22)
            .opacity(recordMic ? 1.0 : 0.85)
            .onChange(of: micDevice) { newValue in
                if newValue != "default" && !recordMic && !micList.isEmpty {
                    recordMic = true
                }
            }
            .onAppear {
                let list = micList.map({ $0.localizedName })
                if !list.contains(micDevice) { micDevice = "default" }
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 146, height: 58)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07), lineWidth: 0.6)
                )
        )
    }
}

struct SelectorView: View {
    var title = "No Title".local
    var symbol = "app"
    var symbolSize: CGFloat = 20
    var overlayer = ""
    var role: SelectorRole = .standard
    var tileWidth: CGFloat = 88
    var tileHeight: CGFloat = 58
    @State private var hovering = false

    private var iconColor: Color {
        switch role {
        case .primaryCapture:
            return Color(red: 0.82, green: 0.25, blue: 0.18)
        case .standard:
            return Color.primary.opacity(hovering ? 1.0 : 0.88)
        case .destructive:
            return hovering ? Color(red: 0.84, green: 0.23, blue: 0.19) : Color.primary.opacity(0.80)
        }
    }

    private var titleColor: Color {
        switch role {
        case .destructive where hovering:
            return Color(red: 0.84, green: 0.23, blue: 0.19)
        default:
            return Color.primary.opacity(hovering ? 1.0 : 0.90)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
                if !overlayer.isEmpty {
                    Text(overlayer)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(iconColor.opacity(0.90))
                        .offset(y: 12)
                }
            }
            .frame(width: 32, height: 24)

            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 3)
        }
        .frame(width: tileWidth, height: tileHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.085 : 0.0001))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            self.hovering = hovering
        }
    }
}

struct CountdownView: View {
    @State var countdownValue: Int = 00
    @State private var timer: Timer?
    var atEnd: () -> Void

    var body: some View {
        ZStack {
            Color.mypurple.environment(\.colorScheme, .dark)
            Text("\(countdownValue)")
                .font(.system(size: 72))
                .foregroundColor(.white)
                .offset(y: -10)
            Button(action: {
                timer?.invalidate()
                for w in NSApp.windows.filter({
                    $0.title == "Countdown Panel".local ||
                    $0.title == "Area Overlayer".local
                }) { w.close() }
            }, label: {
                ZStack {
                    Color.white.opacity(0.2)
                    Text("Cancel").foregroundColor(.white)
                }.frame(width: 120, height: 24)
            })
            .buttonStyle(.plain)
            .padding(.top, 96)
        }
        .frame(width: 120, height: 120)
        .cornerRadius(10)
        .onAppear{
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                if countdownValue > 1 {
                    countdownValue -= 1
                } else {
                    timer.invalidate()
                    if let w = NSApp.windows.first(where: { $0.title == "Countdown Panel".local }) { w.close() }
                    atEnd()
                }
            }
        }
    }
}


extension AppDelegate {
    func showAreaSelector(size: NSSize, noPanel: Bool = false) {
        guard let scDisplay = SCContext.getSCDisplayWithMouse() else { return }
        guard let screen = scDisplay.nsScreen else { return }
        let screenshotWindow = ScreenshotWindow(contentRect: screen.frame, backing: .buffered, defer: false, size: size, force: noPanel)
        screenshotWindow.title = "Area Selector".local
        //screenshotWindow.orderFront(self)
        screenshotWindow.orderFrontRegardless()
        if !noPanel {
            let wX = (screen.frame.width - 790) / 2 + screen.frame.minX
            let wY = screen.visibleFrame.minY + 80
            let contentView = NSHostingView(rootView: AreaSelector(screen: scDisplay))
            contentView.frame = NSRect(x: wX, y: wY, width: 790, height: 90)
            contentView.focusRingType = .none
            let areaPanel = NSPanel(contentRect: contentView.frame, styleMask: [.fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            areaPanel.collectionBehavior = [.canJoinAllSpaces]
            areaPanel.setFrame(contentView.frame, display: true)
            areaPanel.level = .screenSaver
            areaPanel.title = "Start Recording".local
            areaPanel.contentView = contentView
            areaPanel.backgroundColor = .clear
            areaPanel.titleVisibility = .hidden
            areaPanel.isReleasedWhenClosed = false
            areaPanel.titlebarAppearsTransparent = true
            areaPanel.isMovableByWindowBackground = true
            //areaPanel.setFrameOrigin(NSPoint(x: wX, y: wY))
            areaPanel.orderFront(self)
        }
    }
    
    func createCountdownPanel(screen: SCDisplay, action: @escaping () -> Void) {
        guard let screen = screen.nsScreen else { return }
        let countdown = ud.integer(forKey: "countdown")
        if countdown == 0 {
            action()
        } else {
            let wX = (screen.frame.width - 120) / 2 + screen.frame.minX
            let wY = (screen.frame.height - 120) / 2 + screen.frame.minY
            let frame =  NSRect(x: wX, y: wY, width: 120, height: 120)
            let contentView = NSHostingView(rootView: CountdownView(countdownValue: countdown, atEnd: action))
            contentView.frame = frame
            countdownPanel.contentView = contentView
            countdownPanel.setFrame(frame, display: true)
            countdownPanel.makeKeyAndOrderFront(self)
        }
    }
    
    func createNewWindow(view: some View, title: String, random: Bool = false, only: Bool = true) {
        guard let screen = SCContext.getScreenWithMouse() else { return }
        if only { closeAllWindow() }
        var seed = 0.0
        if random { seed = CGFloat(Int(arc4random_uniform(401)) - 200) }
        let wX = (screen.frame.width - 780) / 2 + seed + screen.frame.minX
        let wY = (screen.frame.height - 555) / 2 + 100 + seed + screen.frame.minY
        let contentView = NSHostingView(rootView: view)
        contentView.frame = NSRect(x: wX, y: wY, width: 780, height: 555)
        let window = NSWindow(contentRect: contentView.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = contentView
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(self)
        window.orderFrontRegardless()
    }
}

extension View {
    func needScale() -> some View {
        if #available(macOS 14, *) {
            return self.scaleEffect(0.8).padding(.leading, -4)
        } else {
            return self
        }
    }
}


/*#Preview {
    ContentView()
}
*/
