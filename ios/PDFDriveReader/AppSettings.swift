import Foundation

/// User preferences, saved in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var clientID: String { didSet { defaults.set(clientID, forKey: "clientID") } }
    @Published var folderPath: String { didSet { defaults.set(folderPath, forKey: "folderPath") } }
    @Published var newestFirst: Bool { didSet { defaults.set(newestFirst, forKey: "newestFirst") } }
    @Published var skipFinished: Bool { didSet { defaults.set(skipFinished, forKey: "skipFinished") } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed") } }
    @Published var voiceID: String { didSet { defaults.set(voiceID, forKey: "voiceID") } }
    @Published var announceTitles: Bool { didSet { defaults.set(announceTitles, forKey: "announceTitles") } }
    @Published var autoPlayInCar: Bool { didSet { defaults.set(autoPlayInCar, forKey: "autoPlayInCar") } }

    private init() {
        defaults.register(defaults: [
            "newestFirst": true,
            "skipFinished": true,
            "speed": 1.0,
            "announceTitles": true,
            "autoPlayInCar": true,
        ])
        clientID = defaults.string(forKey: "clientID") ?? ""
        folderPath = defaults.string(forKey: "folderPath") ?? ""
        newestFirst = defaults.bool(forKey: "newestFirst")
        skipFinished = defaults.bool(forKey: "skipFinished")
        speed = defaults.double(forKey: "speed")
        voiceID = defaults.string(forKey: "voiceID") ?? ""
        announceTitles = defaults.bool(forKey: "announceTitles")
        autoPlayInCar = defaults.bool(forKey: "autoPlayInCar")
    }
}
