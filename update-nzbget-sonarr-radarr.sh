#!/bin/zsh
#
# Checks NZBGet, Sonarr, and Radarr for newer stable builds and, if found,
# quits the app, downloads + installs the update, and relaunches it. If
# already up to date, logs that and exits 0.
#
# Sonarr/Radarr: the base URL used to reach each app's local API can be
# overridden with the SONARR_URL / RADARR_URL environment variables (e.g.
# "http://localhost:8989"). If unset, it's derived from the <Port> in the
# app's own config.xml, same as before. The API key is always read from
# config.xml regardless of URL override, since it isn't part of the URL.
# Sonarr/Radarr macOS builds aren't notarized, so they're ad-hoc
# self-signed and de-quarantined after each update.
#
# NZBGet: same URL-override idea via NZBGET_URL, derived by default from
# ControlPort in nzbget.conf. NZBGet's official macOS build is Developer
# ID signed and notarized, so it is copied in as-is - no re-signing.
#
# NOTE: this does not (and cannot) handle the "Allow access to this
# volume?" prompt that macOS shows the first time a freshly re-signed app
# (Sonarr/Radarr) touches a folder in the UI (e.g. Add New -> root folder
# picker). That's a live TCC permission dialog tied to user interaction
# in the app, not something a script can pre-approve without editing the
# protected TCC database. Click Allow when it appears after an update.

set -u

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/update-nzbget-sonarr-radarr.log"
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

    log "$app_name: Checking for updates..."

    if [[ ! -d "/Applications/${app_name}.app" ]]; then
        log "$app_name: Not installed (/Applications/${app_name}.app not found) - Skipping"
        return
    fi

    if [[ ! -f "$config_path" ]]; then
        log "$app_name: Config.xml not found at '$config_path' - Skipping"
        return
    fi

    local api_key port
    api_key=$(sed -nE 's/.*<ApiKey>([^<]+)<\/ApiKey>.*/\1/p' "$config_path")
    port=$(sed -nE 's/.*<Port>([^<]+)<\/Port>.*/\1/p' "$config_path")

    if [[ -z "$api_key" ]]; then
        log "$app_name: Could not read ApiKey from config.xml - Skipping"
        return
    fi

    local base_url
    if [[ -n "$url_override" ]]; then
        base_url="${url_override%/}"
    elif [[ -n "$port" ]]; then
        base_url="http://localhost:${port}"
    else
        log "$app_name: No URL override set and could not read Port from config.xml - Skipping"
        return
    fi

    log "$app_name: Using $base_url"

    local current_version
    current_version=$(curl -fsS --max-time 10 -H "X-Api-Key: $api_key" \
        "${base_url}/api/v3/system/status" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)

    if [[ -z "$current_version" ]]; then
        log "$app_name: Could not read current version from $base_url (is it running, and is the URL correct?) - Skipping"
        return
    fi

    local release_json
    release_json=$(curl -fsS --max-time 20 "https://api.github.com/repos/${repo}/releases/latest")
    if [[ -z "$release_json" ]]; then
        log "$app_name: Could not reach GitHub releases API - Skipping"
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
        log "$app_name: Could not determine latest version from GitHub response - Skipping"
        return
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        log "$app_name: Up to date ($current_version) - No update available. No action taken."
        return
    fi

    if [[ -z "$download_url" ]]; then
        log "$app_name: New version $latest_version is available (currently $current_version) but no matching macOS Apple Silicon asset was found - Skipping"
        return
    fi

    log "$app_name: Update available: $current_version -> $latest_version"

    # 1. Quit the app (clean shutdown via its own API, then force-kill as fallback)
    curl -fsS --max-time 10 -X POST -H "X-Api-Key: $api_key" \
        "${base_url}/api/v3/system/shutdown" >/dev/null 2>&1
    sleep 4
    pkill -9 -x "$app_name" >/dev/null 2>&1
    sleep 1

    # 2. Download the Apple Silicon build
    local zip_path="$WORKDIR/${app_name}.zip"
    if ! curl -fsSL --max-time 300 -o "$zip_path" "$download_url"; then
        log "$app_name: Download failed from $download_url - Aborting this app's update"
        return
    fi

    # 3. Extract
    local extract_dir="$WORKDIR/${app_name}-extract"
    mkdir -p "$extract_dir"
    if ! ditto -xk "$zip_path" "$extract_dir" 2>>"$LOG_FILE"; then
        log "$app_name: Failed to extract downloaded archive - Aborting this app's update"
        return
    fi

    local new_app="$extract_dir/${app_name}.app"
    if [[ ! -d "$new_app" ]]; then
        log "$app_name: Extracted archive did not contain ${app_name}.app - Aborting this app's update"
        return
    fi

    # 4. Replace the installed app
    if ! rm -rf "/Applications/${app_name}.app"; then
        log "$app_name: Could not remove old /Applications/${app_name}.app - Aborting this app's update"
        return
    fi
    if ! mv "$new_app" "/Applications/${app_name}.app"; then
        log "$app_name: Could not move new build into /Applications - Aborting this app's update"
        return
    fi

    # 5. Self-sign and clear quarantine
    codesign --force --deep -s - "/Applications/${app_name}.app" 2>>"$LOG_FILE"
    xattr -rd com.apple.quarantine "/Applications/${app_name}.app" 2>>"$LOG_FILE"

    # 6. Relaunch
    open -a "/Applications/${app_name}.app"

    log "$app_name: Updated to $latest_version and relaunched. NOTE: You may need to click 'Allow' on a volume-access prompt the next time you use Add New in the UI."
}

update_nzbget() {
    local url_override="$1"   # optional base URL, e.g. http://localhost:6789

    local repo="nzbgetcom/nzbget"
    local config_path="$HOME/Library/Application Support/NZBGet/nzbget.conf"
    local asset_regex='-universal\.dmg$'

    log "NZBGet: Checking for updates..."

    if [[ ! -d "/Applications/NZBGet.app" ]]; then
        log "NZBGet: Not installed (/Applications/NZBGet.app not found) - Skipping"
        return
    fi

    if [[ ! -f "$config_path" ]]; then
        log "NZBGet: nzbget.conf not found at '$config_path' - Skipping"
        return
    fi

    local control_port control_user control_pass
    control_port=$(sed -nE 's/^ControlPort=(.*)$/\1/p' "$config_path")
    control_user=$(sed -nE 's/^ControlUsername=(.*)$/\1/p' "$config_path")
    control_pass=$(sed -nE 's/^ControlPassword=(.*)$/\1/p' "$config_path")

    local base_url
    if [[ -n "$url_override" ]]; then
        base_url="${url_override%/}"
    elif [[ -n "$control_port" ]]; then
        base_url="http://localhost:${control_port}"
    else
        log "NZBGet: No URL override set and could not read ControlPort from nzbget.conf - Skipping"
        return
    fi

    log "NZBGet: Using $base_url"

    local curl_auth=()
    if [[ -n "$control_user" || -n "$control_pass" ]]; then
        curl_auth=(-u "${control_user}:${control_pass}")
    fi

    local current_version
    current_version=$(curl -fsS --max-time 10 "${curl_auth[@]}" "${base_url}/jsonrpc/version" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])' 2>/dev/null)

    if [[ -z "$current_version" ]]; then
        log "NZBGet: Could not read current version from $base_url (is it running, and is the URL correct?) - Skipping"
        return
    fi

    local release_json
    release_json=$(curl -fsS --max-time 20 "https://api.github.com/repos/${repo}/releases/latest")
    if [[ -z "$release_json" ]]; then
        log "NZBGet: Could not reach GitHub releases API - Skipping"
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
        log "NZBGet: Could not determine latest version from GitHub response - Skipping"
        return
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        log "NZBGet: Up to date ($current_version) - No update available. No action taken."
        return
    fi

    if [[ -z "$download_url" ]]; then
        log "NZBGet: New version $latest_version is available (currently $current_version) but no matching macOS universal asset was found - Skipping"
        return
    fi

    log "NZBGet: Update available: $current_version -> $latest_version"

    # 1. Quit the app (clean shutdown via its own API, then force-kill as fallback).
    #    NZBGet runs as two processes on macOS: the tray app and a separate daemon.
    curl -fsS --max-time 10 "${curl_auth[@]}" "${base_url}/jsonrpc/shutdown" >/dev/null 2>&1
    sleep 4
    pkill -9 -x "NZBGet" >/dev/null 2>&1
    pkill -9 -x "nzbget" >/dev/null 2>&1
    sleep 1

    # 2. Download the universal (Intel/Apple Silicon) build
    local dmg_path="$WORKDIR/NZBGet.dmg"
    if ! curl -fsSL --max-time 300 -o "$dmg_path" "$download_url"; then
        log "NZBGet: Download failed from $download_url - Aborting this app's update"
        return
    fi

    # 3. Mount the disk image
    local mount_point="$WORKDIR/NZBGet-mount"
    mkdir -p "$mount_point"
    if ! hdiutil attach "$dmg_path" -nobrowse -quiet -mountpoint "$mount_point"; then
        log "NZBGet: Failed to mount downloaded disk image - Aborting this app's update"
        return
    fi

    local new_app="$mount_point/NZBGet.app"
    if [[ ! -d "$new_app" ]]; then
        log "NZBGet: Disk image did not contain NZBGet.app - Aborting this app's update"
        hdiutil detach "$mount_point" -quiet >/dev/null 2>&1
        return
    fi

    # 4. Replace the installed app. ditto (not mv) so the original Developer
    #    ID signature and notarization ticket are copied over intact.
    if ! rm -rf "/Applications/NZBGet.app"; then
        log "NZBGet: Could not remove old /Applications/NZBGet.app - Aborting this app's update"
        hdiutil detach "$mount_point" -quiet >/dev/null 2>&1
        return
    fi
    if ! ditto "$new_app" "/Applications/NZBGet.app"; then
        log "NZBGet: Could not copy new build into /Applications - Aborting this app's update"
        hdiutil detach "$mount_point" -quiet >/dev/null 2>&1
        return
    fi

    # 5. Unmount the disk image
    hdiutil detach "$mount_point" -quiet >/dev/null 2>&1

    # 6. Relaunch. No re-signing step - NZBGet's official build is already
    #    Developer ID signed and notarized.
    open -a "/Applications/NZBGet.app"

    log "NZBGet: Updated to $latest_version and relaunched."
}

update_nzbget "${NZBGET_URL:-}"
update_app "Sonarr" "Sonarr/Sonarr" "$HOME/.config/Sonarr/config.xml" 'osx-arm64-app\.zip$' "${SONARR_URL:-}"
update_app "Radarr" "Radarr/Radarr" "$HOME/Library/Application Support/Radarr/config.xml" 'osx-app-core-arm64\.zip$' "${RADARR_URL:-}"

log "Done"
