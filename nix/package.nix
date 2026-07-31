{
  lib,
  stdenv,
  rustPlatform,
  pkg-config,
  util-linux,
  zig,
}:

rustPlatform.buildRustPackage {
  pname = "anylinuxfs";
  version = "0.19.0";

  # The whole repo: the anylinuxfs crate has a path dependency on ../common-utils.
  src = lib.cleanSource ../.;
  # The crate lives in a subdirectory but depends on ../common-utils by path, so
  # the whole repo is the source. cargoRoot points the setup hooks at the
  # lockfile; buildAndTestSubdir is where cargo actually runs.
  cargoRoot = "anylinuxfs";
  buildAndTestSubdir = "anylinuxfs";

  cargoLock = {
    lockFile = ../anylinuxfs/Cargo.lock;
    outputHashes = {
      "dns-sd-0.1.3" = "sha256-K/PIHhghytm4chXjMMrNLaeehOiZYROGkQhk/VC7rfY=";
    };
  };

  # zig is deliberately NOT a nativeBuildInput: its setup hook takes over
  # buildPhase and runs `zig build`, which has nothing to do with this crate.
  # CC_LINUX below refers to it by absolute path instead, which is enough to
  # pull it into the build closure.
  nativeBuildInputs = [ pkg-config ];

  buildInputs = [ util-linux ];

  buildFeatures = [ "freebsd" ];

  env = {
    # build.rs splits CC_LINUX on whitespace, so the target rides along with the
    # compiler name. Overrides the ./cc_linux entry in .cargo/config.toml, which
    # is not marked `force` and so loses to the environment.
    CC_LINUX = "${zig}/bin/zig cc -target aarch64-linux-musl";
    # Same mechanism: .cargo/config.toml points these at Homebrew.
    PKG_CONFIG = "pkg-config";
    PKG_CONFIG_PATH = "${util-linux.dev}/lib/pkgconfig";
  };

  preBuild = ''
    # zig insists on a writable cache directory.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
  '';

  # The test suite is run separately; several tests touch /tmp and the network.
  doCheck = false;

  meta = {
    description = "Mount Linux filesystems on macOS via a libkrun microVM and NFS";
    homepage = "https://github.com/nohajc/anylinuxfs";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.darwin;
    mainProgram = "anylinuxfs";
  };
}
