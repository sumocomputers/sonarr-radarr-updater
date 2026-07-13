# Sonarr / Radarr Updater (macOS, Apple Silicon)

**This is compatible only with Apple Silicon (M series) Macs. It will not
work on Intel-based Macs** — the update script only looks for `osx-arm64`
builds, and the app is compiled as an arm64-only binary.

Sonarr and Radarr's macOS builds aren't notarized, so their built-in
auto-updater doesn't work on Apple Silicon Macs — every update has to be
downloaded, dropped into `/Applications`, and re-signed by hand. This
project automates that.

It checks GitHub Releases for the latest Apple Silicon build of each app,
compares it against the version currently running (via each app's own
local API), and if there's a newer one:

1. Shuts the app down cleanly (falls back to a force-kill)
2. Downloads the `osx-arm64` build from GitHub
3. Replaces `/Applications/Sonarr.app` or `/Applications/Radarr.app`
4. Ad-hoc code-signs it and clears the quarantine flag
5. Relaunches it

If both apps are already up to date, it says so and exits — no download,
no restart.

## What this can't automate

The first time you use **Add New** after an update, macOS will ask you to
approve folder/volume access again. That's a live TCC permission dialog
tied to user interaction in the app's UI, not something a script can
pre-approve without editing the SIP-protected TCC database — so you'll
still need to click **Allow** once per update.

## Requirements

- Apple Silicon Mac
- Sonarr and/or Radarr installed in `/Applications`
- Standard config file locations, used to read each app's API key (and,
  unless overridden, its port):
  - Sonarr: `~/.config/Sonarr/config.xml`
  - Radarr: `~/Library/Application Support/Radarr/config.xml`
- Assumes you're on the stable release branch (`main` for Sonarr, `master`
  for Radarr) — not `develop`/`nightly`

## Usage

### Command line

```
./update-sonarr-radarr.sh
```

Logs to `logs/update-sonarr-radarr.log` next to the script.

By default it talks to each app at `http://localhost:<port>`, reading the
port from `config.xml`. To point at a different port or host, set
`SONARR_URL` and/or `RADARR_URL`:

```
SONARR_URL=http://localhost:8990 ./update-sonarr-radarr.sh
```

### macOS app

`Sonarr-Radarr-Updater.app` is a small native SwiftUI wrapper that runs
the script and streams its output live in a window. Double-click it, or
rebuild it yourself:

```
./build.sh
```

It has Sonarr URL / Radarr URL fields at the top — leave them blank to
auto-detect from `config.xml` (the field shows what was actually
detected once a check completes), or type a URL to override it. Changes
take effect the next time you click **Run Again**, and are remembered
across launches.

The app looks for `update-sonarr-radarr.sh` next to itself first, falling
back to a copy bundled inside `Contents/Resources` — so either keep the
two files together, or just copy the built `.app` on its own; it's fully
self-contained.

**First launch after downloading:** this is ad-hoc signed, not notarized
with a paid Apple Developer ID, so macOS will refuse to open it the first
time. On a fresh download you'll see:

> "Sonarr-Radarr-Updater" is damaged and can't be opened. You should move
> it to the Trash.

Despite the wording, it isn't actually damaged — this is just Gatekeeper's
generic message for any unnotarized app downloaded from the internet. Fix
it once per Mac, running this from a Terminal in the same directory as
the `.app` file: `xattr -rd com.apple.quarantine "Sonarr-Radarr-Updater.app"`

Then double-click normally. This is the same reason Sonarr/Radarr
themselves need the `codesign`/`xattr` treatment this tool automates.

## Turning off Sonarr/Radarr's built-in updater

Since the built-in updater is broken on Apple Silicon anyway, it's worth
telling each app that updates are externally managed, so it stops
offering an "Install now" that won't work:

```
curl -s -H "X-Api-Key: YOUR_API_KEY" "http://localhost:PORT/api/v3/config/host" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d["updateMechanism"]="external"; d["updateAutomatically"]=False; print(json.dumps(d))' \
  | curl -s -X PUT -H "X-Api-Key: YOUR_API_KEY" -H "Content-Type: application/json" \
      -d @- "http://localhost:PORT/api/v3/config/host/1"
```

Find your API key and port in the app's `config.xml` (same paths as
above), or in Settings → General in the web UI.

## Scheduling

Run `update-sonarr-radarr.sh` on whatever cadence you like via a `launchd`
LaunchAgent or `cron`. It's safe to run as often as you want — it's a
no-op when there's nothing new.

## License

MIT — see [LICENSE](LICENSE).
