{
  lib,
  stdenv,
  rustPlatform,
  rust-bin,
  llvmPackages,
  lld,
}:

let
  target = "aarch64-unknown-linux-musl";
  # nixpkgs' rustc carries std for the host only.
  toolchain = rust-bin.stable.latest.default.override {
    targets = [ target ];
  };
in
rustPlatform.buildRustPackage {
  pname = "vmproxy";
  version = "0.19.0";

  # Whole repo: vmproxy depends on ../common-utils by path.
  src = lib.cleanSource ../.;
  cargoRoot = "vmproxy";
  buildAndTestSubdir = "vmproxy";

  cargoLock.lockFile = ../vmproxy/Cargo.lock;

  nativeBuildInputs = [
    toolchain
    llvmPackages.clang
    lld
  ];

  # cargoBuildHook pins --target to the host, so the cross build is done by
  # hand. RUSTFLAGS (not CARGO_TARGET_*_RUSTFLAGS) is used deliberately: it
  # replaces vmproxy/.cargo/config.toml's per-target rustflags rather than
  # merging with them, which drops -Clinker-plugin-lto. That flag needs rustc's
  # LLVM to match clang's, and a mismatch shows up as a bitcode version error.
  buildPhase = ''
    runHook preBuild
    cd vmproxy
    env RUSTFLAGS="-Clink-arg=--target=${target} -Clink-arg=-fuse-ld=lld" \
      cargo build --release --offline --frozen \
        --features freebsd \
        --target ${target} \
        --config 'target.${target}.linker="clang"'
    cd ..
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 vmproxy/target/${target}/release/vmproxy $out/bin/vmproxy
    runHook postInstall
  '';

  # The output is a Linux binary; the build platform cannot run it, and
  # stripping it with the host toolchain is not useful.
  doCheck = false;
  dontStrip = true;

  meta = {
    description = "anylinuxfs guest agent (Linux/musl)";
    platforms = lib.platforms.darwin;
  };
}
