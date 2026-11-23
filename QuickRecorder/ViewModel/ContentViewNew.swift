//
//  ContentView.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct ContentViewNew: View {
    @State private var window: NSWindow?
    @State private var xmarkGlowing = false
    @State private var infoGlowing = false
    @State private var micGlowing = false
    @State private var isPopoverShowing = false
    @State private var micList = SCContext.getMicrophone()
    @AppStorage("enableAEC") private var enableAEC: Bool = false
    @AppStorage("recordMic") private var recordMic: Bool = false
    @AppStorage("micDevice") private var micDevice: String = "default"
    @AppStorage("showOnDock") private var showOnDock: Bool = true
    @AppStorage("showMenubar") private var showMenubar: Bool = true

    var appDelegate = AppDelegate.shared
    
    var body: some View {
        ZStack {
            ZStack {
                if isTodayChristmas() && isAllowChristmas() {
                    let images = ["snowflake1", "snowflake2", "snowflake3", "christmasTree1", "christmasTree2"]
                    SurpriseView(snowflakes: images, width: 520, height: 200, velocity: 16, lifetime: 30, alphaSpeed: -0.05)
                } else if isChineseNewYear() && isAllowChineseNewYear() {
                    let images = ["fuzi1", "fuzi2", "fuzi3", "hongbao1", "hongbao2", "hongbao3", "bianpao1", "bianpao2", "bianpao3"]
                    SurpriseView(snowflakes: images, width: 520, height: 200, velocity: 16, lifetime: 30, alphaSpeed: -0.05)
                }
            }.opacity(0.5)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        recordMic.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: recordMic ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(recordMic ? MicGlassCapsule.vermilion : Color.primary.opacity(0.55))
                            Text("Microphone".local)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(recordMic ? 0.96 : 0.78))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onChange(of: recordMic) { _ in Task { await SCContext.performMicCheck() } }
                    .onAppear { if micList.isEmpty { recordMic = false } }
                    .disabled(micList.isEmpty)

                    Spacer()

                    Picker("", selection: $micDevice) {
                        Text("Default".local).tag("default")
                        ForEach(micList, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.localizedName)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 170, height: 22)
                    .onChange(of: micDevice) { newValue in
                        if newValue != "default" && !recordMic && !micList.isEmpty {
                            recordMic = true
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

                Divider().opacity(0.22).padding(.horizontal, 6)

                HStack(spacing: 4) {
                    Button(action: {
                        let startAudio: () -> Void = {
                            if let display = SCContext.getSCDisplayWithMouse() ?? SCContext.availableContent?.displays.first {
                                closeMainWindow()
                                appDelegate.createCountdownPanel(screen: display) {
                                    AppDelegate.shared.prepRecord(type: "audio", screens: display, windows: nil, applications: nil)
                                }
                            }
                        }
                        if SCContext.getSCDisplayWithMouse() != nil || SCContext.availableContent?.displays.first != nil {
                            startAudio()
                        } else {
                            SCContext.updateAvailableContent {
                                DispatchQueue.main.async { startAudio() }
                            }
                        }
                    }, label: {
                        SelectorView(title: "System Audio".local, symbol: "waveform", role: .primaryCapture, tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                    Button(action: {
                        closeMainWindow()
                        appDelegate.createNewWindow(view: ScreenSelector(), title: "Screen Selector".local)
                    }, label: {
                        SelectorView(title: "Screen".local, symbol: "display", tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                    Button(action: {
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
                    }, label: {
                        SelectorView(title: "Screen Area".local, symbol: "viewfinder", tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                    Button(action: {
                        closeMainWindow()
                        appDelegate.createNewWindow(view: AppSelector(), title: "App Selector".local)
                    }, label: {
                        SelectorView(title: "Application".local, symbol: "macwindow.on.rectangle", tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                }
                Divider().opacity(0.22).padding(.horizontal, 6)
                HStack(spacing: 4) {
                    Button(action: {
                        closeMainWindow()
                        appDelegate.createNewWindow(view: WinSelector(), title: "Window Selector".local)
                    }, label: {
                        SelectorView(title: "Window".local, symbol: "macwindow", tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                    Button(action: {
                        isPopoverShowing = true
                    }, label: {
                        SelectorView(title: "Mobile Device".local, symbol: "ipad.and.iphone", tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                        .popover(isPresented: $isPopoverShowing, arrowEdge: .bottom) {
                            iDevicePopoverView(closePopover: { isPopoverShowing = false })
                        }
                    Button(action: {
                        closeMainWindow()
                        appDelegate.openSettingPanel()
                    }, label: {
                        SelectorView(title: "Preferences".local, symbol: "slider.horizontal.3", tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                    Button(action: {
                        NSApp.terminate(self)
                    }, label: {
                        SelectorView(title: "Quit".local, symbol: "power", role: .destructive, tileWidth: 94, tileHeight: 56)
                    }).buttonStyle(SelectorTileButtonStyle())
                }
            }.padding(12)
            .onAppear { micList = SCContext.getMicrophone() }
        }
    }
}
