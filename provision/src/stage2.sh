#!/bin/bash
# Etapa 2 — dentro del chroot de Arch Linux ARM, como root.
# Sistema base, kernel, arranque UEFI, paquetes del stack Omarchy y login.
set -euo pipefail
. /root/prov/config.env
. /root/prov/fsinfo.env
export LANG=C LC_ALL=C

if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" /root/prov/catalog.sh /usr/local/share/omarchy/catalog.sh /media/prov/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }

log()  { echo ""; echo "==> [stage2] $*"; }
warn() { echo "!!  [stage2] $*"; }

trap 'warn "$(msg stage2_line_failed "$LINENO")"; exit 1' ERR

# ---------------------------------------------------------------- pacman
log "$(msg stage2_keyring)"
pacman-key --init
pacman-key --populate archlinuxarm

log "$(msg stage2_update)"
pacman -Syu --noconfirm --needed

log "$(msg stage2_base)"
# linux-firmware se omite a proposito: ~800 MB inutiles en una VM
pacman -S --noconfirm --needed \
  base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- localizacion
log "$(msg stage2_locale)"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland lee XKBLAYOUT de aqui (default/hypr/input.lua); KEYMAP solo
# cubre la consola de texto.
printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$VM_KEYMAP" "$VM_XKB" > /etc/vconsole.conf
echo "$VM_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $VM_HOSTNAME.localdomain $VM_HOSTNAME
EOF
systemd-machine-id-setup || true

# ---------------------------------------------------------------- fstab
log "$(msg stage2_fstab)"
if [ "$ROOTFS" = btrfs ]; then
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      btrfs  rw,noatime,compress=zstd:3,subvol=@         0 0
LABEL=OMROOT  /home  btrfs  rw,noatime,compress=zstd:3,subvol=@home     0 0
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS="rootflags=subvol=@"
else
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      ext4   rw,noatime                                  0 1
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS=""
fi
cat /etc/fstab

# ---------------------------------------------------------------- usuario
log "$(msg stage2_user "$VM_USER")"
userdel -r alarm 2>/dev/null || true
if ! id -u "$VM_USER" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash -c "$VM_FULLNAME" "$VM_USER"
fi
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD"     | chpasswd
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# sin contrasena solo mientras dura la instalacion; se retira al final
install -m 0440 /dev/stdin /etc/sudoers.d/99-install <<<"$VM_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# ---------------------------------------------------------------- initramfs
log "$(msg stage2_initramfs)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- arranque UEFI
log "systemd-boot en la ESP"
# --no-variables: no escribimos NVRAM; UTM arranca por la ruta de reserva
# \EFI\BOOT\BOOTAA64.EFI, que bootctl instala igualmente.
bootctl --esp-path=/boot --no-variables install

# La ESP se monta vacia DESPUES de extraer el rootfs, asi que /boot no tiene
# kernel. "pacman -S --needed" no lo repone si la version instalada ya coincide
# con la del repositorio, asi que se fuerza la reinstalacion del paquete.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  $(msg stage2_boot_empty)"
  pacman -S --noconfirm linux-aarch64 || warn "$(msg stage2_kernel_reinstall_failed)"
  mkinitcpio -P || warn "$(msg stage2_initramfs_failed)"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "$(msg stage2_kernel_missing)"; ls -la /boot; exit 1; }

INITRD=""
for c in /boot/initramfs-linux-aarch64.img /boot/initramfs-linux.img; do
  [ -f "$c" ] && { INITRD="/$(basename "$c")"; break; }
done
[ -n "$INITRD" ] || { warn "$(msg stage2_initramfs_missing)"; ls -la /boot; exit 1; }

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default  omarchy.conf
timeout  1
console-mode keep
editor   no
EOF
cat > /boot/loader/entries/omarchy.conf <<EOF
title    Arch Linux ARM — Omarchy
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw quiet loglevel=3
EOF
cat > /boot/loader/entries/omarchy-verbose.conf <<EOF
title    Arch Linux ARM — Omarchy ($(msg stage2_verbose))
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- red
log "$(msg stage2_network)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- escritorio
log "$(msg stage2_desktop)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} $(msg stage2_packages)"
  if pacman -S --noconfirm --needed "${PKGS[@]}"; then return 0; fi
  warn "$(msg stage2_batch_failed "$label")"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$(msg stage2_packages_failed "$label" "${FAILED[*]}")"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}
install_list /root/prov/packages-core.txt  "$(msg stage2_core)" fatal
set +e
install_list /root/prov/packages-extra.txt "$(msg stage2_extras)" soft
set -e

log "$(msg stage2_services)"
systemctl enable sddm.service 2>/dev/null || warn "$(msg stage2_sddm_missing)"
# Integracion con UTM: utmctl ip-address/exec/file necesitan el guest agent
systemctl enable qemu-guest-agent.service 2>/dev/null || true
# spice-vdagentd es una unidad "static": no se habilita, la activa el socket
# spice-vdagentd.socket cuando el cliente de la sesion se conecta. Lo que hay
# que asegurar es el socket, no el servicio.
systemctl enable spice-vdagentd.socket 2>/dev/null || true

# El puerto virtio del portapapeles pertenece a root:root 0600, asi que un
# servicio de usuario no puede abrirlo. La regla se lo da al grupo del usuario
# de la sesion, igual que hace el paquete spice-vdagent con su propia regla.
install -Dm644 /dev/stdin /etc/udev/rules.d/70-omarchy-vdagent.rules <<'UDEV'
# Puerto del agente SPICE: legible por la sesion grafica, para que
# omarchy-arm-vdagent pueda hablar el protocolo del portapapeles.
SUBSYSTEM=="virtio-ports", ATTR{name}=="com.redhat.spice.0", TAG+="uaccess", MODE="0660"
UDEV
echo "  $(msg stage2_udev_rule) /dev/virtio-ports/com.redhat.spice.0"

# Carpeta compartida de UTM. El bundle declara DirectoryShareMode=VirtFS, pero
# eso solo expone el dispositivo: el invitado tiene que montarlo. El tag es
# "share" (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1234).
# nofail para que un arranque sin carpeta configurada no caiga a emergencia,
# y x-systemd.automount para no pagar el montaje si no se usa.
mkdir -p /mnt/share
if ! grep -q '^share ' /etc/fstab; then
  cat >> /etc/fstab <<'FSTAB'

# Carpeta compartida de UTM (Ajustes de la VM -> Compartir -> Ruta compartida)
share  /mnt/share  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount,_netdev,msize=512000  0  0
FSTAB
fi
echo "  $(msg stage2_share_ready)"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "$(msg stage2_stage3 "$VM_USER")"
chmod +x /root/prov/stage3.sh
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 corre como usuario normal y /root es 0750: cualquier prueba suya sobre
# /root/prov da falso sin dar error. Se le deja una copia legible en su home.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  $(msg stage2_stage3_available): $(ls "$PROVDIR" | tr '\n' ' ')"
# El resultado de stage3 tiene que llegar al anfitrion: antes se degradaba a un
# warn y stage2 emitia su token de exito igualmente, asi que un stage3 que
# fallara entero producia un disco sin un solo dotfile de Omarchy declarado OK.
su - "$VM_USER" -c "bash ~/stage3.sh"; STAGE3_RC=$?
[ $STAGE3_RC -eq 0 ] || warn "$(msg stage2_stage3_failed "$STAGE3_RC")"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

# ---------------------------------------------------------------- login SDDM
log "$(msg stage2_sddm_session)"
OM="/home/$VM_USER/.local/share/omarchy"
mkdir -p /usr/local/share/wayland-sessions /etc/sddm.conf.d /usr/share/sddm
if [ -f "$OM/default/wayland-sessions/omarchy.desktop" ]; then
  cp "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
  SESSION=omarchy
else
  SESSION=hyprland-uwsm
fi
[ -f "$OM/default/sddm/hyprland.conf" ] && cp "$OM/default/sddm/hyprland.conf" /usr/share/sddm/hyprland.conf
cat > /etc/sddm.conf.d/10-wayland.conf <<EOF
[General]
DisplayServer=wayland
EOF
cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$VM_USER
Session=$SESSION
EOF
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  $(msg stage2_session)=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- ajustes VM
log "$(msg stage2_vm_tuning)"
# El cursor por hardware y los modificadores DRM dan problemas sobre virtio-gpu
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-vm-graphics.conf <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Sin esto, las ventanas de clientes GPU (alacritty, chromium) se mapean pero
# NO se pintan: virgl no entrega buffers que Hyprland pueda componer. Solo
# renderizan los clientes que usan wl_shm (foot). Con llvmpipe funcionan todos.
# Comprobado que NO lo arreglan: AQ_NO_MODIFIERS, render:cm_enabled=false,
# render:explicit_sync (eliminado en Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# consola serie util para depurar desde el host
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

log "$(msg stage2_cleanup)"
rm -f /etc/sudoers.d/99-install
paccache -rk1 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

log "$(msg stage2_summary)"
echo "  kernel:    $(pacman -Q linux-aarch64 2>/dev/null || echo '?')"
echo "  hyprland:  $(pacman -Q hyprland 2>/dev/null || echo "$(msg stage2_not_installed)")"
echo "  sddm:      $(pacman -Q sddm 2>/dev/null || echo "$(msg stage2_not_installed)")"
echo "  mesa:      $(pacman -Q mesa 2>/dev/null || echo '?')"
echo "  $(msg stage2_user_label): $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || echo "$(msg stage2_missing)")"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] $(msg stage2_completed)"
