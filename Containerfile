# Allow build scripts/assets to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /ctx/build_files
COPY assets /ctx/assets

# NVIDIA-enabled Bazzite GNOME base image
FROM ghcr.io/ublue-os/bazzite-gnome-nvidia:stable

RUN --mount=type=bind,from=ctx,source=/ctx,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /usr/bin/bash /ctx/build_files/build.sh

RUN bootc container lint
