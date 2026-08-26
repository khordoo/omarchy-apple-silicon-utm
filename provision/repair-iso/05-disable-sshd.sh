#!/bin/bash
# Fleco 2: revertir el acceso SSH que habilite solo para aprovisionar.
# Se ejecuta como ROOT dentro del chroot.
set -uo pipefail
if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" /usr/local/share/omarchy/catalog.sh /root/prov/catalog.sh /media/prov/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }
USR=gabriel
log() { echo ""; echo "==> $*"; }

log "$(msg sshd_disable)"
systemctl disable sshd.service 2>&1 | tail -2 || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
echo "  enabled: $(systemctl is-enabled sshd 2>&1)"

log "$(msg sshd_sudoers)"
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
ls -l /etc/sudoers.d/
visudo -c -q && echo "  $(msg sshd_sudoers_valid)"

log "$(msg sshd_host_key)"
# Reactivar el acceso: sudo systemctl enable --now sshd
ls -l /home/$USR/.ssh/authorized_keys 2>&1

log "$(msg sshd_cleanup)"
rm -rf /root/prov /root/STAGE2_OK /home/$USR/shots
rm -f /tmp/*.log 2>/dev/null || true

log "$(msg sshd_check)"
echo "  sshd:      $(systemctl is-enabled sshd 2>&1)"
echo "  qemu-ga:   $(systemctl is-enabled qemu-guest-agent 2>&1)"
echo "  sddm:      $(systemctl is-enabled sddm 2>&1)"
echo ""
echo "==> FIX5_OK"
