{
  description = "anylinuxfs development shell (macOS host toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
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
