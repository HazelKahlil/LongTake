//
//  WindowAccessor.swift
//  LongTake
//
//  使用 scoped NSWindow Notification 替代覆写 window.delegate，保留 SwiftUI Settings / DocumentGroup 原生代理（P2-3）
//

import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    var onWindowOpen: ((NSWindow?) -> Void)?
    var onWindowActive: ((NSWindow?) -> Void)?
    var onWindowDeactivate: ((NSWindow?) -> Void)?
    var onWindowClose: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            if let window = view.window {
                coordinator.attach(to: window)
                coordinator.onWindowOpen?(window)
            } else {
                coordinator.onWindowOpen?(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onWindowOpen: onWindowOpen,
            onWindowActive: onWindowActive,
            onWindowDeactivate: onWindowDeactivate,
            onWindowClose: onWindowClose
        )
    }

    final class Coordinator: NSObject {
        weak var window: NSWindow?
        var onWindowOpen: ((NSWindow?) -> Void)?
        var onWindowActive: ((NSWindow?) -> Void)?
        var onWindowDeactivate: ((NSWindow?) -> Void)?
        var onWindowClose: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        init(
            onWindowOpen: ((NSWindow?) -> Void)? = nil,
            onWindowActive: ((NSWindow?) -> Void)? = nil,
            onWindowDeactivate: ((NSWindow?) -> Void)? = nil,
            onWindowClose: (() -> Void)? = nil
        ) {
            self.onWindowOpen = onWindowOpen
            self.onWindowActive = onWindowActive
            self.onWindowDeactivate = onWindowDeactivate
            self.onWindowClose = onWindowClose
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            removeObservers()
            self.window = window
            let nc = NotificationCenter.default
            observers.append(
                nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    self?.onWindowClose?()
                }
            )
            observers.append(
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.onWindowActive?(self?.window)
                }
            )
            observers.append(
                nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.onWindowDeactivate?(self?.window)
                }
            )
        }

        private func removeObservers() {
            let nc = NotificationCenter.default
            for obs in observers {
                nc.removeObserver(obs)
            }
            observers.removeAll()
        }

        deinit {
            removeObservers()
        }
    }
}
