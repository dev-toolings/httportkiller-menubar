# PortKiller — macOS Menu Bar Port Killer

> **Instantly find and kill the process listening on any TCP port — right from your macOS menu bar.** Free up `:3000`, `:8080`, `:5432` and fix _"address already in use"_ (`EADDRINUSE`) in one click.

[![CI](https://github.com/MakFly/httportkiller-menubar/actions/workflows/ci.yml/badge.svg)](https://github.com/MakFly/httportkiller-menubar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/MakFly/httportkiller-menubar?sort=semver)](https://github.com/MakFly/httportkiller-menubar/releases/latest)
[![Download DMG](https://img.shields.io/github/downloads/MakFly/httportkiller-menubar/total?label=downloads)](https://github.com/MakFly/httportkiller-menubar/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://www.swift.org)

PortKiller is a tiny, native **macOS menu bar app** for developers who constantly hit
**"port already in use"**. It auto-discovers every listening TCP port on your Mac,
groups them by what they are (web server, database, dev tool, container, system),
and lets you **kill the process behind a port with a single click** — no more
hunting for PIDs with `lsof` and `kill -9`.

<!-- Add a screenshot of the popover at docs/screenshot.png and it will render here -->
<!-- ![PortKiller menu bar popover](docs/screenshot.png) -->

## ✨ Features

- 🔍 **Auto-discovers all listening TCP ports** — refreshed automatically (adaptive interval).
- ⚡ **One-click kill** — graceful `SIGTERM`, then `SIGKILL` if the process holds on; PID + port ownership re-validated before killing.
- 🗂️ **Smart categories** — ports grouped into **Web Server · Database · Development · Container · System**.
- ⭐ **Favorites** — pin the ports you care about (`:3000`, `:5432`…) to the top; persisted across launches.
- 👁️ **Watched ports + native notifications** — get a macOS notification when a watched port opens or closes.
- 🔎 **Search & filter** — by port number, PID, process name, command or user.
- 🌳 **List or tree view** — flat by category, or grouped by process (`⌘T`).
- 💣 **Kill All** — clear every visible port at once (with confirmation).
- 🪶 **Native & lightweight** — pure SwiftUI, `LSUIElement` (no Dock icon), no Electron, ~760 KB.

## 📦 Install

### Download (recommended)

1. Grab the latest **`PortKiller.dmg`** from the [**Releases**](https://github.com/MakFly/httportkiller-menubar/releases/latest) page.
2. Open the DMG and **drag `PortKiller.app` into `Applications`**.
3. Launch it — the `network` icon appears in your menu bar.

> **Gatekeeper note:** the build is ad-hoc signed (not notarized). On first launch
> macOS may say _"PortKiller can't be opened"_. **Right-click the app → Open**, then
> confirm — you only need to do this once. (Or: `System Settings → Privacy & Security → Open Anyway`.)

### Build from source

See [Build from source](#-build-from-source) below.

## 🚀 Usage

Click the menu bar icon to open the popover:

- Click the **✕** next to a port to kill it (with a confirm step).
- Hover a row to reveal **★** (favorite) and **👁** (watch) toggles.
- Right-click a row for a context menu (kill, favorite, watch, and process details).

| Shortcut | Action           |
| -------- | ---------------- |
| `⌘R`     | Refresh          |
| `⌘T`     | Toggle list/tree |
| `⌘K`     | Kill all         |
| `⌘Q`     | Quit             |

## 🛠 Build from source

Requirements: **macOS 15+** and **Swift 6 / Xcode 16**.

```sh
git clone https://github.com/MakFly/httportkiller-menubar.git
cd httportkiller-menubar

swift test            # run the test suite
swift build -c release

# Package a signed .app and a drag-to-Applications DMG
Scripts/package_app.sh
Scripts/make_dmg.sh         # -> dist/PortKiller.dmg

open ".build/release/PortKiller.app"
```

## 🔬 How it works

PortKiller shells out to `lsof -iTCP -sTCP:LISTEN -P -n +c 0` to enumerate every
TCP listener, enriches each row with the process command line, and renders them in
a native `MenuBarExtra` popover. Killing a port re-validates that the PID still
owns the port, sends `SIGTERM`, waits, and escalates to `SIGKILL` only if needed —
so you never nuke the wrong process.

## ❓ FAQ

**"Error: listen EADDRINUSE: address already in use :::3000"** — a stale dev server
is still holding the port. Open PortKiller, find `:3000`, click ✕. Done.

**Does it need admin rights?** No. It can only kill processes owned by your user.

**Does it phone home?** No network access, no telemetry. Everything is local.

## 🙏 Attribution

This project adapts design and implementation ideas from
[`productdevbook/port-killer`](https://github.com/productdevbook/port-killer) (MIT).
See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## 📄 License

[MIT](LICENSE) © 2026 MakFly
