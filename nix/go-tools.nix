{
  lib,
  buildGoModule,
  vmrunner-sys,
}:

{
  # Bootstraps the Alpine rootfs for the microVM. Runs on the host, and links
  # the vmrunner-sys staticlib through cgo, so the whole repo is the source and
  # the library is staged at the relative path its #cgo LDFLAGS line expects.
  init-rootfs = buildGoModule {
    pname = "anylinuxfs-init-rootfs";
    version = "0.19.0";

    src = lib.cleanSource ../.;
    modRoot = "init-rootfs";
    vendorHash = "sha256-mJrXveNbnFww9YLgwXnfhECzxWipGfyL1V4qkuc+hwk=";

    # Matches build-app.sh: avoids the gpgme/btrfs C dependencies of
    # containers/image.
    tags = [ "containers_image_openpgp" ];
    ldflags = [ "-w" "-s" ];

    # postPatch, not preBuild: the build cds into modRoot first, and the cgo
    # directive resolves ../../vmrunner-sys/target relative to the source root.
    postPatch = ''
      mkdir -p vmrunner-sys/target
      cp ${vmrunner-sys}/lib/libvmrunner_sys.a vmrunner-sys/target/
    '';

    meta.mainProgram = "init-rootfs";
  };

  # freebsd-bootstrap is intentionally absent: it only matters for the FreeBSD
  # guest, which this package does not ship (vmproxy-bsd needs a pinned nightly
  # toolchain, -Z build-std and a FreeBSD sysroot fetched at build time).
}
