# Jiji

Jiji is a macOS menu bar app featuring a Jiji cat icon that reacts to your current-session usage percentage on [claude.ai](https://claude.ai). Glance at the menu bar to see whether your session is chill, alert, side-eyeing, worried, panicking, or done.

## Requirements

- macOS 13 or newer (uses the `MenuBarExtra` API)
- Swift 5.9 toolchain

If you do not already have the Swift toolchain installed, install the Xcode Command Line Tools:

```sh
xcode-select --install
```

## Run

From the project root:

```sh
./build-app.sh
open Jiji.app
```

`./build-app.sh` runs `swift build -c release`, wraps the binary into a proper `Jiji.app` bundle (with `Info.plist`), and ad-hoc code-signs it. The bundle is required because `WKWebView`'s WebContent process needs a real bundle ID + ATS config to render claude.ai — `swift run` alone produces a blank-white login window.

The app lives in the menu bar. On first launch, a small login window opens pointed at `https://claude.ai/login`. Sign in there once and Jiji will start polling your usage page in the background.

> **Sign in with email, not Google.** The "Continue with Google" button is not supported in this version: Google sign-in opens a popup window to `accounts.google.com`, and Jiji's embedded WKWebView intentionally restricts navigation to `claude.ai` hosts only and does not handle popup windows. Use the "Enter your email" option on the login page instead.

Cookies are stored locally inside the app's sandbox via `WKWebsiteDataStore.default()`. They never leave your machine.

## How it works

Jiji loads `https://claude.ai/settings/usage` in a hidden `WKWebView` once a minute, reads the "Current session" row from the rendered DOM, and parses out the percentage plus any "Resets in ..." text. The menu bar icon (an SF Symbol) changes based on the percent bucket.

## Caveat

Jiji scrapes the rendered DOM of the claude.ai usage page. If Anthropic changes the structure of that page, the DOM-reading script will need to be updated.
