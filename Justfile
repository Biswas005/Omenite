export repo_organization := env("GITHUB_REPOSITORY_OWNER", "Biswas005")
export image_name := env("IMAGE_NAME", "omenite")
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

build $target_image=("localhost/" + image_name) $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    podman build --pull=newer --tag "${target_image}:${tag}" .

_build-bib $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p output
    sudo podman run           --rm --privileged --pull=newer --security-opt label=type:unconfined_t           -v $(pwd)/${config}:/config.toml:ro           -v $(pwd)/output:/output           -v /var/lib/containers/storage:/var/lib/containers/storage           "${bib_image}" build --output /output --use-librepo=True --rootfs xfs --type ${type} "${target_image}:${tag}"

build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: (build target_image tag)
    just _build-bib "${target_image}" "${tag}" qcow2 disk_config/disk.toml

build-iso $target_image=("localhost/" + image_name) $tag=default_tag: (build target_image tag)
    just _build-bib "${target_image}" "${tag}" anaconda-iso disk_config/iso.toml
