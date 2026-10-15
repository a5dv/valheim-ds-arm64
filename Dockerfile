FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PUID=1000 \
    USER=steam \
    HOMEDIR="/home/steam" \
    STEAMCMDDIR="/home/steam/steamcmd" \
    SERVER_DIR="/home/steam/valheim" \
    CONFIG_DIR="/config" \
    BOX64_LOG=0

# Install Box64/Box32 tooling and minimal 32-bit ARM (armhf) libraries.
# SteamCMD is a 32-bit binary and needs armhf runtimes under Box64.
RUN dpkg --add-architecture armhf \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg locales \
        libc6:armhf libstdc++6:armhf libncurses5:armhf \
        libsdl2-2.0-0 libpulse-mainloop-glib0 libatomic1 \
    && wget -qO- https://ryanfortner.github.io/box64-debs/box64.list -O /etc/apt/sources.list.d/box64.list \
    && wget -qO- https://ryanfortner.github.io/box64-debs/KEY.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg \
    && apt-get update && apt-get install -y --no-install-recommends box64 \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# gosu: privilege-dropping helper used by the bootstrap entrypoint.
# Uses curl from the step above; base image has curl available via apt.
RUN ARCH=$(dpkg --print-architecture); \
    curl -fsSL "https://github.com/tianon/gosu/releases/download/1.19/gosu-${ARCH}" -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu

# Create the unprivileged steam user and persistent directories.
# /config is a bind mount at runtime (owned by host); create it as root so
# the steam user can have /home-owned dirs, matching the runtime bind mounts.
RUN useradd -l -u "${PUID}" -m "${USER}" \
    && mkdir -p "${STEAMCMDDIR}" "${HOMEDIR}/.steam/sdk64" "${SERVER_DIR}" "${CONFIG_DIR}" \
    && chown -R "${USER}:${USER}" "${HOMEDIR}"

# Valheim-specific Box64 tuning for stability on ARM64
# https://github.com/ptitSeb/box64/issues/1182
COPY --chown=${USER}:${USER} .box64rc "${HOMEDIR}/.box64rc"

# Download & initialize SteamCMD using Box64 (Box32 mode) for its 32-bit binary
USER ${USER}
WORKDIR ${STEAMCMDDIR}

# Download SteamCMD and initialize it via Box64.
# Directly invoke the 32-bit steamcmd binary through Box64 (Box32 mode) —
# bypasses steamcmd.sh which self-updates mid-execution and replaces itself
# with an ARM-aware version that looks for a non-existent linuxarm64/ directory.
RUN curl -fsSL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' | tar xvzf - \
    && /usr/local/bin/box64 ./linux64/steamcmd +quit \
    || true \
    && ln -s linux64/steamclient.so steamservice.so \
    && ln -s "${STEAMCMDDIR}/linux64/steamclient.so" "${HOMEDIR}/.steam/sdk64/steamclient.so" \
    && cp -a "${STEAMCMDDIR}" /opt/steamcmd \
    && chown -R "${USER}:${USER}" /opt/steamcmd

# Place the entrypoints. The bootstrap runs as root to fix volume ownership,
# then drops privileges and execs the server entrypoint as the steam user.
COPY --chown=${USER}:${USER} --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

WORKDIR ${SERVER_DIR}

# The bootstrap entrypoint must start as root to chown the mounted volumes;
# it then drops to the steam user via gosu before running the server.
USER root

# Valheim default server ports (UDP)
EXPOSE 2456-2457/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
