# ─── Stage: copy build files & assets into build context ───────────────────
FROM scratch AS ctx
COPY build_files/ assets/ /

# ─── Base Image ─────────────────────────────────────────────────────────────
FROM ghcr.io/ublue-os/bazzite-nvidia:stable

# Build arguments for module-signing secrets (base64-encoded by CI)
ARG module_signing_key
ARG module_signing_crt
ARG module_signing_der

# ─── 1. Build custom hp-wmi, sign it, install packages ──────────────────────
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

# ─── 2. Logo / icon installation (must happen BEFORE branding layer) ─────────
# KDE resolves LOGO= via QIcon::fromTheme() → needs hicolor sized dirs.
# fastfetch with kitty protocol uses the pixmaps path directly.
# We install into EVERY standard hicolor size so nothing is missed.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    for sz in 16 22 24 32 48 64 96 128 192 256 512; do \
        install -Dm644 /ctx/omenite-logo.png \
            /usr/share/icons/hicolor/${sz}x${sz}/apps/omenite-logo.png; \
    done && \
    install -Dm644 /ctx/omenite-logo.svg \
        /usr/share/icons/hicolor/scalable/apps/omenite-logo.svg && \
    install -Dm644 /ctx/omenite-logo.png /usr/share/pixmaps/omenite-logo.png && \
    install -Dm644 /ctx/omenite-logo.svg /usr/share/pixmaps/omenite-logo.svg && \
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor/ 2>/dev/null || true && \
    ostree container commit

# ─── 3. OS branding: /usr/lib/os-release AND /etc/os-release ────────────────
# In Fedora/ostree, /etc/os-release is a symlink to /usr/lib/os-release.
# We edit BOTH targets to be safe. We also write /usr/lib/os-release directly
# so it survives the ostree layer correctly.
#
# KDE "About this System" reads:
#   1. /etc/xdg/kcm-about-distrorc   ← bazzite ships this; we MUST override it
#   2. /etc/os-release                ← fallback if kcm-about-distrorc absent
#
# Fields shown in KDE About panel:
#   NAME        → distro name ("Bazzite 44")   ← NAME + VERSION_ID
#   VARIANT     → edition line ("NVIDIA Edition")
#   HOME_URL    → clickable link
#   LOGO        → icon name resolved via QIcon::fromTheme()  ← must match hicolor icon
RUN \
    # ── Edit /usr/lib/os-release (the real file) ──────────────────────────
    sed -i \
        -e 's|^NAME=.*|NAME="Omenite"|' \
        -e 's|^PRETTY_NAME=.*|PRETTY_NAME="Omenite Linux"|' \
        -e 's|^ID=.*|ID=omenite|' \
        -e 's|^ID_LIKE=.*|ID_LIKE="fedora"|' \
        -e 's|^VARIANT=.*|VARIANT="HP Omen Edition"|' \
        -e 's|^VARIANT_ID=.*|VARIANT_ID=omenite|' \
        -e 's|^LOGO=.*|LOGO=omenite-logo|' \
        -e 's|^HOME_URL=.*|HOME_URL="https://github.com/Biswas005/Omenite"|' \
        -e 's|^DOCUMENTATION_URL=.*|DOCUMENTATION_URL="https://github.com/Biswas005/Omenite/wiki"|' \
        -e 's|^SUPPORT_URL=.*|SUPPORT_URL="https://github.com/Biswas005/Omenite/issues"|' \
        -e 's|^BUG_REPORT_URL=.*|BUG_REPORT_URL="https://github.com/Biswas005/Omenite/issues"|' \
        /usr/lib/os-release && \
    # Add missing fields if not present
    grep -q '^LOGO='         /usr/lib/os-release || echo 'LOGO=omenite-logo'                                                  >> /usr/lib/os-release && \
    grep -q '^HOME_URL='     /usr/lib/os-release || echo 'HOME_URL="https://github.com/Biswas005/Omenite"'                    >> /usr/lib/os-release && \
    grep -q '^BUG_REPORT_URL=' /usr/lib/os-release || echo 'BUG_REPORT_URL="https://github.com/Biswas005/Omenite/issues"'    >> /usr/lib/os-release && \
    # ── Make /etc/os-release a plain copy (not symlink) so it's writable ──
    cp /usr/lib/os-release /tmp/os-release-copy && \
    cp /tmp/os-release-copy /etc/os-release && \
    # ── /etc/issue ────────────────────────────────────────────────────────
    printf 'Omenite Linux \\r (\\l)\n' > /etc/issue && \
    printf 'Omenite Linux\n'           > /etc/issue.net && \
    ostree container commit

# ─── 4. KDE-specific branding: kcm-about-distrorc ──────────────────────────
# This file is what KDE Settings → About This System ACTUALLY reads.
# Bazzite ships /etc/xdg/kcm-about-distrorc with their branding.
# We overwrite it completely. LogoPath must be an absolute path to PNG.
# The "Version" field overrides what KDE would otherwise get from VERSION_ID.
RUN \
    mkdir -p /etc/xdg && \
    cat > /etc/xdg/kcm-about-distrorc << 'KCM_EOF'
[General]
Name=Omenite Linux
Version=1.0
Variant=HP Omen Edition
Website=https://github.com/Biswas005/Omenite
LogoPath=/usr/share/pixmaps/omenite-logo.png
KCM_EOF
ostree container commit

# ─── 5. fastfetch system-wide config ────────────────────────────────────────
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    install -Dm644 /ctx/fastfetch-config.jsonc /etc/fastfetch/config.jsonc && \
    ostree container commit

# ─── 6. Plymouth boot splash ────────────────────────────────────────────────
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    for theme_dir in /usr/share/plymouth/themes/bazzite \
                     /usr/share/plymouth/themes/spinner \
                     /usr/share/plymouth/themes/bgrt; do \
        [ -d "$theme_dir" ] && \
            cp /ctx/omenite-logo.png "$theme_dir/logo.png" 2>/dev/null || \
            cp /ctx/omenite-logo.png "$theme_dir/watermark.png" 2>/dev/null || true; \
    done && \
    ostree container commit

# ─── 7. MOTD ────────────────────────────────────────────────────────────────
RUN cat > /etc/motd << 'MOTD_EOF'

  ██████╗ ███╗   ███╗███████╗███╗   ██╗██╗████████╗███████╗
 ██╔═══██╗████╗ ████║██╔════╝████╗  ██║██║╚══██╔══╝██╔════╝
 ██║   ██║██╔████╔██║█████╗  ██╔██╗ ██║██║   ██║   █████╗
 ██║   ██║██║╚██╔╝██║██╔══╝  ██║╚██╗██║██║   ██║   ██╔══╝
 ╚██████╔╝██║ ╚═╝ ██║███████╗██║ ╚████║██║   ██║   ███████╗
  ╚═════╝ ╚═╝     ╚═╝╚══════╝╚═╝  ╚═══╝╚═╝   ╚═╝   ╚══════╝

  Omenite Linux — built for HP Omen
  https://github.com/Biswas005/Omenite

MOTD_EOF
ostree container commit

# ─── 8. GRUB / BLS entry rebranding hook ────────────────────────────────────
RUN cat > /usr/lib/kernel/install.d/40-omenite-title.install << 'GRUB_EOF'
#!/bin/bash
# Rename BLS boot entry title from Bazzite → Omenite after every kernel install
COMMAND="$1"
[ "$COMMAND" = "add" ] || exit 0
for entry in /boot/loader/entries/*.conf; do
    [ -f "$entry" ] || continue
    sed -i 's/\bBazzite\b/Omenite/g; s/\bbazzite\b/omenite/g' "$entry"
done
GRUB_EOF
chmod +x /usr/lib/kernel/install.d/40-omenite-title.install && \
    ostree container commit

# ─── 9. Final lint ──────────────────────────────────────────────────────────
RUN bootc container lint
