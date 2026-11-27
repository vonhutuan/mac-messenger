# MacMessenger

A lightweight, native macOS `WKWebView` wrapper for Facebook Messenger (`facebook.com/messages`) built in pure Swift — no Electron and no full Xcode required (macOS Command Line Tools + Swift are enough).

## Features

- **Native macOS Notifications:** Bridges `window.Notification` to `UNUserNotificationCenter` so incoming messages trigger native macOS banners and sounds, and clicking a notification jumps back into the app.
- **Voice & Video Calls (WebRTC):**
  - Uses a desktop macOS Safari User-Agent so Facebook enables calling.
  - Opens Messenger's call popups (`window.open`) in a real child `NSWindow` / `WKWebView` preserving `window.opener` and WebRTC sessions.
  - Handles macOS microphone and camera permission prompts (`AVCaptureDevice` + `WKUIDelegate`).
- **Clean Messenger Mode:** Optional CSS toggle (**View → Hide Facebook Top Bar**, `⌘B`) that hides Facebook's top navigation bar on `/messages` pages.
- **Dock Unread Badge & Menu Bar Icon:** Watches unread message counts and keeps running silently in the background when you close the main window (`⌘W`).
- **Native Attachments & Links:** Supports `NSOpenPanel` file uploads, `WKDownload` downloads into `~/Downloads`, and opens outbound links in your default browser.

## Requirements

- macOS 13+
- Apple Command Line Tools (`xcode-select --install`)

## Build & Run

Build and package `dist/MacMessenger.app`:

```bash
./scripts/build-app.sh
open dist/MacMessenger.app
```

To build and copy straight into `/Applications`:

```bash
./scripts/build-app.sh --install
open /Applications/MacMessenger.app
```

> **Note:** Always launch the packaged `.app` bundle (not `swift run`) so macOS enables `UNUserNotificationCenter` notifications and microphone/camera permissions.

## First-Time Setup Notes

1. Sign in with your Facebook account (session cookies persist across launches).
2. If prompted for End-to-End Encrypted chat history, enter your Messenger **Secure Storage PIN**.
3. On your first voice/video call, allow **Microphone** (and **Camera**) access when macOS prompts.
4. For notifications, allow MacMessenger in **System Settings → Notifications** when prompted on launch.

## Project Structure

- `Package.swift` — Swift Package Manager manifest
- `Sources/MacMessenger/MacMessengerApp.swift` — App entry point
- `Sources/MacMessenger/AppDelegate.swift` — Main window, Dock badge, Menu Bar item, menus
- `Sources/MacMessenger/MessengerWebViewController.swift` — `WKWebView`, script bridge, uploads/downloads, link routing
- `Sources/MacMessenger/PopupWindowController.swift` — Secondary window for voice/video call popups + media permissions
- `Sources/MacMessenger/NotificationBridge.swift` — `UNUserNotificationCenter` native notification bridge
- `Sources/MacMessenger/InjectedScripts.swift` — Safari UA, `window.Notification` shim, unread observer, clean-mode CSS
- `Resources/Info.plist` — Bundle metadata and mic/camera usage descriptions
- `scripts/build-app.sh` — Builds, generates `.icns`, packages, and ad-hoc signs `MacMessenger.app`
