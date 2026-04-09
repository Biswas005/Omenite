# Stage to copy build files
FROM scratch AS ctx
COPY build_files /

# Base Image
FROM ghcr.io/ublue-os/bazzite-gnome-nvidia:stable

# Build arguments for module signing secrets
ARG module_signing_key
ARG module_signing_crt  
ARG module_signing_der

# Create temporary directory for secrets and decode them
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    mkdir -p /tmp/secrets && \
    echo "$module_signing_key" | base64 -d > /tmp/secrets/module-signing.key && \
    echo "$module_signing_crt" | base64 -d > /tmp/secrets/module-signing.crt && \
    echo "$module_signing_der" | base64 -d > /tmp/secrets/module-signing.der && \
    /ctx/build.sh && \
    rm -rf /tmp/secrets && \
    ostree container commit

# Override OS branding to Omenite
RUN sed -i 's/^NAME=.*/NAME="Omenite"/' /etc/os-release && \
    sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="Omenite Linux"/' /etc/os-release && \
    sed -i 's/^VARIANT=.*/VARIANT="Omenite"/' /etc/os-release && \
    sed -i 's|^LOGO=.*|LOGO=/usr/share/icons/hicolor/scalable/apps/omenite-logo.svg|' /etc/os-release

# Copy Omenite logo to system locations
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    cp /ctx/assets/omenite-logo.png /usr/share/icons/hicolor/scalable/apps/ && \
    cp /ctx/assets/omenite-logo.svg /usr/share/icons/hicolor/scalable/apps/ && \
    # Also copy to plymouth theme if it exists
    if [ -d /usr/share/plymouth/themes/bazzite ]; then \
        cp /ctx/assets/omenite-logo.png /usr/share/plymouth/themes/bazzite/logo.png || true; \
    fi

RUN bootc container lint
