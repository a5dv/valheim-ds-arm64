#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Valheim World Reset
#
# Stops the server, preserves the current world as a backup, and boots a
# fresh world. The old world is MOVED to a timestamped backup folder, never
# deleted outright, so you can restore it if needed.
#
# Run as ubuntu (docker-group member):
#   ./reset-world.sh
#
# NOTE: config/ is owned by opc (uid 1000) because the container chowns
# the volume to PUID:PGID (default 1000:1000) on every start. docker
# commands run as the invoking user, but renaming the world folder is done
# as 'opc' so the backup step has write permission.
# ============================================================================

# Run a command as 'opc' (owner of config/). From root we act directly.
run_as_opc() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -u opc "$@"
    fi
}

WORLD_NAME="Valhalla"                       # must match WORLD_NAME in compose.yaml
COMPOSE_DIR="/home/ubuntu/server-files/valheim-arm64"
WORLD_DIR="${COMPOSE_DIR}/config/worlds_local/${WORLD_NAME}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${COMPOSE_DIR}/config/worlds_local/${WORLD_NAME}_backup_manual-${TIMESTAMP}"

echo "=== Valheim World Reset ==="
echo "World: ${WORLD_NAME}"
echo

# 1. Stop the server gracefully.
#    docker compose stop honors stop_grace_period (60s) so the current
#    world gets saved before the container is killed.
echo "[1/3] Stopping Valheim server..."
cd "${COMPOSE_DIR}"
docker compose stop

# 2. Preserve the old world as a backup (move, don't delete).
#    Runs as 'opc', who owns config/ and can rename the world folder.
#    Admin/banned lists and prefs live outside worlds_local and are kept.
if [ -d "${WORLD_DIR}" ]; then
    echo "[2/3] Backing up old world to:"
    echo "      ${BACKUP_DIR}"
    run_as_opc mv "${WORLD_DIR}" "${BACKUP_DIR}"
else
    echo "[2/3] No existing world found (${WORLD_DIR}) - skipping backup."
fi

# 3. Start the server - it generates a brand-new world on boot.
echo "[3/3] Starting Valheim server..."
cd "${COMPOSE_DIR}"
docker compose up -d

echo
echo "Done. A fresh world will be created on next boot."
echo "Old world backup: ${BACKUP_DIR}"