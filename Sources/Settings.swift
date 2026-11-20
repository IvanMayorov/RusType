import SwiftUI
import AVFoundation

class Preferences: ObservableObject {
    @Published var rules: [Rule] {
        didSet { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "dictionary.v1") } }
    }
    @Published var microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? "" {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
    }
    @Published var devices = [AVCaptureDevice]()
    @Published var canCopy = false
    func discover() {
        devices = AVCaptureDevice.devices(for: .audio)
    }
    func device() -> AVCaptureDevice? {
        microphoneID.isEmpty ? AVCaptureDevice.default(for: .audio) : devices.first { $0.uniqueID == microphoneID }
    }
    @Published var mic = false
    @Published var access = false
    @Published var status = ""
    init() {
        rules = UserDefaults.standard.data(forKey: "dictionary.v1").flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
    }
    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let access = AXIsProcessTrusted()
        if self.mic != mic { self.mic = mic }
        if self.access != access { self.access = access }
    }
    func requestMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        } else { openPrivacy("Microphone") }
    }
    func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_"+pane)!)
    }
}
struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let copyText: () -> Void
    let quit: () -> Void
    @State private var heard = ""
    @State private var written = ""
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: copyText) { Label("Скопировать последний текст", systemImage: "doc.on.doc") }.disabled(!prefs.canCopy)
            Divider()
            Picker("Микрофон", selection: $prefs.microphoneID) {
                Text("Системный").tag("")
                ForEach(prefs.devices, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                if !prefs.microphoneID.isEmpty && prefs.device() == nil { Text("Устройство отключено").tag(prefs.microphoneID) }
            }
            if !prefs.mic || !prefs.access {
                VStack(alignment: .leading, spacing: 4) {
                if !prefs.mic { Button("Разрешить микрофон") { prefs.requestMic() } }
                if !prefs.access { Button("Разрешить ввод текста") {
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    prefs.openPrivacy("Accessibility")
                } }
                }
            }
            if !prefs.status.isEmpty { Text(prefs.status).foregroundColor(.secondary) }
            Divider()
            DisclosureGroup("Словарь замен", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
            HStack { TextField("Как распознаётся", text: $heard); Image(systemName: "arrow.right"); TextField("Как вставлять", text: $written)
                Button {
                    let key = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = written.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let index = prefs.rules.firstIndex(where: { $0.heard.caseInsensitiveCompare(key) == .orderedSame }) {
                        prefs.rules[index].written = value
                    } else { prefs.rules.append(Rule(heard: key, written: value)) }
                    heard = ""; written = ""
                } label: { Image(systemName: "plus") }.accessibilityLabel("Сохранить замену").help("Сохранить замену").disabled([heard,written].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
            if !prefs.rules.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(prefs.rules) { rule in
                            HStack {
                                Text(rule.heard).lineLimit(1).help(rule.heard)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(rule.written).lineLimit(1).help(rule.written)
                                Spacer()
                                Button { prefs.rules.removeAll { $0.id == rule.id } } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless).accessibilityLabel("Удалить замену " + rule.heard)
                            }.frame(height: 20)
                        }
                    }
                }.frame(height: CGFloat(min(prefs.rules.count, 4)) * 24)
            }
                }.padding(.top, 4)
            }
            Divider()
            Button("Завершить RusType", action: quit)
        }.controlSize(.small).padding(12).frame(width: 300).fixedSize(horizontal: false, vertical: true)
    }
}
