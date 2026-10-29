import CarPlay
import Combine

/// The CarPlay screen: a list of the folder's PDFs plus the standard
/// Now Playing screen with play/pause, next/previous and back/forward buttons.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var list: CPListTemplate?
    private var subscriptions = Set<AnyCancellable>()
    private var player: ReaderPlayer { ReaderPlayer.shared }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let list = CPListTemplate(title: "PDF Reader", sections: [])
        self.list = list
        interfaceController.setRootTemplate(list, animated: false, completion: nil)
        setUpNowPlayingButtons()

        player.objectWillChange
            .merge(with: OneDriveAuth.shared.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildList() }
            .store(in: &subscriptions)
        rebuildList()

        // Get in the car → carry on where you left off.
        Task { @MainActor in
            await player.refresh()
            if AppSettings.shared.autoPlayInCar, OneDriveAuth.shared.isSignedIn, !player.isPlaying {
                player.play()
                showNowPlaying()
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        subscriptions.removeAll()
        self.interfaceController = nil
        list = nil
    }

    private func rebuildList() {
        guard let list else { return }
        var items: [CPListItem] = []

        if !OneDriveAuth.shared.isSignedIn {
            items.append(CPListItem(text: "Sign in on your iPhone", detailText: "Open PDF Reader on your phone to connect OneDrive."))
        } else {
            let title: String
            if let current = player.current {
                title = (player.isPlaying ? "Playing: " : "Resume: ") + current.title
            } else if let resume = player.resumeTitle {
                title = "Resume: " + resume
            } else {
                title = "Play newest unread"
            }
            let playItem = CPListItem(text: title, detailText: player.status)
            playItem.handler = { [weak self] _, completion in
                Task { @MainActor in
                    if !(self?.player.isPlaying ?? true) { self?.player.play() }
                    self?.showNowPlaying()
                }
                completion()
            }
            items.append(playItem)

            for file in player.files.prefix(max(0, CPListTemplate.maximumItemCount - 1)) {
                let finished = player.finished.contains(file.id)
                let date = file.createdDateTime.formatted(date: .abbreviated, time: .omitted)
                let item = CPListItem(text: file.title, detailText: finished ? "Finished · \(date)" : date)
                item.isPlaying = player.current?.id == file.id
                item.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        self?.player.start(file)
                        self?.showNowPlaying()
                    }
                    completion()
                }
                items.append(item)
            }
        }
        list.updateSections([CPListSection(items: items)])
    }

    private func setUpNowPlayingButtons() {
        let back = CPNowPlayingImageButton(image: UIImage(systemName: "gobackward")!) { _ in
            Task { @MainActor in ReaderPlayer.shared.skip(-3) }
        }
        let forward = CPNowPlayingImageButton(image: UIImage(systemName: "goforward")!) { _ in
            Task { @MainActor in ReaderPlayer.shared.skip(3) }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([back, forward])
    }

    private func showNowPlaying() {
        guard let interfaceController, interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
