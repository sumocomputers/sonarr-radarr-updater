# NZBGet / Sonarr / Radarr Updater (macOS, Apple Silicon)

**Note on how this app was created**

I am not a developer, but I have a few Apple Silicon Macs that run Sonarr & Radarr natively (not in Docker).

Since the built-in updater of Sonarr & Radarr was broken on Apple Silicon Macs, I was tired of the tedious process involved in updating to the latest version. If you do this regularly, you know the annoyances.

I used Claude Code to create a script that also has a simple SwiftUI app so I could more easily update to the latest versions with less hassle. I have been happy with how the app works, but if you run into issues feel free to post them in Github issues. I can't guarantee I can fix them, but it would be good to have any problems documented.

<img width="1012" height="644" alt="app-01" src="https://github.com/user-attachments/assets/23330cfe-e50d-4b7a-bdb3-9bb854905615" />


**This is compatible only with Apple Silicon (M series) Macs. It will not
work on Intel-based Macs** — the Sonarr/Radarr half of the update script
only looks for `osx-arm64` builds, and the app is compiled as an
arm64-only binary.

Sonarr and Radarr's macOS builds aren't notarized, so their built-in
auto-updater doesn't work on Apple Silicon Macs — every update has to be
downloaded, dropped into `/Applications`, and re-signed by hand. NZBGet
doesn't have that problem (its official build is properly Developer ID
signed and notarized), but updating it still means force-quitting it,
downloading the new build, mounting the disk image, and swapping it into
`/Applications` by hand. This project automates all three.

It checks each app's latest **stable** release, compares it against the
version currently running (via each app's own local API), and if there's
a newer one, quits the app, installs the update, and relaunches it. If
everything is already up to date, it says so and exits — no download, no
restart.

| | Source | Asset | Re-signed after install? |
|---|---|---|---|
| NZBGet | [nzbgetcom/nzbget](https://github.com/nzbgetcom/nzbget) releases | `*-universal.dmg` (Intel + Apple Silicon) | No — already Developer ID signed & notarized |
| Sonarr | [Sonarr/Sonarr](https://github.com/Sonarr/Sonarr) releases | `*-osx-arm64-app.zip` | Yes — ad-hoc signed, quarantine cleared |
| Radarr | [Radarr/Radarr](https://github.com/Radarr/Radarr) releases | `*-osx-app-core-arm64.zip` | Yes — ad-hoc signed, quarantine cleared |

## What this can't automate

The first time you use **Add New** in Sonarr/Radarr after an update,
macOS will ask you to approve folder/volume access again. That's a live
TCC permission dialog tied to user interaction in the app's UI, not
something a script can pre-approve without editing the SIP-protected TCC
database — so you'll still need to click **Allow** once per update. This
doesn't apply to NZBGet, since its signature (and the TCC grants tied to
it) doesn't change on update.

The easiest way to do this is open Sonarr and/or Radarr normally and select "Add New", even if you don't have any shows or movies to add. This will result in macOS prompt(s) for any new disk permissions needed, since the OS thinks the Sonarr and/or Radarr app are new.

## Requirements

- Apple Silicon Mac (M Series)
- NZBGet, Sonarr, and/or Radarr installed in `/Applications` (any subset
  is fine — anything not installed is skipped with a log message)
- Sonarr and/or Radarr using http (https might work, but was not tested)
- Standard config file locations, used to read each app's control
  credentials (and, unless overridden, its port):
  - NZBGet: `~/Library/Application Support/NZBGet/nzbget.conf`
  - Sonarr: `~/.config/Sonarr/config.xml`
  - Radarr: `~/Library/Application Support/Radarr/config.xml`
- Assumes you're on each app's stable release channel (NZBGet's GitHub
  "latest" release, `main` for Sonarr, `master` for Radarr) — not a
  testing/nightly/develop build

## Usage

### Command line

```
./update-nzbget-sonarr-radarr.sh
```

Logs to `logs/update-nzbget-sonarr-radarr.log` next to the script.

By default it talks to each app at `http://localhost:<port>`, reading the
port from its config file. To point at a different port or host, set
`NZBGET_URL`, `SONARR_URL`, and/or `RADARR_URL`:

```
NZBGET_URL=http://localhost:6790 ./update-nzbget-sonarr-radarr.sh
```

### macOS app

`NZBGet-Sonarr-Radarr-Updater.app` is a small native SwiftUI wrapper that
runs the script and streams its output live in a window. Double-click
it, or rebuild it yourself:

```
./build.sh
```

It has NZBGet URL / Sonarr URL / Radarr URL fields at the top — leave
them blank to auto-detect from each app's config file (the field shows
what was actually detected once a check completes), or type a URL to
override it. Changes take effect the next time you click **Run Again**,
and are remembered across launches.

The app looks for `update-nzbget-sonarr-radarr.sh` next to itself first,
falling back to a copy bundled inside `Contents/Resources` — so either
keep the two files together, or just copy the built `.app` on its own;
it's fully self-contained.

**First launch after downloading:** this app itself (not NZBGet/Sonarr/
Radarr) is ad-hoc signed, not notarized with a paid Apple Developer ID,
so macOS will refuse to open it the first time. On a fresh download
you'll see:

> "NZBGet-Sonarr-Radarr-Updater" is damaged and can't be opened. You
> should move it to the Trash.

Despite the wording, it isn't actually damaged — this is just Gatekeeper's
generic message for any unnotarized app downloaded from the internet. Fix
it once per Mac, running this from a Terminal in the same directory as
the `.app` file: `xattr -rd com.apple.quarantine "NZBGet-Sonarr-Radarr-Updater.app"`

Then double-click normally. This is the same reason Sonarr/Radarr
themselves need the `codesign`/`xattr` treatment this tool automates for
them.

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
above), or in Settings → General in the web UI. NZBGet doesn't need this
— its own auto-update mechanism can be left alone or used as normal.

## Scheduling

Run `update-nzbget-sonarr-radarr.sh` on whatever cadence you like via a
`launchd` LaunchAgent or `cron`. It's safe to run as often as you want —
it's a no-op when there's nothing new.

## License

MIT — see [LICENSE](LICENSE).
