#!/bin/zsh
#
# Checks Sonarr and Radarr for newer Apple Silicon builds and, if found,
# quits the app, downloads + installs the update, self-signs it, and
# relaunches it. If already up to date, logs that and exits 0.
#
# The base URL used to reach each app's local API can be overridden with
# the SONARR_URL / RADARR_URL environment variables (e.g.
# "http://localhost:8989"). If unset, it's derived from the <Port> in the
# app's own config.xml, same as before. The API key is always read from
# config.xml regardless of URL override, since it isn't part of the URL.
#
# NOTE: this does not (and cannot) handle the "Allow access to this
# volume?" prompt that macOS shows the first time the freshly-signed app
# touches a folder in the UI (e.g. Add New -> root folder picker). That's
# a live TCC permission dialog tied to user interaction in the app, not
# something a script can pre-approve without editing the protected TCC
# database. Click Allow when it appears after an update.

set -u

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/update-sonarr-radarr.log"
mkdir -p "$LOG_DIR"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() {
    print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

update_app() {
    local app_name="$1"       # Sonarr | Radarr
    local repo="$2"           # e.g. Sonarr/Sonarr
    local config_path="$3"    # path to config.xml
    local asset_regex="$4"    # regex matching the macOS arm64 .zip asset name
    local url_override="$5"   # optional base URL, e.g. http://localhost:8989

    log "== $app_name: checking =="

    if [[ ! -f "$config_path" ]]; then
        log "$app_name: config.xml not found at '$config_path' - skipping"
        return
    fi

    local api_key port
    api_key=$(sed -nE 's/.*<ApiKey>([^<]+)<\/ApiKey>.*/\1/p' "$config_path")
    port=$(sed -nE 's/.*<Port>([^<]+)<\/Port>.*/\1/p' "$config_path")

    if [[ -z "$api_key" ]]; then
        log "$app_name: could not read ApiKey from config.xml - skipping"
        return
    fi

    local base_url
    if [[ -n "$url_override" ]]; then
        base_url="${url_override%/}"
    elif [[ -n "$port" ]]; then
        base_url="http://localhost:${port}"
    else
        log "$app_name: no URL override set and could not read Port from config.xml - skipping"
        return
    fi

    log "$app_name: using $base_url"

    local current_version
    current_version=$(curl -fsS --max-time 10 -H "X-Api-Key: $api_key" \
        "${base_url}/api/v3/system/status" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)

    if [[ -z "$current_version" ]]; then
        log "$app_name: could not read current version from $base_url (is it running, and is the URL correct?) - skipping"
        return
    fi

    local release_json
    release_json=$(curl -fsS --max-time 20 "https://api.github.com/repos/${repo}/releases/latest")
    if [[ -z "$release_json" ]]; then
        log "$app_name: could not reach GitHub releases API - skipping"
        return
    fi

    local latest_version download_url
    latest_version=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' <<< "$release_json" 2>/dev/null)
    download_url=$(python3 -c "
import json, re, sys
data = json.load(sys.stdin)
pattern = re.compile(r'$asset_regex')
for a in data.get('assets', []):
    if pattern.search(a['name']):
        print(a['browser_download_url'])
        break
" <<< "$release_json" 2>/dev/null)

    if [[ -z "$latest_version" ]]; then
        log "$app_name: could not determine latest version from GitHub response - skipping"
        return
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        log "$app_name: up to date ($current_version) - no action taken"
        return
    fi

    if [[ -z "$download_url" ]]; then
        log "$app_name: new version $latest_version is available (currently $current_version) but no matching macOS Apple Silicon asset was found - skipping"
        return
    fi

    log "$app_name: update available: $current_version -> $latest_version"

    # 1. Quit the app (clean shutdown via its own API, then force-kill as fallback)
    curl -fsS --max-time 10 -X POST -H "X-Api-Key: $api_key" \
        "${base_url}/api/v3/system/shutdown" >/dev/null 2>&1
    sleep 4
    pkill -9 -x "$app_name" >/dev/null 2>&1
    sleep 1

    # 2. Download the Apple Silicon build
    local zip_path="$WORKDIR/${app_name}.zip"
    if ! curl -fsSL --max-time 300 -o "$zip_path" "$download_url"; then
        log "$app_name: download failed from $download_url - aborting this app's update"
        return
    fi

    # 3. Extract
    local extract_dir="$WORKDIR/${app_name}-extract"
    mkdir -p "$extract_dir"
    if ! ditto -xk "$zip_path" "$extract_dir" 2>>"$LOG_FILE"; then
        log "$app_name: failed to extract downloaded archive - aborting this app's update"
        return
    fi

    local new_app="$extract_dir/${app_name}.app"
    if [[ ! -d "$new_app" ]]; then
        log "$app_name: extracted archive did not contain ${app_name}.app - aborting this app's update"
        return
    fi

    # 4. Replace the installed app
    if ! rm -rf "/Applications/${app_name}.app"; then
        log "$app_name: could not remove old /Applications/${app_name}.app - aborting this app's update"
        return
    fi
    if ! mv "$new_app" "/Applications/${app_name}.app"; then
        log "$app_name: could not move new build into /Applications - aborting this app's update"
        return
    fi

    # 5. Self-sign and clear quarantine
    codesign --force --deep -s - "/Applications/${app_name}.app" 2>>"$LOG_FILE"
    xattr -rd com.apple.quarantine "/Applications/${app_name}.app" 2>>"$LOG_FILE"

    # 6. Relaunch
    open -a "/Applications/${app_name}.app"

    log "$app_name: updated to $latest_version and relaunched. NOTE: you may need to click 'Allow' on a volume-access prompt the next time you use Add New in the UI."
}

update_app "Sonarr" "Sonarr/Sonarr" "$HOME/.config/Sonarr/config.xml" 'osx-arm64-app\.zip$' "${SONARR_URL:-}"
update_app "Radarr" "Radarr/Radarr" "$HOME/Library/Application Support/Radarr/config.xml" 'osx-app-core-arm64\.zip$' "${RADARR_URL:-}"

log "== Done =="
