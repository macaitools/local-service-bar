import AppKit
import Combine
import SwiftUI
import OSLog

@main
struct LocalServiceBarApp: App {
    @NSApplicationDelegateAdaptor(LocalServiceBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class LocalServiceBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = ServiceMonitor()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var countSubscription: AnyCancellable?
    private var recoverySubscriptions = Set<AnyCancellable>()
    private var recoveryTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.localservicebar.app", category: "StatusItem")

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 175)
        let content = ServicePopoverView(monitor: monitor)
            .frame(width: 390)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { [weak popover] size in
                guard let popover, size.width > 0, size.height > 0,
                      popover.contentSize != size else { return }
                popover.contentSize = size
            }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        controller.view.frame = NSRect(x: 0, y: 0, width: 390, height: 175)
        popover.contentViewController = controller

        countSubscription = monitor.$lastKnownRunningCount
            .removeDuplicates()
            .sink { [weak self] count in
                self?.statusItem?.button?.title = " \(count)"
            }

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        Publishers.Merge3(
            workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification),
            workspaceNotifications.publisher(for: NSWorkspace.screensDidWakeNotification),
            workspaceNotifications.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.restoreStatusItem(reason: "workspace resumed") }
        .store(in: &recoverySubscriptions)

        workspaceNotifications.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { ["com.apple.controlcenter", "com.apple.systemuiserver"].contains($0.bundleIdentifier ?? "") }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restoreStatusItem(reason: "menu bar service restarted") }
            .store(in: &recoverySubscriptions)

        restoreStatusItem(reason: "launch")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreStatusItem(reason: "reopen")
        return false
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        restoreStatusItem(reason: "screens changed")
    }

    private func restoreStatusItem(reason: String) {
        recoveryTask?.cancel()
        recreateStatusItem()
        logger.info("Restoring status item: \(reason, privacy: .public)")

        // A registered item may not have a usable window yet during login or wake.
        // Retry only a few times; do not keep scanning or rebuilding while idle.
        recoveryTask = Task { [weak self] in
            let delays: [UInt64] = [500_000_000, 2_000_000_000, 5_000_000_000, 5_000_000_000]
            for (attempt, delay) in delays.enumerated() {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if let item = self.statusItem, item.isVisible,
                   let button = item.button, let window = button.window, window.isVisible,
                   button.bounds.width > 0, button.bounds.height > 0 {
                    let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
                    if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                        self.logger.info("Status item has an on-screen window")
                        return
                    }
                }
                if attempt < delays.count - 1 {
                    self.logger.warning("Status item has no on-screen window; recreating")
                    self.recreateStatusItem()
                }
            }
            self?.logger.warning("Status item recovery retry limit reached")
        }
    }

    private func recreateStatusItem() {
        popover.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "LocalServiceBar"
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "本机服务")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = " \(monitor.lastKnownRunningCount)"
            button.toolTip = "本机服务"
            button.setAccessibilityLabel("本机服务")
            button.target = self
            button.action = #selector(togglePopover)
        }
        item.isVisible = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoveryTask?.cancel()
        recoverySubscriptions.removeAll()
        monitor.stopMonitoring()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        monitor.startMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.stopMonitoring()
    }
}
