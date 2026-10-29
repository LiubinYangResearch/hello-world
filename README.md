# PDF Drive Reader

A small phone web app that signs in to your OneDrive, finds the PDFs in one folder,
and reads them aloud **one after another, newest created first** — no tapping
through files while driving.

- Big Play / Pause / Next / Previous / Back / Forward buttons
- Steering-wheel and Bluetooth media buttons work (play, pause, next, previous)
- Remembers where you stopped and which PDFs you've finished
- Checks the folder again after each PDF, so new uploads are picked up
- Keeps the screen awake while playing
- Install to your home screen; no app store needed

It runs entirely in your phone's browser. Your files go only between your phone
and Microsoft. The speech uses your phone's built-in voices.

## Why not modify Adobe Acrobat?

Acrobat Reader for mobile is closed source and has no plug-in or scripting support,
so you can't add a "play the whole folder" feature to it. This app is the
practical alternative.

## One-time setup (about 15 minutes)

### 1. Host the app (GitHub Pages, free)

1. In this GitHub repo, go to **Settings → Pages**.
2. Under **Build and deployment**, choose **Deploy from a branch**, pick the branch
   that holds these files and the `/ (root)` folder, then **Save**.
3. After a minute you get a URL like
   `https://<your-github-username>.github.io/hello-world/`. That's your app URL.

### 2. Register the app with Microsoft (free)

This lets the app ask your permission to read your OneDrive.

1. Go to <https://entra.microsoft.com> (or the Azure portal) and sign in.
   Any Microsoft account works, including a personal one.
2. Open **App registrations → New registration**.
   - **Name:** `PDF Drive Reader`
   - **Supported account types:** *Accounts in any organizational directory and
     personal Microsoft accounts*
   - **Redirect URI:** platform **Single-page application (SPA)**, value = your app URL
     from step 1, **including the trailing slash**.
3. Click **Register**, then copy the **Application (client) ID**.
4. Under **API permissions**, check that **Microsoft Graph → Files.Read** (delegated)
   is listed. Add it if it isn't.

> If your OneDrive is a Yale or other work/school account, your IT department may
> need to approve the app the first time you sign in. A personal OneDrive doesn't
> need this.

### 3. Set it up on your phone

1. Open your app URL in **Safari** (iPhone) or **Chrome** (Android).
2. Paste the client ID, enter the folder path as it appears in OneDrive
   (for example `Documents/To Read`), and tap **Save**.
3. Tap **Sign in with Microsoft** and approve.
4. Add it to your home screen:
   - iPhone: Share button → **Add to Home Screen**
   - Android: ⋮ menu → **Install app** / **Add to Home screen**

## Using it in the car

1. Mount the phone, open the app, and press **▶** once before you start driving.
2. It reads the newest unread PDF, then moves on to the next one automatically.
   When the folder runs out, it says so and stops.
3. Use your car's or headset's next/previous buttons to skip PDFs.
4. Settings (⚙) has speed, voice, newest-first or oldest-first order,
   "skip finished PDFs", and "announce each title".

**Keep the app on screen while it reads.** Phone browsers, iPhones especially,
may stop built-in speech when the screen locks or you switch apps. The app keeps
the screen awake for you. If you need it to keep reading behind other apps
(for example, alongside navigation), see *Ideas for later* below.

## Limitations

- Scanned PDFs that are only images have no text to read. The app says
  "no readable text" and skips them.
- Text comes out in the PDF's own order, so headers, footers, page numbers and
  multi-column layouts may sound a little choppy.
- Voice quality depends on the voices installed on your phone. On iPhone, download
  an "Enhanced" or "Premium" voice under Settings → Accessibility → Spoken Content
  → Voices, then select it in the app.

## Ideas for later

To get true background playback with a locked screen, plus higher-quality voices,
convert each new PDF to an MP3 automatically: a Power Automate flow or small cloud
function watches the folder, turns the text into speech with Azure AI Speech, and
saves MP3s back to OneDrive. Any podcast or music player can then play them like
a playlist.

## Files

| File | Purpose |
|---|---|
| `index.html` | Page layout |
| `style.css` | Large, high-contrast styling |
| `app.js` | Sign-in, OneDrive listing, PDF text extraction, speech, media buttons |
| `manifest.webmanifest`, `sw.js`, `icon.svg` | Make it installable to the home screen |
