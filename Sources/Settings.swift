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
final class SettingsDraft: ObservableObject {
    @Published var heard = ""
    @Published var written = ""
    @Published var expanded = false
}
final class HoverState: ObservableObject { @Published var on = false }

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let copyText: () -> Void
    let quit: () -> Void
    // StateObject instead of @State: the Command Line Tools toolchain ships without the SwiftUI @State macro plugin.
    @StateObject private var draft = SettingsDraft()
    private var microphoneName: String {
        if prefs.microphoneID.isEmpty { return "Системный" }
        return prefs.device()?.localizedName ?? "Устройство отключено"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: copyText) { Label("Скопировать последний текст", systemImage: "doc.on.doc") }
                .buttonStyle(MenuRowStyle()).disabled(!prefs.canCopy)
            Divider().padding(.horizontal, 6)
            HStack(spacing: 8) {
                Label("Микрофон", systemImage: "mic")
                Spacer(minLength: 8)
                Menu {
                    Picker("Микрофон", selection: $prefs.microphoneID) {
                        Text("Системный").tag("")
                        ForEach(prefs.devices, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                        if !prefs.microphoneID.isEmpty && prefs.device() == nil { Text("Устройство отключено").tag(prefs.microphoneID) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(microphoneName).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .frame(maxWidth: 170, alignment: .trailing)
                .foregroundStyle(.secondary)
                .focusEffectDisabled()
                .accessibilityLabel("Микрофон")
            }.padding(.horizontal, 8)
            if !prefs.mic || !prefs.access {
                VStack(alignment: .leading, spacing: 2) {
                    if !prefs.mic {
                        Button { prefs.requestMic() } label: {
                            Label("Разрешить микрофон", systemImage: "exclamationmark.triangle.fill")
                        }.buttonStyle(MenuRowStyle())
                    }
                    if !prefs.access {
                        Button {
                            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                            prefs.openPrivacy("Accessibility")
                        } label: {
                            Label("Разрешить ввод текста", systemImage: "exclamationmark.triangle.fill")
                        }.buttonStyle(MenuRowStyle())
                    }
                }
            }
            if !prefs.status.isEmpty {
                Text(prefs.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            }
            Divider().padding(.horizontal, 6)
            DisclosureGroup(isExpanded: $draft.expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Как распознаётся", text: $draft.heard).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Как вставлять", text: $draft.written).textFieldStyle(.roundedBorder)
                        Button {
                            let key = draft.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                            let value = draft.written.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let index = prefs.rules.firstIndex(where: { $0.heard.caseInsensitiveCompare(key) == .orderedSame }) {
                                prefs.rules[index].written = value
                            } else { prefs.rules.append(Rule(heard: key, written: value)) }
                            draft.heard = ""; draft.written = ""
                        } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Сохранить замену").help("Сохранить замену")
                            .disabled([draft.heard,draft.written].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    }.controlSize(.small)
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
                                        }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Удалить замену " + rule.heard)
                                    }.frame(height: 20)
                                }
                            }
                        }.frame(height: CGFloat(min(prefs.rules.count, 4)) * 24)
                    }
                }.padding(.top, 6)
            } label: {
                Label("Словарь замен", systemImage: "character.book.closed")
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { draft.expanded.toggle() } }
            }.padding(.horizontal, 8)
            Divider().padding(.horizontal, 6)
            Button(action: quit) {
                HStack {
                    Text("Завершить RusType")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
            }.buttonStyle(MenuRowStyle(quiet: true)).keyboardShortcut("q")
        }
        .font(.system(size: 13))
        .labelStyle(MenuLabelStyle())
        .buttonStyle(MenuRowStyle())
        .padding(.vertical, 12).padding(.horizontal, 6)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A full-width row that highlights on hover, like items in a macOS menu.
struct MenuRowStyle: ButtonStyle {
    var quiet = false
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration, quiet: quiet) }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let quiet: Bool
        @StateObject private var hover = HoverState()
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let active = hover.on && isEnabled
            configuration.label
                .labelStyle(MenuLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(active ? AnyShapeStyle(Color.white) : quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1) : Color.clear))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hover.on = $0 }
        }
    }
}

struct MenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}
