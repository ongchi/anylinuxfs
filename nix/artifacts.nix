{ fetchurl }:

# Prebuilt artifacts that download-dependencies.sh fetches at build time. The
# checksums are the same values pinned in that script, so the two stay in step:
# update both together when bumping a version.
#
# init-freebsd is deliberately absent — it only matters for the FreeBSD guest,
# which this package does not ship.
let
  libkrunfwRelease = "https://github.com/nohajc/libkrunfw/releases/download/v6.12.62-rev1";
in
{
  # Kernel images for the guest; unpacks to Image and Image-4K.
  images = fetchurl {
    url = "${libkrunfwRelease}/linux-aarch64-Images-v6.12.62-anylinuxfs.tar.gz";
    sha256 = "1de75a3d4ef2eccd41df10f2eac8435dbaba52371fa42b0b0384fd9cf9a1f3ce";
  };

  # Kernel modules, unpacked into the rootfs by init-rootfs.
  modules = fetchurl {
    url = "${libkrunfwRelease}/modules.squashfs";
    sha256 = "86ed485e4e46ba265261a55e25c92ea15f6118003fcec95a8bafde8ad39f697f";
  };

  # User-mode networking helper. This checksum is the publisher's own, from the
  # sha256sums asset in the gvisor-tap-vsock release.
  gvproxy = fetchurl {
    url = "https://github.com/containers/gvisor-tap-vsock/releases/download/v0.8.9/gvproxy-darwin";
    sha256 = "c6f7b4bc7f21bf810b5cf54e04d979b014c5d96472a03a9e97fe62a00940067c";
  };

  vmnetHelper = fetchurl {
    url = "https://github.com/nirs/vmnet-helper/releases/download/v0.12.0/vmnet-helper.tar.gz";
    sha256 = "0f123c29565e36278aca57e13917d3a7db098e8c1552389f9332331c9dfc6381";
  };
}
