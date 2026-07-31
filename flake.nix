{
  description = "anylinuxfs development shell (macOS host toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  # nixpkgs' rustc only ships std for the host. vmproxy is cross-compiled to
  # aarch64-unknown-linux-musl for the guest, which needs a toolchain carrying
  # that target's std.
  inputs.rust-overlay.url = "github:oxalica/rust-overlay";
  inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        }));
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          vmrunner-sys = pkgs.callPackage ./nix/vmrunner-sys.nix { };
          goTools = pkgs.callPackage ./nix/go-tools.nix { inherit vmrunner-sys; };
          artifacts = pkgs.callPackage ./nix/artifacts.nix { };
          anylinuxfs-bin = pkgs.callPackage ./nix/package.nix { };
          vmproxy = pkgs.callPackage ./nix/vmproxy.nix { };
        in
        rec {
          anylinuxfs = pkgs.callPackage ./nix/assemble.nix {
            inherit anylinuxfs-bin vmproxy vmrunner-sys artifacts;
            inherit (goTools) init-rootfs;
          };
          inherit anylinuxfs-bin vmproxy vmrunner-sys;
          inherit (goTools) init-rootfs;
          default = anylinuxfs;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            # libblkid-rs-sys resolves libblkid through pkg-config.
            pkgs.pkg-config
            pkgs.util-linux
            # Cross-compiles krun-init-blob's init.c for the Linux guest. zig
            # ships its own musl headers and libc, so this replaces the
            # Homebrew-clang + Debian-sysroot path in ./cc_linux entirely.
            pkgs.zig
            # `-fuse-ld=lld` in the guest cross builds; clang looks for ld.lld
            # on PATH. clang itself is referenced by absolute path below so it
            # does not shadow the host toolchain for the macOS build.
            pkgs.lld
            # The Go builds stamp VCS info. /usr/bin/git is an Xcode stub that
            # dispatches via xcrun, which nixpkgs' xcbuild shadows in this
            # shell, so a real git has to be on PATH ahead of it.
            pkgs.git
            # Integration tests.
            pkgs.bats
          ];

          env = {
            # build.rs splits CC_LINUX on whitespace, so the target triple can
            # travel with the compiler name and no wrapper script is needed.
            # Overrides the ./cc_linux entry in .cargo/config.toml, which is
            # not marked `force` and so loses to the ambient environment.
            CC_LINUX = "zig cc -target aarch64-linux-musl";
            PKG_CONFIG_PATH = "${pkgs.util-linux.dev}/lib/pkgconfig";
            # Cross-links vmproxy for the Linux and FreeBSD guests, replacing
            # the Homebrew LLVM path pinned in vmproxy/.cargo/config.toml.
            # Consumed by ./build-app.sh.
            ANYLINUXFS_CROSS_CC = "${pkgs.llvmPackages.clang}/bin/clang";
          };

          # Rust deliberately comes from the ambient rustup toolchain rather
          # than nixpkgs: vmproxy's FreeBSD target needs a pinned nightly plus
          # -Z build-std, which rustup manages and this shell should not fight.
          shellHook = ''
            echo "anylinuxfs devshell: CC_LINUX=$CC_LINUX"
            echo "rust: $(rustc --version 2>/dev/null || echo 'not found — install via rustup')"
          '';
        };
      });
    };
}
