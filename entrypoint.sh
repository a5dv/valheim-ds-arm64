#!/usr/bin/env bash
set -e

# Default environment variables
SERVER_NAME="${SERVER_NAME:-My ARM64 Valheim Realm}"
WORLD_NAME="${WORLD_NAME:-Dedicated}"
SERVER_PASS="${SERVER_PASS:-Secret123!}"
SERVER_PORT="${SERVER_PORT:-2456}"
SERVER_PUBLIC="${SERVER_PUBLIC:-1}"
CROSSPLAY="${CROSSPLAY:-0}"
UPDATE_ON_START="${UPDATE_ON_START:-false}"

# World modifiers (difficulty / ruleset). Empty value = Valheim default.
# A preset is applied FIRST; individual -modifier overrides run after it,
# since a later -preset would silently reset any earlier modifiers.
WORLD_PRESET="${WORLD_PRESET:-}"
COMBAT_DIFFICULTY="${COMBAT_DIFFICULTY:-}"
DEATH_PENALTY="${DEATH_PENALTY:-}"
RESOURCES="${RESOURCES:-}"
RAIDS="${RAIDS:-}"
PORTALS="${PORTALS:-}"

BOX64="/usr/local/bin/box64"

echo "=== Starting Valheim ARM64 Container Setup ==="

# 1. Map Unity's hardcoded save directory to the mounted Docker volume
UNITY_SAVE_DIR="/home/steam/.config/unity3d/IronGate/Valheim"
mkdir -p "$(dirname "$UNITY_SAVE_DIR")"
if [ ! -L "$UNITY_SAVE_DIR" ] && [ ! -d "$UNITY_SAVE_DIR" ]; then
    ln -s /config "$UNITY_SAVE_DIR"
fi

# ---------------------------------------------------------------------------
# 2. Update or download Valheim Server via SteamCMD.
#
#    SteamCMD is a 32-bit x86 binary, so we run it under Box64 (Box32 mode).
#    We bypass steamcmd.sh entirely — its self-update replaces the script
#    mid-execution with an ARM-aware version that looks for linuxarm64/.
#
#    Failure mode this logic guards against: when Iron Gate ships a new build,
#    Steam's CDN refuses to serve the OLD depot manifest our install needs for
#    a delta update ("CDepotDownloadMgr::BYldRequestDepotManifest ... Access
#    Denied"), so the download never starts (BytesToDownload=0) and every
#    restart produces "Error! App '896660' state is 0x6 after update job".
#    The current build's manifest is always served, so recovery is a clean
#    reinstall (moving steamapps aside), which Valve's own community fix also
#    recommends.
# ---------------------------------------------------------------------------
VALHEIM_APPID=896660

run_steam_update() {
    local validate="${1:-validate}"
    cd "${STEAMCMDDIR}"
    if [ "${validate}" = "validate" ]; then
        "${BOX64}" ./linux64/steamcmd \
            +@sSteamCmdForcePlatformType linux \
            +force_install_dir "${SERVER_DIR}" \
            +login anonymous \
            +app_update "${VALHEIM_APPID}" validate \
            +quit
    else
        "${BOX64}" ./linux64/steamcmd \
            +@sSteamCmdForcePlatformType linux \
            +force_install_dir "${SERVER_DIR}" \
            +login anonymous \
            +app_update "${VALHEIM_APPID}" \
            +quit
    fi
}

# Up-to-date if buildid matches TargetBuildID in the app manifest.
app_is_current() {
    local acf="${SERVER_DIR}/steamapps/appmanifest_${VALHEIM_APPID}.acf"
    [ -f "${acf}" ] || return 1
    local installed target
    installed="$(awk -F'"' '/^[ \t]*"buildid"/{print $4}' "${acf}")"
    target="$(awk -F'"' '/^[ \t]*"TargetBuildID"/{print $4}' "${acf}")"
    [ -n "${installed}" ] && [ "${installed}" = "${target}" ]
}

update_valheim() {
    local attempts=4 attempt

    # Normal (re)install/update with integrity validation. Multiple attempts
    # absorb the SteamCMD self-update race (the freshly-updated binary can
    # drop the +app_update args) and transient CDN hiccups.
    for attempt in $(seq 1 "${attempts}"); do
        echo "--> SteamCMD update attempt ${attempt}/${attempts}"
        if ! run_steam_update "validate"; then
            echo "    SteamCMD exited non-zero on attempt ${attempt}"
        fi
        if app_is_current; then
            echo "--> Valheim Dedicated Server is up to date."
            return 0
        fi
        echo "    Update still pending (buildid != TargetBuildID); retrying in 5s..."
        sleep 5
    done

    # Persistently blocked -> Steam CDN refusing the old manifest. Move prior
    # install state aside (kept in case we need to roll back) and reinstall the
    # current build from scratch; its manifest is fresh and always served.
    echo "--> Normal update blocked by Steam CDN (old manifest Access Denied)."
    echo "    Reinstalling the current build from scratch..."
    if [ -d "${SERVER_DIR}/steamapps" ] && [ ! -d "${SERVER_DIR}/steamapps.orphaned" ]; then
        mv "${SERVER_DIR}/steamapps" "${SERVER_DIR}/steamapps.orphaned"
    fi

    for attempt in $(seq 1 "${attempts}"); do
        echo "--> Fresh install attempt ${attempt}/${attempts}"
        run_steam_update "validate" || true
        if app_is_current; then
            echo "--> Fresh install succeeded."
            rm -rf "${SERVER_DIR}/steamapps.orphaned"
            return 0
        fi
        sleep 5
    done

    # Full recovery failed: restore the previous install state so the server
    # can still boot on the files it already has.
    if [ ! -d "${SERVER_DIR}/steamapps" ] && [ -d "${SERVER_DIR}/steamapps.orphaned" ]; then
        mv "${SERVER_DIR}/steamapps.orphaned" "${SERVER_DIR}/steamapps"
    fi
    echo "!! WARNING: Valheim update failed after all attempts."
    echo "   Continuing with the existing installation."
    return 1
}

if [ "$UPDATE_ON_START" = "true" ] || [ ! -f "${SERVER_DIR}/valheim_server.x86_64" ]; then
    echo "--> Syncing Valheim Server (AppID ${VALHEIM_APPID}) via SteamCMD..."
    update_valheim || true
fi

# 3. Build launch parameters
export SteamAppId=892970
export LD_LIBRARY_PATH="${SERVER_DIR}/linux64:${LD_LIBRARY_PATH}"

EXTRA_ARGS=""
if [ "$CROSSPLAY" = "1" ] || [ "$CROSSPLAY" = "true" ]; then
    EXTRA_ARGS="-crossplay"
fi

# Build world modifier launch args (-preset first, then -modifier overrides)
WORLD_MODS=""
if [ -n "${WORLD_PRESET}" ]; then
    WORLD_MODS="${WORLD_MODS}-preset ${WORLD_PRESET} "
fi
if [ -n "${COMBAT_DIFFICULTY}" ]; then
    WORLD_MODS="${WORLD_MODS}-modifier combat ${COMBAT_DIFFICULTY} "
fi
if [ -n "${DEATH_PENALTY}" ]; then
    WORLD_MODS="${WORLD_MODS}-modifier deathpenalty ${DEATH_PENALTY} "
fi
if [ -n "${RESOURCES}" ]; then
    WORLD_MODS="${WORLD_MODS}-modifier resources ${RESOURCES} "
fi
if [ -n "${RAIDS}" ]; then
    WORLD_MODS="${WORLD_MODS}-modifier raids ${RAIDS} "
fi
if [ -n "${PORTALS}" ]; then
    WORLD_MODS="${WORLD_MODS}-modifier portals ${PORTALS} "
fi

# Valheim server binary must be executable (SteamCMD may reset permissions)
chmod +x "${SERVER_DIR}/valheim_server.x86_64"

echo "=== Launching Valheim Server via Box64 ==="

# Handle graceful shutdown (forward SIGTERM/SIGINT to Unity process)
trap 'echo "Stopping Valheim server..."; kill -SIGINT "$PID"; wait "$PID"' SIGTERM SIGINT

# Execute the 64-bit Valheim server binary via Box64 in background to capture PID
cd "${SERVER_DIR}"
"$BOX64" ./valheim_server.x86_64 \
    -nographics \
    -batchmode \
    -port "${SERVER_PORT}" \
    -name "${SERVER_NAME}" \
    -world "${WORLD_NAME}" \
    -password "${SERVER_PASS}" \
    -public "${SERVER_PUBLIC}" \
    -savedir "${CONFIG_DIR}" \
    ${EXTRA_ARGS} \
    ${WORLD_MODS} &

PID=$!
wait "$PID"
