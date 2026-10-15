#!/usr/bin/env bash
set -e

# Docker ENTRYPOINT (runs as root) -> fixes volume ownership -> drops to the
# steam user -> execs the real server entrypoint.

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Additional persistent mounts owned by the steam user.
STEAM_CMD="${STEAMCMDDIR:-/home/steam/steamcmd}"
STEAM_HOME="${HOMEDIR:-/home/steam}"
STEAMCMD_PRISTINE="${STEAMCMD_PRISTINE:-/opt/steamcmd}"

# Create the steam group/user at the desired IDs first so any seeded files get
# the right ownership immediately.
echo "=== Fixing volume ownership (PUID=${PUID} PGID=${PGID}) ==="
groupmod -o -g "${PGID}" steam || groupadd -g "${PGID}" steam
usermod -o -u "${PUID}" -g "${PGID}" steam || useradd -u "${PUID}" -g "${PGID}" -m steam

# Seed persistent SteamCMD / Steam config dirs on first boot of a fresh host.
# Bind-mounting an empty dir hides the copies baked into the image, so restore
# them here before the steam user touches them.
if [ -d "${STEAMCMD_PRISTINE}" ] && [ ! -x "${STEAM_CMD}/linux64/steamcmd" ]; then
    echo "--> Seeding empty STEAMCMDDIR (${STEAM_CMD}) from ${STEAMCMD_PRISTINE}"
    mkdir -p "${STEAM_CMD}"
    cp -a "${STEAMCMD_PRISTINE}/." "${STEAM_CMD}/"
fi
if [ ! -e "${STEAM_HOME}/.steam/sdk64/steamclient.so" ]; then
    echo "--> Recreating steamclient.so link in ${STEAM_HOME}/.steam/sdk64"
    mkdir -p "${STEAM_HOME}/.steam/sdk64"
    ln -sfn "${STEAM_CMD}/linux64/steamclient.so" "${STEAM_HOME}/.steam/sdk64/steamclient.so"
fi

# Directories that need to be writable by the steam user.
# Bind mounts override image ownership at runtime, so we match their owner.
WRITE_DIRS=(
    "${SERVER_DIR:-/home/steam/valheim}"
    "${CONFIG_DIR:-/config}"
    "${STEAM_CMD}"
    "${STEAM_HOME}/Steam"
    "${STEAM_HOME}/.steam"
)

for d in "${WRITE_DIRS[@]}"; do
    mkdir -p "${d}"
    chown -R "${PUID}:${PGID}" "${d}"
done

echo "=== Dropping privileges to 'steam' and starting server ==="

# Run the real entrypoint as the unprivileged user, preserving signals.
exec gosu steam /usr/local/bin/entrypoint.sh