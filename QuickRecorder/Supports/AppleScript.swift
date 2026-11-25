//
//  AppleScript.swift
//  LongTake
//
//  Created by apple on 2024/9/23.
//

import Foundation
import AppKit
import ScreenCaptureKit

private extension NSScriptCommand {
    func failScript(code: Int, message: String) {
        self.scriptErrorNumber = code
        self.scriptErrorString = message
        DispatchQueue.main.async {
            _ = createAlert(title: "Error".local, message: message, button1: "OK".local).runModal()
        }
    }
}

class selectScreen: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingActive || AVOutputClass.shared.isRecordingDevice {
            failScript(code: -1, message: "Already recording!".local)
            return nil
        }
        let requestedIndex = self.evaluatedArguments?["index"] as? Int
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                guard !SCContext.isRecordingActive && !AVOutputClass.shared.isRecordingDevice else { return }
                closeAllWindow()
                if var index = requestedIndex {
                    guard let screens = SCContext.availableContent?.displays else { return }
                    index -= 1
                    if index >= screens.count || index < 0 {
                        self.failScript(code: -2, message: "Invalid screen number!".local)
                        return
                    }
                    let screen = screens[index]
                    AppDelegate.shared.createCountdownPanel(screen: screen) {
                        AppDelegate.shared.prepRecord(type: "display", screens: screen, windows: nil, applications: nil)
                    }
                } else {
                    AppDelegate.shared.createNewWindow(view: ScreenSelector(), title: "Screen Selector".local)
                }
            }
        }
        return nil
    }
}

class selectArea: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingActive || AVOutputClass.shared.isRecordingDevice {
            failScript(code: -1, message: "Already recording!".local)
            return nil
        }
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                guard !SCContext.isRecordingActive && !AVOutputClass.shared.isRecordingDevice else { return }
                AppDelegate.shared.stopGlobalMouseMonitor()
                AppDelegate.shared.activeAreaSessionID = UUID()
                closeAllWindow()
                AppDelegate.shared.showAreaSelector(size: NSSize(width: 600, height: 450))
                var currentDisplayID = SCContext.getSCDisplayWithMouse()?.displayID
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .rightMouseDown, .leftMouseDown, .otherMouseDown]) { _ in
                    let displayID = SCContext.getSCDisplayWithMouse()?.displayID
                    if displayID != nil && displayID != currentDisplayID {
                        currentDisplayID = displayID
                        AppDelegate.shared.activeAreaSessionID = UUID()
                        closeAllWindow()
                        AppDelegate.shared.showAreaSelector(size: NSSize(width: 600, height: 450))
                    }
                }
            }
        }
        return nil
    }
}

class selectApps: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingActive || AVOutputClass.shared.isRecordingDevice {
            failScript(code: -1, message: "Already recording!".local)
            return nil
        }
        let targetAppName = self.evaluatedArguments?["name"] as? String
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                guard !SCContext.isRecordingActive && !AVOutputClass.shared.isRecordingDevice else { return }
                closeAllWindow()
                if let name = targetAppName {
                    guard let app = SCContext.availableContent?.applications.first(where: { $0.applicationName == name }) else {
                        self.failScript(code: -3, message: "No such application!".local)
                        return
                    }
                    guard let screens = SCContext.availableContent?.displays else { return }
                    // 修复 P1-13：严格按目标应用的 processID 过滤窗口，不再把其他应用的窗口算进去
                    let windows = (SCContext.availableContent?.windows ?? []).filter {
                        guard let title = $0.title else { return false }
                        return $0.owningApplication?.processID == app.processID
                        && !title.contains("Item-0")
                        && title != "Window"
                        && $0.frame.width > 40
                        && $0.frame.height > 40
                    }
                    var matchedScreens = [SCDisplay]()
                    for screen in screens {
                        for w in windows {
                            if NSIntersectsRect(screen.frame, w.frame) && !matchedScreens.contains(where: { $0.displayID == screen.displayID }) {
                                matchedScreens.append(screen)
                            }
                        }
                    }
                    if matchedScreens.isEmpty {
                        self.failScript(code: -4, message: "This application has no windows!".local)
                        return
                    }
                    if matchedScreens.count != 1 {
                        AppDelegate.shared.createNewWindow(view: AppSelector(), title: "App Selector".local)
                        self.failScript(code: -5, message: "This app exists in multiple screens, please select it manually!".local)
                    } else {
                        let chosen = matchedScreens[0]
                        AppDelegate.shared.createCountdownPanel(screen: chosen) {
                            AppDelegate.shared.prepRecord(type: "application", screens: chosen, windows: nil, applications: [app])
                        }
                    }
                } else {
                    AppDelegate.shared.createNewWindow(view: AppSelector(), title: "App Selector".local)
                }
            }
        }
        return nil
    }
}

class selectWindows: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingActive || AVOutputClass.shared.isRecordingDevice {
            failScript(code: -1, message: "Already recording!".local)
            return nil
        }
        let targetTitle = self.evaluatedArguments?["title"] as? String
        let targetApp = self.evaluatedArguments?["app"] as? String
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                guard !SCContext.isRecordingActive && !AVOutputClass.shared.isRecordingDevice else { return }
                closeAllWindow()
                if let title = targetTitle {
                    var windows = (SCContext.availableContent?.windows ?? []).filter { $0.title == title }
                    if let app = targetApp {
                        windows = windows.filter { $0.owningApplication?.applicationName == app }
                    }
                    if windows.isEmpty {
                        self.failScript(code: -6, message: "No such window!".local)
                        return
                    }
                    if windows.count > 1 {
                        AppDelegate.shared.createNewWindow(view: WinSelector(), title: "Window Selector".local)
                        self.failScript(code: -7, message: "Duplicate window exists, please select it manually!".local)
                        return
                    }
                    let window = windows[0]
                    guard let screens = SCContext.availableContent?.displays else { return }
                    let matchedScreens = screens.filter { NSIntersectsRect($0.frame, window.frame) }
                    guard !matchedScreens.isEmpty else {
                        self.failScript(code: -8, message: "Unable to find the screen this window belongs to!".local)
                        return
                    }
                    let chosenDisplay: SCDisplay
                    if let mouseDisplay = SCContext.getSCDisplayWithMouse(),
                       matchedScreens.contains(where: { $0.displayID == mouseDisplay.displayID }) {
                        chosenDisplay = mouseDisplay
                    } else {
                        chosenDisplay = matchedScreens[0]
                    }
                    AppDelegate.shared.createCountdownPanel(screen: chosenDisplay) {
                        AppDelegate.shared.prepRecord(type: "window", screens: chosenDisplay, windows: [window], applications: nil)
                    }
                } else {
                    AppDelegate.shared.createNewWindow(view: WinSelector(), title: "Window Selector".local)
                }
            }
        }
        return nil
    }
}

class recordAudio: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingActive || AVOutputClass.shared.isRecordingDevice {
            failScript(code: -1, message: "Already recording!".local)
            return nil
        }
        let micArg = self.evaluatedArguments?["mic"] as? Bool
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                guard !SCContext.isRecordingActive && !AVOutputClass.shared.isRecordingDevice else { return }
                if let mic = micArg {
                    UserDefaults.standard.set(mic, forKey: "recordMic")
                }
                closeAllWindow()
                let display = SCContext.getSCDisplayWithMouse() ?? SCContext.availableContent?.displays.first
                AppDelegate.shared.prepRecord(type: "audio", screens: display, windows: nil, applications: nil)
            }
        }
        return nil
    }
}

class stopRecordingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        DispatchQueue.main.async {
            if AVOutputClass.shared.isRecordingDevice || SCContext.streamType == .idevice {
                AVOutputClass.shared.stopRecording()
            } else {
                SCContext.stopRecording()
            }
        }
        return nil
    }
}

class setPreferences: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingActive || AVOutputClass.shared.isRecordingDevice {
            failScript(code: -1, message: "Already recording!".local)
            return nil
        }
        let args = self.evaluatedArguments ?? [:]
        if let hires = args["hires"] as? Bool { UserDefaults.standard.set(hires ? 2 : 1, forKey: "highRes") }
        if let fps = args["fps"] as? Int { UserDefaults.standard.set(fps, forKey: "frameRate") }
        if let cursor = args["cursor"] as? Bool { UserDefaults.standard.set(cursor, forKey: "showMouse") }
        if let sound = args["sound"] as? Bool { UserDefaults.standard.set(sound, forKey: "recordWinSound") }
        if let microphone = args["microphone"] as? Bool { UserDefaults.standard.set(microphone, forKey: "recordMic") }
        if let quality = args["quality"] as? Int, [1, 2, 3].contains(quality) {
            switch quality {
            case 1: UserDefaults.standard.set(0.3, forKey: "videoQuality")
            case 2: UserDefaults.standard.set(0.7, forKey: "videoQuality")
            default: UserDefaults.standard.set(1.0, forKey: "videoQuality")
            }
        }
        if let micname = args["micname"] as? String {
            if micname == "default" {
                UserDefaults.standard.set("default", forKey: "micDevice")
            } else if let dev = SCContext.getMicrophone().first(where: { $0.uniqueID == micname || $0.localizedName == micname }) {
                UserDefaults.standard.set(dev.uniqueID, forKey: "micDevice")
            }
        }
        if let hdr = args["hdr"] as? Bool {
            if #available(macOS 15.0, *) {
                UserDefaults.standard.set(hdr, forKey: "recordHDR")
            }
        }
        return nil
    }
}
