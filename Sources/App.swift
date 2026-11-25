import AppKit
import SwiftUI
import AVFoundation

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let prefs = Preferences()
    var item: NSStatusItem!
    private var lastTranscript: String?
    var popover: NSPopover!
    private var settingsController: NSHostingController<SettingsView>!
    private var popoverClosedAt = Date.distantPast
    private var appBeforeSettings: NSRunningApplication?
    let levels = Levels()
    var overlay: NSPanel!
    var monitors = [Any]()
    var recorder: AudioCapture?
    var target: Destination?
    var held = false
    private var recordingID = UUID()
    private var pendingText: String?
    private var clickMonitor: Any?
    private var escapeMonitor: Any?
    private var selectionMonitor: Any?
    private var selectionPoint: CGPoint?
    private func stopSelecting() {
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor); self.selectionMonitor = nil }
        selectionPoint = nil
    }
    var previous: Task<Void, Never>?
    var sessionObservers = [NSObjectProtocol]()

    func applicationDidFinishLaunching(_ note: Notification) {
        prefs.refresh()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "RusType")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp])
        prefs.discover()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.prefs.discover() }
        }
        settingsController = NSHostingController(rootView: SettingsView(prefs: prefs, copyText: { [weak self] in self?.copyLastTranscript() }, quit: { NSApp.terminate(nil) }))
        settingsController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = settingsController
        overlay = NSPanel(contentRect: NSRect(origin: .zero, size: RecordingBadge.size), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        overlay.backgroundColor = .clear; overlay.isOpaque = false; overlay.hasShadow = false
        overlay.ignoresMouseEvents = true; overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        overlay.contentView = NSHostingView(rootView: RecordingBadge(levels: levels))
        let ws = NSWorkspace.shared.notificationCenter
        sessionObservers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard self?.prefs.access == true else { return }
            Destination.prepareAccessibility(for: note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cancel() })
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if !prefs.access || !prefs.mic { showSettings() }
    }
    func refresh() {
        prefs.refresh()
        if prefs.access && monitors.isEmpty {
            Destination.prepareAccessibility(for: NSWorkspace.shared.frontmostApplication)
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in self?.key($0) }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in self?.key($0); return $0 }) { monitors.append(m) }
        }
        if !prefs.access && !monitors.isEmpty { monitors.forEach(NSEvent.removeMonitor); monitors = []; cancel() }
    }
    private func clearPending() {
        pendingText = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }
    private func waitForField(_ text: String) {
        clearPending()
        pendingText = text
        report("Щёлкните в поле для вставки · Esc для отмены")
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let point = event.cgEvent?.location else { return }
            Task { @MainActor in
                guard let self, let phrase = self.pendingText, let destination = Destination(),
                      destination.acceptsDictation, destination.containsClick(point) else { return }
                self.clearPending()
                // Let the clicked app move its caret before reading the text around it.
                try? await Task.sleep(nanoseconds: 60_000_000)
                let fitted = Dictation.fit(phrase, after: destination.textBeforeCursor())
                self.lastTranscript = fitted.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = await destination.type(fitted)
                self.report(ok ? "" : "Ввод остановлен: изменился фокус")
            }
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.clearPending(); self?.report("") }
        }
    }
    @objc func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        // A click on the icon first closes the transient popover; don't reopen it on the same click.
        guard Date().timeIntervalSince(popoverClosedAt) > 0.3 else { return }
        showSettings()
    }
    func showSettings() {
        guard let button = item.button else { return }
        if popover.isShown { return }
        if button.window == nil { DispatchQueue.main.async { self.showSettings() }; return }
        prefs.discover()
        settingsController.view.layoutSubtreeIfNeeded()
        let size = settingsController.view.fittingSize
        if size.width > 0, size.height > 0 { popover.contentSize = size }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { appBeforeSettings = front }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(nil) // no blue focus ring on the first control
        }
    }
    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        // Hand focus back to the app the user was typing in, unless they already switched elsewhere.
        if NSApp.isActive, let app = appBeforeSettings, !app.isTerminated { app.activate() }
        appBeforeSettings = nil
    }
    @objc private func copyLastTranscript() {
        guard let lastTranscript else { return }
        clearPending(); report("")
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if !clipboard.setString(lastTranscript, forType: .string) {
            report("Не удалось скопировать текст")
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ note: Notification) { cancel() }
    func cancel() {
        recordingID = UUID(); stopSelecting(); clearPending()
        held = false; overlay?.orderOut(nil)
        if let recorder { recorder.stop { _ in try? FileManager.default.removeItem(at: recorder.url) } }
        recorder = nil; target = nil
    }
    func report(_ message: String) {
        prefs.status = message; item.button?.toolTip = message
    }
    func key(_ event: NSEvent) {
        guard event.keyCode == 63 else { return }
        let down = event.modifierFlags.contains(.function)
        guard down != held else { return }
        held = down
        if !down { finish(); return }
        guard event.modifierFlags.intersection([.control,.command,.option,.shift]).isEmpty else { return }
        guard prefs.mic && prefs.access else { report("Проверьте разрешения в настройках RusType"); return }
        guard let device = prefs.device() else { report("Выбранный микрофон недоступен"); return }
        recordingID = UUID(); stopSelecting(); clearPending(); report("")
        let capture = AudioCapture()
        recorder = capture
        levels.bars = Array(repeating: 0, count: levels.bars.count)
        capture.level = { [weak self, weak capture] level in
            guard let self, let capture, self.recorder === capture, self.held else { return }
            self.levels.append(level)
            if !self.overlay.isVisible {
                let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                if let frame = screen?.visibleFrame { self.overlay.setFrameOrigin(NSPoint(x: frame.midX - RecordingBadge.size.width / 2, y: frame.minY+18)) }
                self.overlay.orderFrontRegardless()
            }
        }
        selectionMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.selectionPoint = event.cgEvent?.location
        }
        capture.start(device: device)
        target = Destination()
    }
    func finish() {
        overlay.orderOut(nil)
        guard let r = recorder else { return }
        let initialDestination = target, id = recordingID
        recorder = nil; target = nil
        let url = r.url
        let stopped = Task { await withCheckedContinuation { continuation in r.stop { continuation.resume(returning: $0) } } }
        let before = previous, rules = prefs.rules
        previous = Task { @MainActor in
            await before?.value
            defer {
                try? FileManager.default.removeItem(at: url)
                if id == recordingID { stopSelecting() }
            }
            do {
                let frames = try await stopped.value.get()
                guard frames > 1920 else { report("Слишком короткая запись"); return }
                let raw = try await Task.detached { try Dictation.recognize(url) }.value
                let text = Dictation.prepare(raw, rules: rules)
                guard !text.isEmpty else { report("Речь не распознана"); return }
                self.lastTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.prefs.canCopy = true
                let destination: Destination?
                if id == recordingID, let point = selectionPoint {
                    let focused = Destination()
                    destination = focused?.containsClick(point) == true ? focused : nil
                } else {
                    destination = initialDestination
                }
                guard let destination, destination.acceptsDictation, destination.current else {
                    if id == recordingID { waitForField(text) }
                    return
                }
                let phrase = Dictation.fit(text, after: destination.textBeforeCursor())
                self.lastTranscript = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = await destination.type(phrase)
                report(ok ? "" : "Ввод остановлен: изменился фокус или недоступно разрешение")
            } catch { report("Не удалось распознать речь: " + error.localizedDescription) }
        }
    }
}

@main struct Entry {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recognize" {
            do { print(Dictation.prepare(try Dictation.recognize(URL(fileURLWithPath: CommandLine.arguments[2])), rules: Preferences().rules)); return }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
