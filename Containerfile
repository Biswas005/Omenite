# Stage to copy build files
FROM scratch AS ctx
COPY build_files/ assets/ /

# Base Image
FROM ghcr.io/ublue-os/bazzite-nvidia:stable

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
    sed -i 's/^VARIANT_ID=.*/VARIANT_ID="omenite"/' /etc/os-release && \
    sed -i 's|^LOGO=.*|LOGO=omenite-logo|' /etc/os-release && \
    sed -i '/^LOGO=/a ICON_NAME="omenite-logo"' /etc/os-release && \
    mkdir -p /etc/ostree/remotes.d && \
    printf '[remote "omenite"]\nurl=https://example.com/omenite\ngpg-verify=true\n' > /etc/ostree/remotes.d/omenite.conf && \
    if [ -d /boot/loader/entries ]; then \
        for entry in /boot/loader/entries/*bazzite*.conf; do \
            if [ -f "$$entry" ]; then \
                sed -i 's/Bazzite/Omenite/g' "$$entry"; \
                sed -i 's/bazzite/omenite/g' "$$entry"; \
            fi; \
        done; \
    fi

# Copy Omenite logo to system locations for GNOME Settings and fastfetch
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    cp /ctx/omenite-logo.png /usr/share/icons/hicolor/scalable/apps/ && \
    cp /ctx/omenite-logo.svg /usr/share/icons/hicolor/scalable/apps/ && \
    cp /ctx/omenite-logo.png /usr/share/pixmaps/omenite-logo.png && \
    cp /ctx/omenite-logo.svg /usr/share/pixmaps/omenite-logo.svg && \
    # Create symlinks for common OS detection patterns
    ln -sf /usr/share/pixmaps/omenite-logo.svg /usr/share/pixmaps/os-logo.svg || true && \
    # Update icon cache
    gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true && \
    # Also copy to plymouth theme if it exists for boot splash
    if [ -d /usr/share/plymouth/themes/bazzite ]; then \
        cp /ctx/omenite-logo.png /usr/share/plymouth/themes/bazzite/logo.png || true; \
    fi

RUN bootc container lint
