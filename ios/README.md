# PDF Reader for iPhone and CarPlay

A native iPhone app that reads the PDFs in a OneDrive folder aloud, newest first.

- **CarPlay:** shows a list of your PDFs and a Now Playing screen. Use the car's
  touchscreen or steering-wheel buttons for play/pause and next/previous PDF.
  The Now Playing screen also has back and forward buttons that move a few
  sentences.
- **Navigation:** pauses for Apple Maps directions, then resumes.
- **Phone calls:** pauses for calls, then resumes when you hang up.
- **Resume:** keeps your place to the sentence. It picks up there after a
  pause, after you close the app, or when you get back in the car. It can start
  reading automatically when CarPlay connects (setting, on by default).
- **Unplugging:** pauses when you unplug or turn the car off, so it doesn't
  start talking from the phone speaker.
- **Background:** keeps reading with the screen locked or with Maps on screen.

## How the pausing works

The app tells iOS it's a "spoken audio" app, the same kind as a podcast or
audiobook app. Because of that:

- Apple Maps pauses it for each direction instead of just lowering the volume.
  When the prompt ends, iOS tells the app to resume, and it repeats the
  interrupted sentence.
- Phone calls (including CarPlay calls) interrupt it, and it resumes after the
  call.
- Google Maps and Waze usually just lower the volume for their prompts instead
  of pausing other apps. The app can't change that.

## What you need

- A **Mac with Xcode** (free from the Mac App Store).
- An **Apple ID**.
  - With a free Apple ID, Xcode can install the app on your own iPhone, but the
    install expires after 7 days and has to be redone from the Mac.
  - The **Apple Developer Program** ($99 a year) makes installs last a year, lets
    you use TestFlight, and is required to request CarPlay access.
- **CarPlay access from Apple:** to show up as an app on the CarPlay screen,
  Apple has to grant the *CarPlay audio* entitlement. Request it at
  <https://developer.apple.com/contact/carplay/> and choose the audio app
  category. Approval is at Apple's discretion and can take a while.
  - **Until it's approved:** delete the `CODE_SIGN_ENTITLEMENTS` line from
    `project.yml`, or the entitlements file in Xcode, so the app can be signed.
    The app still plays through the car speakers over CarPlay, and play/pause and
    next/previous should work from the steering wheel and CarPlay's own Now
    Playing screen. You just won't have an app icon on the CarPlay screen with
    the PDF list.
  - **In the Simulator:** you can try the CarPlay screen without approval. In
    Xcode's Simulator, choose **I/O → External Displays → CarPlay**.

## Setup

### 1. Register the app with Microsoft

If you already registered one for the web version, reuse it and just add the
redirect URI.

1. Go to <https://entra.microsoft.com> → **App registrations** → your app, or
   **New registration**. For a new one, choose *Accounts in any organizational
   directory and personal Microsoft accounts*.
2. **Authentication → Add a platform → Mobile and desktop applications** → add the
   custom redirect URI `pdfdrivereader://auth`.
3. **API permissions:** make sure **Microsoft Graph → Files.Read** (delegated) is
   listed.
4. Copy the **Application (client) ID**.

### 2. Build it onto your iPhone

```sh
brew install xcodegen      # one-time; generates the Xcode project from project.yml
cd ios
xcodegen
open PDFDriveReader.xcodeproj
```

In Xcode:

1. Select the **PDFDriveReader** target → **Signing & Capabilities** → choose your
   Team. Change the bundle identifier to something unique, such as
   `com.yourname.pdfdrivereader`.
2. Plug in your iPhone, select it at the top of the window, and press **Run** (▶).
3. The first time, on the iPhone, trust the developer under Settings → General →
   VPN & Device Management.

### 3. First launch

1. Paste the client ID, type the folder path as it appears in OneDrive (for
   example `Documents/To Read`), and tap **Sign in with Microsoft**.
2. Optional: install a better voice. On the iPhone go to Settings → Accessibility →
   Spoken Content → Voices → English, and download an *Enhanced* or *Premium*
   voice. The app picks the best installed voice automatically, or you can choose
   one in the app's settings.

## Files

| File | Purpose |
|---|---|
| `ReaderPlayer.swift` | Playback queue, speech, interruption handling (calls and directions), saved position, steering-wheel and lock-screen controls |
| `CarPlaySceneDelegate.swift` | CarPlay list and Now Playing screens |
| `OneDriveAuth.swift` | Microsoft sign-in (OAuth with PKCE), token kept in the Keychain |
| `OneDrive.swift` | Lists and downloads PDFs through Microsoft Graph |
| `PDFText.swift` | Extracts PDF text with PDFKit and splits it into sentences |
| `ContentView.swift` | iPhone screens: setup, player, settings |
| `Info.plist`, `PDFDriveReader.entitlements`, `project.yml` | Background audio, CarPlay scene, build settings |
