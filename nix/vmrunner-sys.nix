{
  lib,
  rustPlatform,
  zig,
}:

# A staticlib that init-rootfs links via cgo
# (`#cgo LDFLAGS: ${SRCDIR}/../../vmrunner-sys/target/libvmrunner_sys.a`).
rustPlatform.buildRustPackage {
  pname = "vmrunner-sys";
  version = "0.19.0";

  src = lib.cleanSource ../.;
  cargoRoot = "vmrunner-sys";
  buildAndTestSubdir = "vmrunner-sys";

  cargoLock.lockFile = ../vmrunner-sys/Cargo.lock;

  # See nix/package.nix: zig by absolute path, so its setup hook stays out of
  # buildPhase. libkrun pulls in krun-init-blob, whose build.rs needs it.
  env.CC_LINUX = "${zig}/bin/zig cc -target aarch64-linux-musl";

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
  '';

  # cargoInstallHook only installs binaries; this crate produces a staticlib.
  # buildRustPackage may or may not build under a target-triple subdirectory
  # depending on whether it passes --target, so locate the artifact rather than
  # assuming a path.
  installPhase = ''
    runHook preInstall
    lib_path="$(find . -name libvmrunner_sys.a -type f | head -1)"
    if [ -z "$lib_path" ]; then
      echo "libvmrunner_sys.a not found in the build tree" >&2
      exit 1
    fi
    install -Dm644 "$lib_path" $out/lib/libvmrunner_sys.a
    runHook postInstall
  '';

  doCheck = false;

  meta = {
    description = "Static library used by anylinuxfs init-rootfs";
    platforms = lib.platforms.darwin;
  };
}
