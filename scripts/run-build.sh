#!/bin/bash
set -e
# La raiz se deduce de la ubicacion del propio script: asi el repo se puede
# clonar en cualquier sitio sin editar nada.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# The self-contained builder normally provides omarchy_msg.  When this helper
# is run directly, load the maintained catalog if available; an untranslated
# key is safer than changing build behavior when the catalog is absent.
if ! type omarchy_msg >/dev/null 2>&1; then
  [ -f "${OMARCHY_CATALOG:-$ROOT/localization/catalog.sh}" ] && . "${OMARCHY_CATALOG:-$ROOT/localization/catalog.sh}"
fi
msg() { omarchy_msg "$@"; }

echo "=== $(msg script_prepare_iso) ==="
rm -rf provision/iso && mkdir -p provision/iso
cp provision/src/stage1.sh provision/src/stage2.sh provision/src/stage3.sh \
   provision/src/config.env provision/src/packages-core.txt provision/src/packages-extra.txt \
   provision/iso/
cp "${OMARCHY_CATALOG:-$ROOT/localization/catalog.sh}" provision/iso/catalog.sh
# nombre corto para no depender de extensiones ISO9660
ln dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz 2>/dev/null \
  || cp dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz
rm -f provision/provision.iso
hdiutil makehybrid -iso -joliet -default-volume-name PROVISION \
  -o provision/provision.iso provision/iso/ >/dev/null
ls -lh provision/provision.iso

echo "=== $(msg script_clean_disk) ==="
rm -f vm/omarchy-arm.qcow2 vm/efi-vars.fd
qemu-img create -f qcow2 vm/omarchy-arm.qcow2 80G >/dev/null
dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

echo "=== $(date '+%F %T') $(msg script_building) ==="
exec expect -f scripts/build.exp
