#!/bin/bash

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

# Every artifact below is executed, or unpacked into something that is executed,
# with root privileges. Each download is therefore pinned to a SHA-256 and
# verified before it is unpacked or made executable.
#
# Provenance differs by source, and it is worth being clear about which is which:
#
#   - gvproxy: taken from the `sha256sums` asset that containers/gvisor-tap-vsock
#     publishes alongside each release, so these are the publisher's own values.
#
#   - everything else: the upstream releases publish no checksums, so these were
#     recorded from a download on 2026-07-31 and cross-checked against the copies
#     already installed on a working machine. That pins the artifact against
#     future substitution, but it is trust-on-first-use: it does not prove the
#     bytes were authentic at the time they were recorded.
#
# When bumping a version, update the matching checksum in the same commit.
# Re-record with: curl -fL <url> | shasum -a 256

IMAGE_ARCHIVE_NAME="linux-aarch64-Images-v6.12.62-anylinuxfs.tar.gz"
RELEASE_URL="https://github.com/nohajc/libkrunfw/releases/download/v6.12.62-rev1"
IMAGE_ARCHIVE_URL="${RELEASE_URL}/${IMAGE_ARCHIVE_NAME}"
IMAGE_ARCHIVE_SHA256="1de75a3d4ef2eccd41df10f2eac8435dbaba52371fa42b0b0384fd9cf9a1f3ce"
MODULES_ARCHIVE_NAME="modules.squashfs"
MODULES_ARCHIVE_URL="${RELEASE_URL}/${MODULES_ARCHIVE_NAME}"
MODULES_ARCHIVE_SHA256="86ed485e4e46ba265261a55e25c92ea15f6118003fcec95a8bafde8ad39f697f"

INIT_BSD="init-freebsd"
INIT_BSD_URL="https://github.com/nohajc/libkrun/releases/download/v1.17.0-init-bsd/${INIT_BSD}"
INIT_BSD_SHA256="574dfa33e3a825657a065e7469e7acbcce0fb9ca28a57479f936b4b939d6d319"

GVPROXY_VERSION="0.8.9"
if [[ "$HOST_OS" == "Darwin" ]]; then
    GVPROXY_URL="https://github.com/containers/gvisor-tap-vsock/releases/download/v${GVPROXY_VERSION}/gvproxy-darwin"
    GVPROXY_SHA256="c6f7b4bc7f21bf810b5cf54e04d979b014c5d96472a03a9e97fe62a00940067c"

    VMNET_HELPER_VERSION="0.12.0"
    VMNET_HELPER_URL="https://github.com/nirs/vmnet-helper/releases/download/v${VMNET_HELPER_VERSION}/vmnet-helper.tar.gz"
    VMNET_HELPER_SHA256="0f123c29565e36278aca57e13917d3a7db098e8c1552389f9332331c9dfc6381"
elif [[ "$HOST_OS" == "Linux" && ( "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ) ]]; then
    GVPROXY_URL="https://github.com/containers/gvisor-tap-vsock/releases/download/v${GVPROXY_VERSION}/gvproxy-linux-arm64"
    GVPROXY_SHA256="6ecca02839254c9a0cc184bba7aac63755a22d7ed10d455b852528a99d7f7d4b"
else
    echo "Unsupported host for prebuilt gvproxy: ${HOST_OS}/${HOST_ARCH}" >&2
    exit 1
fi

sha256_of() {
    if command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# Download to the given path and refuse to leave the file in place unless it
# matches. `curl -f` keeps an HTTP error body from being mistaken for content.
fetch_verified() {
    local url="$1" dest="$2" expected="$3"

    curl -fL --retry 3 -o "$dest" "$url"

    local actual
    actual="$(sha256_of "$dest")"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$dest"
        echo "" >&2
        echo "checksum mismatch for ${url}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        echo "Refusing to use this file. If the upstream release was rebuilt," >&2
        echo "verify the new artifact independently before updating the pin." >&2
        exit 1
    fi
}

cd "$SCRIPT_DIR"
fetch_verified "$IMAGE_ARCHIVE_URL" "$IMAGE_ARCHIVE_NAME" "$IMAGE_ARCHIVE_SHA256"
mkdir -p "libexec"
tar xzf "$IMAGE_ARCHIVE_NAME" -C "libexec"
rm "$IMAGE_ARCHIVE_NAME"

mkdir -p "lib"
fetch_verified "$MODULES_ARCHIVE_URL" "lib/${MODULES_ARCHIVE_NAME}" "$MODULES_ARCHIVE_SHA256"

fetch_verified "$INIT_BSD_URL" "libexec/${INIT_BSD}" "$INIT_BSD_SHA256"
chmod +x "libexec/$INIT_BSD"

fetch_verified "$GVPROXY_URL" "libexec/gvproxy" "$GVPROXY_SHA256"
chmod +x libexec/gvproxy

if [[ "$HOST_OS" == "Darwin" ]]; then
    fetch_verified "$VMNET_HELPER_URL" "vmnet-helper.tar.gz" "$VMNET_HELPER_SHA256"
    tar xzf vmnet-helper.tar.gz -C libexec --strip-components=4 ./opt/vmnet-helper/bin/vmnet-helper
    rm vmnet-helper.tar.gz
fi
