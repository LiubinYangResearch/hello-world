import AuthenticationServices
import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject private var auth = OneDriveAuth.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var player = ReaderPlayer.shared
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if settings.clientID.isEmpty || !auth.isSignedIn {
                    SetupView()
                } else {
                    PlayerView()
                }
            }
            .navigationTitle("PDF Reader")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await player.refresh() } }) {
                SettingsView()
            }
        }
        .task { await player.refresh() }
    }
}

struct SetupView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Application (client) ID", text: $settings.clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Folder, e.g. Documents/To Read", text: $settings.folderPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("The client ID comes from your Microsoft app registration (see README).")
            }
            Section {
                Button("Sign in with Microsoft") { signIn() }
                    .disabled(settings.clientID.isEmpty)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private func signIn() {
        error = nil
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIWindow()
        Task {
            do {
                try await OneDriveAuth.shared.signIn(from: window)
                await ReaderPlayer.shared.refresh()
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
                // User closed the sign-in sheet.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct PlayerView: View {
    @ObservedObject private var player = ReaderPlayer.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(headline).font(.title2.bold())
                    Text(player.status).foregroundStyle(.secondary)
                    ProgressView(value: Double(player.position), total: Double(max(player.length, 1)))
                    HStack(spacing: 0) {
                        control("backward.end.fill", label: "Previous PDF") { player.previous() }
                        control("gobackward", label: "Back a few sentences") { player.skip(-3) }
                        control(player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                                label: player.isPlaying ? "Pause" : "Play", size: 64) { player.togglePlay() }
                        control("goforward", label: "Forward a few sentences") { player.skip(3) }
                        control("forward.end.fill", label: "Next PDF") { player.next() }
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Folder") {
                ForEach(player.files) { file in
                    Button { player.start(file) } label: { row(file) }
                }
            }
        }
        .refreshable { await player.refresh() }
    }

    private var headline: String {
        if let current = player.current { return current.title }
        if let resume = player.resumeTitle { return "Resume: \(resume)" }
        return "Press play to start"
    }

    private func row(_ file: DriveItem) -> some View {
        let isCurrent = player.current?.id == file.id
        let isFinished = player.finished.contains(file.id)
        return HStack {
            VStack(alignment: .leading) {
                Text(file.title).fontWeight(isCurrent ? .semibold : .regular)
                Text(file.createdDateTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
            } else if isFinished {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isFinished && !isCurrent ? Color.secondary : Color.primary)
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 30, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.borderless) // several buttons in one List row
        .accessibilityLabel(label)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("OneDrive") {
                    TextField("Application (client) ID", text: $settings.clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Folder, e.g. Documents/To Read", text: $settings.folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Newest PDFs first", isOn: $settings.newestFirst)
                    Toggle("Skip PDFs already finished", isOn: $settings.skipFinished)
                }
                Section("Voice") {
                    VStack(alignment: .leading) {
                        Text("Speed \(settings.speed, specifier: "%.1f")×")
                        Slider(value: $settings.speed, in: 0.6...2.0, step: 0.1)
                    }
                    Picker("Voice", selection: $settings.voiceID) {
                        Text("Best available").tag("")
                        ForEach(ReaderPlayer.availableVoices, id: \.identifier) { voice in
                            Text(voiceLabel(voice)).tag(voice.identifier)
                        }
                    }
                    Toggle("Announce each title", isOn: $settings.announceTitles)
                }
                Section {
                    Toggle("Resume automatically in CarPlay", isOn: $settings.autoPlayInCar)
                } header: {
                    Text("Car")
                } footer: {
                    Text("Starts reading where you left off as soon as your iPhone connects to CarPlay.")
                }
                Section {
                    Button("Mark all PDFs as unread") { ReaderPlayer.shared.markAllUnread() }
                    Button("Sign out", role: .destructive) {
                        ReaderPlayer.shared.pause()
                        OneDriveAuth.shared.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return voice.name + " (Premium)"
        case .enhanced: return voice.name + " (Enhanced)"
        default: return voice.name
        }
    }
}
