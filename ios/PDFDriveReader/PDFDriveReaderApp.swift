import SwiftUI

@main
struct PDFDriveReaderApp: App {
    init() {
        // Set up the audio session and car / lock-screen controls at launch,
        // so steering-wheel buttons work even before the phone UI is opened.
        _ = ReaderPlayer.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
