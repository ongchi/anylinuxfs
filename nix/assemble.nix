{
  lib,
  runCommand,
  darwin,
  cctools,
  anylinuxfs-bin,
  vmproxy,
  init-rootfs,
  vmrunner-sys,
  artifacts,
}:

# Lays out the install tree anylinuxfs expects at runtime. settings.rs derives
# prefix_dir as the parent of the executable's directory, then looks for
# libexec/, lib/ and etc/ beneath it.
#
# Signing happens here rather than in the component derivations because their
# fixupPhase strips the binaries, and stripping invalidates a code signature.
runCommand "anylinuxfs-0.19.0"
  {
    nativeBuildInputs = [
      # sigtool provides codesign; it shells out to codesign_allocate from
      # cctools and aborts without it.
      darwin.sigtool
      cctools
    ];

    meta = {
      description = "Mount Linux filesystems on macOS via a libkrun microVM and NFS";
      homepage = "https://github.com/nohajc/anylinuxfs";
      license = lib.licenses.gpl2Only;
      platforms = lib.platforms.darwin;
      mainProgram = "anylinuxfs";
    };
  }
  ''
    mkdir -p $out/bin $out/libexec $out/lib $out/etc

    install -Dm755 ${anylinuxfs-bin}/bin/anylinuxfs $out/bin/anylinuxfs
    install -Dm755 ${vmproxy}/bin/vmproxy         $out/libexec/vmproxy
    install -Dm755 ${init-rootfs}/bin/init-rootfs $out/libexec/init-rootfs
    install -Dm755 ${artifacts.gvproxy}           $out/libexec/gvproxy

    # Kernel images (Image, Image-4K).
    tar xzf ${artifacts.images} -C $out/libexec

    install -Dm644 ${artifacts.modules} $out/lib/modules.squashfs

    tar xzf ${artifacts.vmnetHelper} -C $out/libexec \
      --strip-components=4 ./opt/vmnet-helper/bin/vmnet-helper
    chmod 755 $out/libexec/vmnet-helper

    install -Dm644 ${../etc/anylinuxfs.toml} $out/etc/anylinuxfs.toml

    # libkrun needs com.apple.security.hypervisor to start a VM at all, and
    # init-rootfs runs the same machinery when bootstrapping the rootfs.
    for binary in $out/bin/anylinuxfs $out/libexec/init-rootfs; do
      codesign --entitlements ${../anylinuxfs.entitlements} --force -s - "$binary"
    done

    # Fail loudly rather than shipping a binary that cannot start a VM.
    # sigtool's codesign cannot read entitlements back (-d wants --sign), so the
    # check uses the system codesign when the sandbox exposes it, and is skipped
    # otherwise rather than being silently wrong.
    if [ -x /usr/bin/codesign ]; then
      for binary in $out/bin/anylinuxfs $out/libexec/init-rootfs; do
        if ! /usr/bin/codesign -d --entitlements - "$binary" 2>&1 \
             | grep -q "com.apple.security.hypervisor"; then
          echo "ERROR: hypervisor entitlement missing from $binary" >&2
          exit 1
        fi
      done
    else
      echo "note: system codesign unavailable, skipping entitlement readback" >&2
    fi
  ''
