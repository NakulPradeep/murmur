import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            FormattingSettings()
                .tabItem { Label("Formatting", systemImage: "textformat.123") }
            VocabularySettings()
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var trigger = Prefs.triggerKey
    @State private var capturing = false
    @State private var captureHint: String?
    @State private var captureMonitor: Any?
    @AppStorage(PrefKey.soundFeedback) private var soundFeedback = true

    var body: some View {
        Form {
            Section("Dictation key") {
                HStack {
                    Text(capturing ? "Press any key\u{2026}" : trigger.display)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(capturing ? Color.accentColor.opacity(0.2)
                                                : Color.secondary.opacity(0.15)))
                    Spacer()
                    Button(capturing ? "Cancel" : "Change\u{2026}") {
                        capturing ? endCapture(nil) : beginCapture()
                    }
                    if !capturing, trigger != .defaultKey {
                        Button("Reset") { apply(.defaultKey) }
                    }
                }
                if let captureHint {
                    Text(captureHint)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("Hold \(trigger.display) to talk \u{2014} release to insert. "
                    + "Quick-tap it, or press Shift+\(trigger.display), to record hands-free; "
                    + "press \(trigger.display) or Return to finish. Esc cancels. "
                    + "Keys and middle/side mouse buttons can both be the trigger.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Sound feedback", isOn: $soundFeedback)
            }
            Section("Privacy") {
                Text("Everything runs on this Mac. Your voice is never uploaded anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { endCapture(nil) }
    }

    private func beginCapture() {
        capturing = true
        captureHint = nil
        AppDelegate.shared?.dictation.suspendHotkeys()
        captureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            switch event.type {
            case .otherMouseDown:
                let btn = event.buttonNumber
                if btn >= 2 {
                    endCapture(KeySpec(
                        keyCode: UInt16(btn), isModifier: false, isMouse: true,
                        display: KeyNames.mouseName(btn)))
                    return nil
                }
                return event
            case .keyDown:
                if event.keyCode == 53 {  // Esc cancels capture
                    endCapture(nil)
                    return nil
                }
                if let name = KeyNames.specials[event.keyCode] {
                    endCapture(KeySpec(keyCode: event.keyCode, isModifier: false, display: name))
                } else {
                    let ch = event.charactersIgnoringModifiers ?? ""
                    let label = ch.count == 1 && (ch.first!.isLetter || ch.first!.isNumber)
                        ? "\u{201C}\(ch.uppercased())\u{201D}" : "That key"
                    captureHint = "\(label) types or edits text, so it can't be the dictation key. "
                        + "Use a modifier, function, or arrow key \u{2014} or click a middle/side mouse button."
                }
                return nil
            case .flagsChanged:
                if let name = KeyNames.modifiers[event.keyCode],
                   let mask = KeyNames.nsModifierMask(for: event.keyCode),
                   event.modifierFlags.contains(mask) {  // key press, not release
                    endCapture(KeySpec(keyCode: event.keyCode, isModifier: true, display: name))
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func endCapture(_ spec: KeySpec?) {
        if let m = captureMonitor {
            NSEvent.removeMonitor(m)
            captureMonitor = nil
        }
        capturing = false
        if let spec {
            apply(spec)
        } else {
            // Re-arm the global hotkey with the unchanged trigger.
            AppDelegate.shared?.dictation.reloadHotkey()
        }
    }

    private func apply(_ spec: KeySpec) {
        Prefs.triggerKey = spec
        trigger = spec
        captureHint = nil
        AppDelegate.shared?.dictation.reloadHotkey()
        AppDelegate.shared?.refreshMenu()
    }
}

// MARK: - Formatting

private struct FormattingSettings: View {
    @AppStorage(PrefKey.numberMode) private var numberMode = NumberMode.numerals.rawValue
    @AppStorage(PrefKey.removeFillers) private var removeFillers = true
    @AppStorage(PrefKey.spokenLineCommands) private var lineCommands = true
    @AppStorage(PrefKey.spokenPunctuation) private var spokenPunctuation = false
    @AppStorage(PrefKey.smartCapitalization) private var smartCaps = true
    @AppStorage(PrefKey.appendTrailingSpace) private var trailingSpace = true

    private var selectedMode: NumberMode {
        NumberMode(rawValue: numberMode) ?? .numerals
    }

    var body: some View {
        Form {
            Section("Numbers") {
                Picker("Write numbers as", selection: $numberMode) {
                    ForEach(NumberMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Text(selectedMode.example)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if selectedMode == .numerals || selectedMode == .auto {
                    Text("Also converts units: \u{201C}twenty percent\u{201D} \u{2192} 20%, \u{201C}five hundred rupees\u{201D} \u{2192} \u{20B9}500")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Cleanup") {
                Toggle("Remove filler words (um, uh, hmm)", isOn: $removeFillers)
                Toggle("Smart capitalization", isOn: $smartCaps)
                Toggle("End with a trailing space (chains dictations smoothly)", isOn: $trailingSpace)
            }
            Section("Spoken commands") {
                Toggle("\u{201C}new line\u{201D} / \u{201C}new paragraph\u{201D}", isOn: $lineCommands)
                Toggle("Spoken punctuation (\u{201C}comma\u{201D}, \u{201C}full stop\u{201D}, \u{2026})", isOn: $spokenPunctuation)
                Text("Whisper punctuates automatically, so spoken punctuation is off unless you prefer narrating marks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Vocabulary

private struct VocabularySettings: View {
    @State private var replacements: [CustomReplacement] = Prefs.customReplacements
    @State private var newFind = ""
    @State private var newReplace = ""

    var body: some View {
        Form {
            Section {
                Text("Fix words the transcriber gets wrong \u{2014} names, jargon, brands. Matching is case-insensitive on whole words.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Replacements") {
                ForEach(replacements) { r in
                    HStack {
                        Text(r.find)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(r.replace)
                        Spacer()
                        Button(role: .destructive) {
                            replacements.removeAll { $0.id == r.id }
                            Prefs.customReplacements = replacements
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("heard\u{2026}", text: $newFind)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("should be\u{2026}", text: $newReplace)
                    Button("Add") {
                        let r = CustomReplacement(
                            find: newFind.trimmingCharacters(in: .whitespaces),
                            replace: newReplace.trimmingCharacters(in: .whitespaces))
                        guard !r.find.isEmpty else { return }
                        replacements.append(r)
                        Prefs.customReplacements = replacements
                        newFind = ""
                        newReplace = ""
                    }
                    .disabled(newFind.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Models

private struct ModelSettings: View {
    @EnvironmentObject private var models: ModelManager
    @AppStorage(PrefKey.selectedModel) private var selectedModel = "auto"

    var body: some View {
        Form {
            Section {
                Picker("Active model", selection: $selectedModel) {
                    Text("Auto (best installed)").tag("auto")
                    ForEach(ModelManager.catalog) { model in
                        if models.installed.contains(model.file) {
                            Text(model.title).tag(model.file)
                        }
                    }
                }
                .onChange(of: selectedModel) {
                    ModelManager.shared.loadSelectedModel()
                }
                if let active = models.activeModelFile {
                    Text("Loaded: \(active)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No model loaded yet \u{2014} download one below.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section("Available models") {
                ForEach(ModelManager.catalog) { model in
                    ModelRow(model: model)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).fontWeight(.medium)
                Text("\(model.note) \u{2022} \(model.sizeMB) MB")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = models.downloadProgress[model.file] {
                ProgressView(value: progress)
                    .frame(width: 90)
                Button("Cancel") { models.cancelDownload(model) }
                    .buttonStyle(.borderless)
            } else if models.installed.contains(model.file) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(role: .destructive) {
                    models.remove(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            } else {
                Button("Download") { models.download(model) }
            }
        }
    }
}
