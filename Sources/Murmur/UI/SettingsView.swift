import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings()
                .tabItem { Label("Speech", systemImage: "waveform") }
            VocabularySettings()
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            FormattingSettings()
                .tabItem { Label("Formatting", systemImage: "textformat.123") }
            HistorySettings()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var trigger = Prefs.triggerKey
    @State private var capturing = false
    @State private var captureHint: String?
    @State private var captureMonitor: Any?
    @AppStorage(PrefKey.soundFeedback) private var soundFeedback = true
    @AppStorage(PrefKey.showOverlay) private var showOverlay = true

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
                    Text(captureHint).font(.callout).foregroundStyle(.orange)
                }
                Text("Hold \(trigger.display) to talk, release to insert. "
                    + "Quick-tap it, or press Shift+\(trigger.display), to keep recording "
                    + "hands-free; press \(trigger.display) or Return to finish. Esc cancels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Toggle("Play sounds", isOn: $soundFeedback)
                Toggle("Show a floating indicator while recording", isOn: $showOverlay)
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
                let button = event.buttonNumber
                if button >= 2 {
                    endCapture(KeySpec(
                        keyCode: UInt16(button), isModifier: false, isMouse: true,
                        display: KeyNames.mouseName(button)))
                    return nil
                }
                return event
            case .keyDown:
                if event.keyCode == 53 { endCapture(nil); return nil }
                if let name = KeyNames.specials[event.keyCode] {
                    endCapture(KeySpec(keyCode: event.keyCode, isModifier: false, display: name))
                } else {
                    let characters = event.charactersIgnoringModifiers ?? ""
                    let label = characters.count == 1
                        && (characters.first!.isLetter || characters.first!.isNumber)
                        ? "\u{201C}\(characters.uppercased())\u{201D}" : "That key"
                    captureHint = "\(label) types text, so it cannot be the dictation key. "
                        + "Use a modifier, function, or arrow key \u{2014} or a spare mouse button."
                }
                return nil
            case .flagsChanged:
                if let name = KeyNames.modifiers[event.keyCode],
                   let mask = KeyNames.nsModifierMask(for: event.keyCode),
                   event.modifierFlags.contains(mask) {
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
        if let monitor = captureMonitor {
            NSEvent.removeMonitor(monitor)
            captureMonitor = nil
        }
        capturing = false
        if let spec {
            apply(spec)
        } else {
            AppDelegate.shared?.dictation.reloadHotkey()
        }
    }

    private func apply(_ spec: KeySpec) {
        Prefs.triggerKey = spec
        trigger = spec
        captureHint = nil
        AppDelegate.shared?.dictation.reloadHotkey()
        AppDelegate.shared?.refresh()
    }
}

// MARK: - Speech models

private struct ModelSettings: View {
    @EnvironmentObject private var store: ModelStore
    @AppStorage(PrefKey.selectedModel) private var selectedModel = "auto"
    @AppStorage(PrefKey.polishMode) private var polishMode = PolishMode.off.rawValue
    @AppStorage(PrefKey.language) private var language = "en"
    @AppStorage(PrefKey.liveCaption) private var liveCaption = true

    private var polish: PolishMode { PolishMode(rawValue: polishMode) ?? .off }

    var body: some View {
        Form {
            Section("Language") {
                Picker("I speak", selection: $language) {
                    ForEach(SpokenLanguage.all) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .onChange(of: language) { EngineRouter.shared.languageDidChange() }
                Text(language == "auto"
                    ? "The recognizer will guess. On short phrases it sometimes guesses wrong "
                        + "and writes your words in another alphabet."
                    : "Keeps short phrases from being mistaken for another language and "
                        + "written in the wrong alphabet.")
                    .font(.callout)
                    .foregroundStyle(language == "auto" ? .orange : .secondary)
            }

            Section("Active model") {
                Picker("Use", selection: $selectedModel) {
                    Text("Best installed").tag("auto")
                    ForEach(ModelCatalog.all) { model in
                        if store.installed.contains(model.file) {
                            Text(model.title).tag(model.file)
                        }
                    }
                }
                .onChange(of: selectedModel) { EngineRouter.shared.activatePreferredModel() }

                if let active = EngineRouter.shared.loadedModel {
                    Label("\(active.title) loaded \u{2014} \(active.languages)",
                          systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Label(EngineRouter.shared.statusDescription, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Available models") {
                ForEach(ModelCatalog.all) { model in
                    ModelRow(model: model)
                }
            }

            Section("While you speak") {
                Toggle("Show words in the indicator as you talk", isOn: $liveCaption)
                Text(LiveCaptionEngine.isAvailable
                    ? "Uses Apple's on-device recognizer for instant feedback. The final "
                        + "text still comes from the accurate engine."
                    : "Needs macOS 26 with a speech model installed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("AI polish") {
                Picker("After transcribing", selection: $polishMode) {
                    ForEach(PolishMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Text(polish.detail).font(.callout).foregroundStyle(.secondary)

                let availability = AIRefiner.availability
                if !availability.isReady {
                    Label(availability.explanation, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Runs entirely on this Mac using Apple Intelligence. If it changes "
                        + "something you meant to keep, choose \u{201C}Use What I Actually "
                        + "Said\u{201D} from the menu bar (\u{2318}Z) to put your own "
                        + "wording back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRow: View {
    let model: ModelDescriptor
    @EnvironmentObject private var store: ModelStore

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.title).fontWeight(.medium)
                    Text(model.engine.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.16)))
                }
                Text(model.note).font(.callout).foregroundStyle(.secondary)
                Text("\(model.languages) \u{2022} \(model.sizeDescription)")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure = store.failures[model.file] {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if let progress = store.progress[model.file] {
                    ProgressView(value: progress.fraction).frame(width: 110)
                    Text(progress.description).font(.caption2).foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelDownload(model) }
                        .buttonStyle(.borderless)
                } else if store.installed.contains(model.file) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Button(role: .destructive) {
                        store.remove(model)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Download") { store.download(model) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Vocabulary

private struct VocabularySettings: View {
    @State private var entries: [VocabularyEntry] = Prefs.vocabulary
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section {
                Text("Words Murmur should always get right \u{2014} names, companies, jargon, "
                    + "product names. These are given to the recognizer as a hint, and "
                    + "near-misses in the result are corrected back automatically "
                    + "(\u{201C}clawed code\u{201D} \u{2192} \u{201C}Claude Code\u{201D}).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Your words") {
                if entries.isEmpty {
                    Text("Nothing added yet.").foregroundStyle(.secondary)
                }
                ForEach($entries) { $entry in
                    HStack {
                        TextField("Term", text: $entry.term)
                            .textFieldStyle(.plain)
                            .onSubmit(save)
                        Spacer()
                        Toggle("Auto-fix", isOn: $entry.autoCorrect)
                            .toggleStyle(.checkbox)
                            .onChange(of: entry.autoCorrect) { save() }
                        Button(role: .destructive) {
                            entries.removeAll { $0.id == entry.id }
                            save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a word or phrase\u{2026}", text: $newTerm)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: save)
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        entries.append(VocabularyEntry(term: term))
        newTerm = ""
        save()
    }

    private func save() {
        Prefs.vocabulary = entries.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - Formatting

private struct FormattingSettings: View {
    @AppStorage(PrefKey.numberMode) private var numberMode = NumberMode.numerals.rawValue
    @AppStorage(PrefKey.removeFillers) private var removeFillers = true
    @AppStorage(PrefKey.selfCorrections) private var selfCorrections = true
    @AppStorage(PrefKey.spokenLineCommands) private var lineCommands = true
    @AppStorage(PrefKey.spokenPunctuation) private var spokenPunctuation = false
    @AppStorage(PrefKey.smartCapitalization) private var smartCaps = true
    @AppStorage(PrefKey.appendTrailingSpace) private var trailingSpace = true

    private var mode: NumberMode { NumberMode(rawValue: numberMode) ?? .numerals }

    var body: some View {
        Form {
            Section("Numbers") {
                Picker("Write numbers as", selection: $numberMode) {
                    ForEach(NumberMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Text(mode.example).font(.callout).foregroundStyle(.secondary)
                if mode == .numerals || mode == .auto {
                    Text("Also converts units: \u{201C}twenty percent\u{201D} \u{2192} 20%, "
                        + "\u{201C}five hundred rupees\u{201D} \u{2192} \u{20B9}500")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Cleanup") {
                Toggle("Remove filler words (um, uh, hmm)", isOn: $removeFillers)
                Toggle("Fix spoken corrections and repeated words", isOn: $selfCorrections)
                Text("\u{201C}Ship it Friday, no wait, Monday\u{201D} "
                    + "\u{2192} \u{201C}Ship it Monday\u{201D}")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Smart capitalization", isOn: $smartCaps)
                Toggle("End with a trailing space", isOn: $trailingSpace)
            }
            Section("Spoken commands") {
                Toggle("\u{201C}new line\u{201D} / \u{201C}new paragraph\u{201D}",
                       isOn: $lineCommands)
                Toggle("Spoken punctuation (\u{201C}comma\u{201D}, \u{201C}full stop\u{201D})",
                       isOn: $spokenPunctuation)
                Text("The recognizer punctuates on its own, so spoken punctuation is off "
                    + "unless you prefer narrating marks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

private struct HistorySettings: View {
    @EnvironmentObject private var dictation: DictationController
    @AppStorage(PrefKey.keepHistory) private var keepHistory = true
    @State private var search = ""

    private var filtered: [DictationController.HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return dictation.history }
        return dictation.history.filter { $0.text.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Keep a local history of dictations", isOn: $keepHistory)
                    Text("Stored only on this Mac, in Application Support.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 110)

            Divider()

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search dictations", text: $search).textFieldStyle(.plain)
                Spacer()
                Button("Clear all") { dictation.clearHistory() }
                    .disabled(dictation.history.isEmpty)
            }
            .padding(10)

            List(filtered) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.text).font(.callout).textSelection(.enabled)
                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) "
                        + "\u{2022} \(String(format: "%.1fs", entry.seconds))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }
}
