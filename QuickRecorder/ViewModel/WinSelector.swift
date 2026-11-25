//
//  WinSelector.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/17.
//

import SwiftUI
import Foundation
import AVFoundation
import ScreenCaptureKit

struct WinSelector: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject var viewModel = WindowSelectorViewModel()
    @State private var selected = [SCWindow]()
    @State private var display: SCDisplay!
    @State private var selectedTab = 0
    @State private var isPopoverShowing = false
    @State private var isPopoverShowing2 = false
    @State private var disableFilter = false
    @State private var donotCapture = false
    @State private var autoStop = 0
    var appDelegate = AppDelegate.shared
    
    var body: some View {
        ZStack {
            VStack(spacing: 15) {
                if #available(macOS 15, *) {
                    Text("Please select the window(s) to record").offset(y: 12)
                } else {
                    HStack {
                        Spacer()
                        Text("Please select the window(s) to record")
                        Spacer()
                        HoverButton(action: {
                            WindowHighlighter.shared.registerMouseMonitor(mode: 2)
                        }, label: {
                            ZStack {
                                Color.white.opacity(0.0001)
                                Image("window.select")
                                    .resizable().scaledToFit()
                            }.frame(width: 20, height: 20)
                        })
                        .help("Select Window Directly")
                        .padding(.leading, -20)
                    }.padding(.horizontal, 10)
                }
                TabView(selection: $selectedTab) {
                    let allApps = viewModel.windowThumbnails.sorted(by: { $0.key.displayID < $1.key.displayID })
                    ForEach(allApps, id: \.key) { element in
                        let (screen, thumbnails) = element
                        let index = allApps.firstIndex(where: { $0.key == screen }) ?? 0
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                ForEach(0..<thumbnails.count/4 + 1, id: \.self) { rowIndex in
                                    HStack(spacing: 16.5) {
                                        ForEach(0..<4, id: \.self) { columnIndex in
                                            let index = 4 * rowIndex + columnIndex
                                            if index <= thumbnails.count - 1 {
                                                let item = thumbnails[index]
                                                Button(action: {
                                                    if !selected.contains(item.window) {
                                                        selected.append(item.window)
                                                    } else {
                                                        selected.removeAll{ $0 == item.window }
                                                    }
                                                }, label: {
                                                    VStack(spacing: 1){
                                                        ZStack{
                                                            if colorScheme == .light {
                                                                Image(nsImage: item.image)
                                                                    .resizable()
                                                                    .aspectRatio(contentMode: .fit)
                                                                    .colorMultiply(.black)
                                                                    .blur(radius: 0.5)
                                                                    .opacity(1)
                                                                    .frame(width: 160, height: 90, alignment: .center)
                                                            } else {
                                                                Image(nsImage: item.image)
                                                                    .resizable()
                                                                    .aspectRatio(contentMode: .fit)
                                                                    .colorMultiply(.black)
                                                                    .colorInvert()
                                                                    .blur(radius: 0.5)
                                                                    .opacity(1)
                                                                    .frame(width: 160, height: 90, alignment: .center)
                                                            }
                                                            Image(nsImage: item.image)
                                                                .resizable()
                                                                .aspectRatio(contentMode: .fit)
                                                                .frame(width: 160, height: 90, alignment: .center)
                                                            Image(systemName: "circle.fill")
                                                                .font(.system(size: 31))
                                                                .foregroundStyle(.white)
                                                                .opacity(selected.contains(item.window) ? 1.0 : 0.0)
                                                                .offset(x: 55, y: 25)
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .font(.system(size: 27))
                                                                .foregroundStyle(.green)
                                                                .opacity(selected.contains(item.window) ? 1.0 : 0.0)
                                                                .offset(x: 55, y: 25)
                                                            Image(nsImage: SCContext.getAppIcon(item.window.owningApplication!)!)
                                                                .resizable()
                                                                .aspectRatio(contentMode: .fit)
                                                                .frame(width: 40, height: 40, alignment: .center)
                                                                .offset(y: 35)
                                                        }
                                                        .padding(5)
                                                        .padding(.vertical, 5)
                                                        .background(
                                                            Rectangle()
                                                                .foregroundStyle(.blue)
                                                                .cornerRadius(5)
                                                                .opacity(selected.contains(item.window) ? 0.2 : 0.0001)
                                                        )
                                                        Text(item.window.title!)
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                            .truncationMode(.tail)
                                                            .frame(width: 160)
                                                    }
                                                }).buttonStyle(.plain)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 12).padding(.top, 5)
                                }
                            }
                        }
                        .tag(index)
                        .tabItem { Text(screen.nsScreen?.localizedName ?? ("Display ".local + "\(index)")) }
                        .onAppear{ display = screen }
                    }
                }
                .frame(height: 445)
                .padding(.horizontal, 10)
                .onChange(of: selectedTab) { _ in selected.removeAll() }
                .onReceive(viewModel.$isReady) { isReady in
                    if isReady {
                        let allApps = viewModel.windowThumbnails.sorted(by: { $0.key.displayID < $1.key.displayID })
                        if let s = NSApp.windows.first(where: { $0.title == "Window Selector".local })?.screen,
                           let index = allApps.firstIndex(where: { $0.key.displayID == s.displayID }) {
                            selectedTab = index
                        }
                    }
                }
                HStack(spacing: 4) {
                    Button(action: {
                        self.viewModel.setupStreams(filter: !disableFilter, capture: !donotCapture)
                        self.selected.removeAll()
                    }, label: {
                        VStack{
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.blue)
                            Text("Refresh")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        
                    }).buttonStyle(.plain)
                    Button(action: {
                        isPopoverShowing2 = true
                    }, label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.blue)
                    })
                    .buttonStyle(.plain)
                    .padding(.top, 42.5)
                    .popover(isPresented: $isPopoverShowing2, arrowEdge: .bottom, content: {
                        VStack(alignment: .leading) {
                            Toggle(isOn: $disableFilter) { Text("Show Windows with No Title") }
                                .toggleStyle(.checkbox)
                                .onChange(of: disableFilter) { _ in
                                    self.viewModel.setupStreams(filter: !disableFilter, capture: !donotCapture)
                                    self.selected.removeAll()
                                }
                            Toggle(isOn: $donotCapture) { Text("Don't Create Thumbnails") }
                                .toggleStyle(.checkbox)
                                .onChange(of: donotCapture) { _ in
                                    self.viewModel.setupStreams(filter: !disableFilter, capture: !donotCapture)
                                    self.selected.removeAll()
                                }
                        }
                        .fixedSize()
                        .padding()
                    })
                    Spacer()
                    OptionsView()
                    Spacer()
                    Button(action: {
                        isPopoverShowing = true
                    }, label: {
                        Image(systemName: "timer")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.blue)
                    })
                    .buttonStyle(.plain)
                    .padding(.top, 42.5)
                    .popover(isPresented: $isPopoverShowing, arrowEdge: .bottom, content: {
                        HStack {
                            Text(" Stop after".local)
                            TextField("", value: $autoStop, formatter: NumberFormatter())
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Stepper("", value: $autoStop)
                                .padding(.leading, -10)
                            Text("minutes ".local)
                        }
                        .fixedSize()
                        .padding()
                    })
                    Button(action: {
                        startRecording()
                    }, label: {
                        VStack{
                            Image(systemName: "record.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.red)
                            Text("Start")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                    })
                    .buttonStyle(.plain)
                    .disabled(selected.count < 1)
                }.padding(.horizontal, 40)
                Spacer()
            }.padding(.top, -5)
        }
        .frame(width: 780, height:555)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HoverButton(action: {
                    WindowHighlighter.shared.registerMouseMonitor()
                }, label: {
                    Image("window.select")
                        .resizable().scaledToFit()
                        .frame(width: 20)
                }).help("Select Window Directly")
            }
        }
    }
    
    func startRecording() {
        guard let targetDisplay = display ?? SCContext.getSCDisplayWithMouse() ?? SCContext.availableContent?.displays.first,
              !selected.isEmpty else { return }
        closeAllWindow()
        appDelegate.createCountdownPanel(screen: targetDisplay) {
            SCContext.autoStop = autoStop
            appDelegate.prepRecord(type: (selected.count < 2 ? "window" : "windows"), screens: targetDisplay, windows: selected, applications: nil)
        }
    }
}

class WindowSelectorViewModel: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    @Published var windowThumbnails = [SCDisplay: [WindowThumbnail]]()
    @Published var isReady = false
    private var generation: UInt64 = 0
    private var streamTargets = [ObjectIdentifier: (stream: SCStream, window: SCWindow, gen: UInt64)]()
    private var expectedCount = 0
    private var receivedCount = 0

    override init() {
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.setupStreams()
        }
    }

    deinit {
        stopAllStreams()
    }

    private func stopAllStreams() {
        let active = streamTargets.values.map { $0.stream }
        streamTargets.removeAll()
        for s in active {
            s.stopCapture { _ in }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let key = ObjectIdentifier(stream)
        guard let entry = streamTargets.removeValue(forKey: key) else {
            stream.stopCapture { _ in }
            return
        }
        stream.stopCapture { _ in }
        guard entry.gen == generation else { return }

        let nsImage = sampleBuffer.nsImage ?? NSImage.unknowScreen
        let currentWindow = entry.window
        let thumbnail = WindowThumbnail(image: nsImage, window: currentWindow)
        if let displays = SCContext.availableContent?.displays.filter({ NSIntersectsRect(currentWindow.frame, $0.frame) }) {
            for d in displays {
                if self.windowThumbnails[d] != nil {
                    if !self.windowThumbnails[d]!.contains(where: { $0.window.windowID == currentWindow.windowID }) {
                        self.windowThumbnails[d]!.append(thumbnail)
                    }
                } else {
                    self.windowThumbnails[d] = [thumbnail]
                }
            }
        }
        receivedCount += 1
        if receivedCount >= expectedCount {
            self.isReady = true
        }
    }

    func setupStreams(filter: Bool = true, capture: Bool = true) {
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                self.generation &+= 1
                let currentGen = self.generation
                self.stopAllStreams()
                self.windowThumbnails.removeAll()
                self.isReady = false
                self.receivedCount = 0

                var windows = SCContext.getWindows().filter {
                    !($0.title == "" && $0.owningApplication?.bundleIdentifier == "com.apple.finder")
                    && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                    && $0.owningApplication?.applicationName != ""
                }
                if filter { windows = windows.filter { $0.title != "" } }
                self.expectedCount = windows.count

                if !capture {
                    for w in windows {
                        let thumbnail = WindowThumbnail(image: NSImage.unknowScreen, window: w)
                        guard let displays = SCContext.availableContent?.displays.filter({ NSIntersectsRect(w.frame, $0.frame) }) else { break }
                        for d in displays {
                            if self.windowThumbnails[d] != nil {
                                if !self.windowThumbnails[d]!.contains(where: { $0.window.windowID == w.windowID }) {
                                    self.windowThumbnails[d]!.append(thumbnail)
                                }
                            } else {
                                self.windowThumbnails[d] = [thumbnail]
                            }
                        }
                    }
                    self.isReady = true
                    return
                }

                if windows.isEmpty {
                    self.isReady = true
                    return
                }

                Task { @MainActor in
                    for w in windows {
                        guard self.generation == currentGen else { break }
                        let contentFilter = SCContentFilter(desktopIndependentWindow: w)
                        let streamConfiguration = SCStreamConfiguration()
                        let width = w.frame.width
                        let height = w.frame.height
                        let factor = (width < 200 && height < 200) ? 1.0 : 0.5
                        streamConfiguration.width = max(2, Int(width * factor))
                        streamConfiguration.height = max(2, Int(height * factor))
                        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
                        if #available(macOS 13, *) { streamConfiguration.capturesAudio = false }
                        streamConfiguration.showsCursor = false
                        streamConfiguration.scalesToFit = true
                        streamConfiguration.queueDepth = 3

                        let stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)
                        // 在 startCapture 前登记 stream -> target，防止首帧早到找不到目标或切过滤越界（P1-9）
                        let key = ObjectIdentifier(stream)
                        self.streamTargets[key] = (stream, w, currentGen)
                        do {
                            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                            try await stream.startCapture()
                        } catch {
                            self.streamTargets.removeValue(forKey: key)
                            self.receivedCount += 1
                            if self.receivedCount >= self.expectedCount && self.generation == currentGen {
                                self.isReady = true
                            }
                            print("Get windowshot error：\(error)")
                        }
                    }
                }
            }
        }
    }
}

class WindowThumbnail {
    let image: NSImage
    let window: SCWindow

    init(image: NSImage, window: SCWindow) {
        self.image = image
        self.window = window
    }
}
