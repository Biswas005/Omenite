FROM scratch AS ctx
COPY build_files /ctx/build_files
COPY assets /ctx/assets

FROM ghcr.io/ublue-os/bazzite-gnome-nvidia:stable

ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite-gnome-nvidia:stable
ENV BASE_IMAGE=${BASE_IMAGE}

RUN --mount=type=bind,from=ctx,source=/ctx,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /usr/bin/bash /ctx/build_files/build.sh