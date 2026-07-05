# WARP Monitor

WARP Monitor is a small pure-AppKit macOS utility that watches Cloudflare WARP,
Shadowrocket, and the current Cloudflare colo. It targets the NRT colo and can
run the existing recovery flow when WARP disconnects or drifts to another colo.

The app is packaged as a standard macOS `.app` bundle with a Dock icon, menu bar
status item, and no external Swift dependencies.

## Requirements

- macOS 13 or newer
- Xcode command line tools with SwiftPM
- `warp-cli` available on `PATH`
- Shadowrocket installed if you want the recovery toggle flow to work

## Build Locally

Build the release executable:

```sh
swift build -c release
```

Build the macOS app bundle:

```sh
Scripts/build_app.sh
```

The app bundle is written to:

```text
dist/WARP Monitor.app
```

Launch it locally:

```sh
open "dist/WARP Monitor.app"
```

## Create a DMG

```sh
Scripts/create_dmg.sh
```

The DMG is written to:

```text
dist/WARP-Monitor.dmg
```

## Icon Previews

The executable can export quick PNG previews of the Dock and menu bar icons:

```sh
.build/release/WarpMonitor --dump-icons /tmp/warp-monitor-icons
```

`Scripts/build_app.sh` uses the same icon drawing code to generate the app
bundle icon, so the packaged Dock icon stays in sync with the source.

## GitHub Actions

`.github/workflows/build.yml` builds on macOS for push, pull request, and manual
workflow dispatch. It uploads `dist/WARP-Monitor.dmg` as a workflow artifact.

The generated app is unsigned. For public releases, sign and notarize the app
before distributing it outside trusted local workflows.
