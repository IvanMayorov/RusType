import AppKit
import SwiftUI
import AVFoundation

final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let prefs = Preferences()
    var item: NSStatusItem!
    private var lastTranscript: String?
    var panel: SettingsPanel!
    var settingsSize = CGSize(width: 300, height: 160)
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
        prefs.discover()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.prefs.discover() }
        }
        panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: settingsSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let settings = SettingsView(prefs: prefs, copyText: { [weak self] in self?.copyLastTranscript() }, quit: { NSApp.terminate(nil) })
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .background(GeometryReader { geometry in
                Color.clear.onAppear { self.resizeSettings(geometry.size) }
                    .onChange(of: geometry.size) { self.resizeSettings($0) }
            })
        panel.contentView = NSHostingView(rootView: settings)
        overlay = NSPanel(contentRect: NSRect(origin: .zero, size: RecordingBadge.size), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        overlay.backgroundColor = .clear; overlay.isOpaque = false; overlay.hasShadow = false
        overlay.ignoresMouseEvents = true; overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        overlay.contentView = NSHostingView(rootView: RecordingBadge(levels: levels))
        let ws = NSWorkspace.shared.notificationCenter
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
                let ok = await destination.type(phrase)
                self.report(ok ? "" : "Ввод остановлен: изменился фокус")
            }
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.clearPending(); self?.report("") }
        }
    }
    @objc func togglePanel() { if panel.isVisible { panel.orderOut(nil) } else { showSettings() } }
    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { panel.orderOut(nil) }
    }
    func resizeSettings(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != settingsSize else { return }
        settingsSize = size
        DispatchQueue.main.async { if self.panel.isVisible { self.positionSettings() } }
    }
    func positionSettings() {
        guard let button = item.button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let bounds = screen.frame
        let x = min(max(anchor.midX - settingsSize.width / 2, bounds.minX + 4), bounds.maxX - settingsSize.width - 4)
        let top = min(anchor.minY, bounds.maxY - NSStatusBar.system.thickness) - 2
        panel.setFrame(NSRect(x: x.rounded(), y: top - settingsSize.height, width: settingsSize.width, height: settingsSize.height), display: true)
    }
    func showSettings() {
        positionSettings()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.prefs.discover() }
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
                let ok = await destination.type(text)
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
