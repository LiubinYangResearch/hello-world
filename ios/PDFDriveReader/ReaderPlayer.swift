import AVFoundation
import MediaPlayer

/// Reads the folder's PDFs aloud one after another.
///
/// - Uses the `.spokenAudio` audio-session mode, which tells iOS this is a
///   podcast/audiobook-style app. Apple Maps (and other navigation apps that
///   follow Apple's guidance) then *pause* it during directions instead of just
///   lowering the volume, and phone calls interrupt it. In both cases we get an
///   interruption notification, stop, and pick up again when it ends.
/// - Remembers the exact sentence it reached, so it resumes there after an
///   interruption, after the app is closed, or when you next get in the car.
@MainActor
final class ReaderPlayer: ObservableObject {
    static let shared = ReaderPlayer()

    @Published private(set) var files: [DriveItem] = []
    @Published private(set) var current: DriveItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Press play to start"
    @Published private(set) var position = 0   // sentence within the current PDF
    @Published private(set) var length = 0     // sentences in the current PDF
    @Published private(set) var finished: Set<String>

    private let settings = AppSettings.shared
    private let synth = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()
    private var chunks: [String] = []          // intro lines + PDF sentences
    private var intro = 0                      // number of intro lines before the PDF text
    private var index = 0                      // index into `chunks`
    private var utterance: AVSpeechUtterance?
    private var textCache: [String: Task<[String], Error>] = [:]
    private var generation = 0                 // bumped on every stop so stale callbacks are ignored
    private var isLoading = false
    private var resumeAfterInterruption = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        finished = Set(UserDefaults.standard.stringArray(forKey: "finished") ?? [])
        speechDelegate.onFinish = { [weak self] u in self?.utteranceFinished(u) }
        synth.delegate = speechDelegate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        observeAudioSession()
        setUpRemoteCommands()
    }

    // MARK: - Public controls

    func refresh() async {
        guard OneDriveAuth.shared.isSignedIn else { return }
        do {
            let items = try await OneDrive.listPDFs(folder: settings.folderPath)
            let newest = settings.newestFirst
            files = items.sorted { newest ? $0.createdDateTime > $1.createdDateTime : $0.createdDateTime < $1.createdDateTime }
            if current == nil {
                let unread = files.filter { !finished.contains($0.id) }.count
                status = files.isEmpty ? "No PDFs in that folder" : "\(files.count) PDFs · \(unread) unread"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func play() {
        if current != nil, !chunks.isEmpty {
            isPlaying = true
            speak()
            return
        }
        guard !isLoading else { return }
        Task {
            if files.isEmpty { await refresh() }
            if let saved = savedPosition, let item = files.first(where: { $0.id == saved.id }) {
                start(item, at: saved.sentence)
            } else if let i = nextIndex(after: nil, automatic: true) {
                start(files[i])
            } else {
                say("There are no unread PDFs in the folder.")
            }
        }
    }

    func pause() {
        resumeAfterInterruption = false
        halt()
        status = "Paused"
        updateNowPlaying()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func next() {
        guard let item = current else { return play() }
        advance(from: item, automatic: false, preface: nil)
    }

    /// Restarts the current PDF, or goes to the previous one if we're at its start.
    func previous() {
        guard let item = current, let i = files.firstIndex(where: { $0.id == item.id }) else { return }
        if position > 2 || i == 0 {
            start(item)
        } else {
            start(files[i - 1])
        }
    }

    /// Moves back (negative) or forward by a number of sentences.
    func skip(_ sentences: Int) {
        guard current != nil, !chunks.isEmpty else { return }
        let wasPlaying = isPlaying
        halt()
        index = min(max(intro, index + sentences), chunks.count - 1)
        position = index - intro
        if wasPlaying {
            isPlaying = true
            speak()
        } else {
            saveCurrentPosition()
            updateNowPlaying()
        }
    }

    func start(_ item: DriveItem, at sentence: Int = 0, preface: String? = nil) {
        halt()
        let gen = generation
        current = item
        chunks = []
        index = 0
        position = sentence
        length = 0
        isPlaying = true
        isLoading = true
        status = "Opening…"
        updateNowPlaying()

        Task {
            let text: [String]
            do {
                text = try await loadText(item)
            } catch {
                guard gen == generation else { return }
                isLoading = false
                status = error.localizedDescription
                if error is AuthError {
                    halt()
                    say("Please sign in to OneDrive on your phone.")
                } else {
                    advance(from: item, automatic: false, preface: "Couldn't open \(item.title). Skipping.")
                }
                return
            }
            guard gen == generation else { return }
            isLoading = false

            if text.isEmpty {
                markFinished(item)
                advance(from: item, automatic: true, preface: "\(item.title) has no readable text. Skipping.")
                return
            }
            var lines: [String] = []
            if let preface { lines.append(preface) }
            if sentence > 0 {
                lines.append("Resuming \(item.title).")
            } else if settings.announceTitles {
                lines.append(item.title + ".")
            }
            chunks = lines + text
            intro = lines.count
            index = intro + min(max(sentence, 0), text.count - 1)
            length = text.count
            prefetch(after: item)
            speak()
        }
    }

    func markAllUnread() {
        finished = []
        UserDefaults.standard.set([String](), forKey: "finished")
        savedPosition = nil
    }

    /// Title of the PDF we'd resume, if any.
    var resumeTitle: String? {
        guard let saved = savedPosition else { return nil }
        return files.first { $0.id == saved.id }?.title
    }

    static var availableVoices: [AVSpeechSynthesisVoice] {
        let language = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted {
                $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name
            }
    }

    // MARK: - Speaking

    private func speak() {
        guard isPlaying, let item = current else { return }
        guard index < chunks.count else { return finishedCurrent(item) }
        position = max(0, index - intro)
        saveCurrentPosition()
        status = "Sentence \(position + 1) of \(length)"

        let u = AVSpeechUtterance(string: chunks[index])
        u.rate = speechRate
        u.voice = voice
        utterance = u
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.speak(u)
        updateNowPlaying()
    }

    private func utteranceFinished(_ u: AVSpeechUtterance) {
        guard u === utterance, isPlaying else { return }
        index += 1
        speak()
    }

    /// Speaks a standalone notice that isn't part of any PDF.
    private func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = speechRate
        u.voice = voice
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.speak(u)
    }

    /// Stops speech immediately, keeping our place.
    private func halt() {
        generation += 1
        utterance = nil
        isPlaying = false
        isLoading = false
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    private func finishedCurrent(_ item: DriveItem) {
        markFinished(item)
        savedPosition = nil
        let gen = generation
        Task {
            await refresh() // pick up PDFs added while we were listening
            guard gen == generation else { return }
            advance(from: item, automatic: true, preface: nil)
        }
    }

    private func advance(from item: DriveItem, automatic: Bool, preface: String?) {
        if let i = nextIndex(after: item.id, automatic: automatic) {
            start(files[i], preface: preface)
        } else {
            halt()
            current = nil
            chunks = []
            length = 0
            position = 0
            status = "All caught up"
            updateNowPlaying()
            say([preface, "That was the last unread PDF in the folder."].compactMap { $0 }.joined(separator: " "))
        }
    }

    /// Which PDF comes next.
    /// With "skip finished" on, a PDF that just ended moves on to the first unread
    /// PDF in folder order, so newly added PDFs come next when sorting newest first.
    /// Pressing Next goes to the next unread PDF below the current one.
    private func nextIndex(after id: String?, automatic: Bool) -> Int? {
        let after = (id.flatMap { id in files.firstIndex { $0.id == id } } ?? -1) + 1
        guard settings.skipFinished else { return after < files.count ? after : nil }
        let unread: (DriveItem) -> Bool = { [finished] item in !finished.contains(item.id) && item.id != id }
        if !automatic, after <= files.count, let i = files[after...].firstIndex(where: unread) { return i }
        return files.firstIndex(where: unread)
    }

    private func loadText(_ item: DriveItem) async throws -> [String] {
        if let cached = textCache[item.id] { return try await cached.value }
        let task = Task { () async throws -> [String] in
            let data = try await OneDrive.download(item)
            return await Task.detached(priority: .userInitiated) { PDFText.chunks(from: data) }.value
        }
        textCache[item.id] = task
        do {
            return try await task.value
        } catch {
            textCache[item.id] = nil
            throw error
        }
    }

    private func prefetch(after item: DriveItem) {
        guard let i = nextIndex(after: item.id, automatic: false) else { return }
        let next = files[i]
        Task { _ = try? await loadText(next) }
    }

    private var speechRate: Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(pow(settings.speed, 0.6))
        return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private var voice: AVSpeechSynthesisVoice? {
        if !settings.voiceID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: settings.voiceID) { return chosen }
        return Self.availableVoices.first
    }

    // MARK: - Progress

    private func markFinished(_ item: DriveItem) {
        finished.insert(item.id)
        UserDefaults.standard.set(Array(finished), forKey: "finished")
    }

    private func saveCurrentPosition() {
        if let current { savedPosition = (current.id, position) }
    }

    private var savedPosition: (id: String, sentence: Int)? {
        get {
            guard let id = UserDefaults.standard.string(forKey: "positionID") else { return nil }
            return (id, UserDefaults.standard.integer(forKey: "positionSentence"))
        }
        set {
            UserDefaults.standard.set(newValue?.id, forKey: "positionID")
            UserDefaults.standard.set(newValue?.sentence ?? 0, forKey: "positionSentence")
        }
    }

    // MARK: - Calls, directions, unplugging

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in self?.handleInterruption(type, options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            // CarPlay / Bluetooth / headphones disconnected (e.g. car turned off): pause, don't blast from the phone.
            if reason == .oldDeviceUnavailable {
                Task { @MainActor in self?.pause() }
            }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, _ options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            // A phone call, or navigation directions from Maps.
            guard isPlaying else { return }
            halt()
            resumeAfterInterruption = true
            status = "Paused for call or directions"
            updateNowPlaying()
        case .ended:
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            if options.contains(.shouldResume) {
                play() // repeats the interrupted sentence from its start
            } else {
                status = "Paused"
            }
        @unknown default:
            break
        }
    }

    // MARK: - Lock screen, CarPlay and steering-wheel controls

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        // Keep Next/Previous (whole PDFs) on the car's buttons rather than seek buttons.
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let progress = length > 0 ? "\(position * 100 / length)% read" : "Loading…"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: progress,
            MPMediaItemPropertyAlbumTitle: "PDF Drive Reader",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}

/// Bridges AVSpeechSynthesizer's delegate callbacks onto the main actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (@MainActor (AVSpeechUtterance) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let callback = onFinish
        Task { @MainActor in callback?(utterance) }
    }
}
