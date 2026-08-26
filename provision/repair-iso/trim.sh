#!/bin/bash
# Quita peso muerto: dependencias que solo hacian falta para COMPILAR.
set -uo pipefail
if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" /usr/local/share/omarchy/catalog.sh /root/prov/catalog.sh /media/prov/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }
NEW=omarchy
log(){ echo; echo "==> $*"; }

log "$(msg trim_before)"
df -h / | tail -1

log "$(msg trim_largest)"
expac -H M '%m\t%n' 2>/dev/null | sort -rh | head -12 | sed 's/^/  /'

log "$(msg trim_build_deps)"
# Pinta necesita dotnet-runtime, NO el SDK. OBS ya esta compilado.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  $(msg trim_removed "$p")" || echo "  $(msg trim_remove_failed "$p")"; }
done
orph=$(pacman -Qdtq 2>/dev/null)
[ -n "$orph" ] && { echo "  $(msg trim_orphans): $(echo $orph | tr '\n' ' ')"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }

log "$(msg trim_check)"
for p in obs-studio pinta dotnet-runtime-bin hyprland quickshell; do
  printf "  %-20s %s\n" "$p" "$(pacman -Q $p 2>/dev/null || msg trim_missing)"
done
command -v obs pinta omarchy-arm-extras | sed 's/^/  /'

log "$(msg trim_final)"
rm -rf /var/cache/pacman/pkg/* /home/$NEW/.cache/* /tmp/* 2>/dev/null
rm -rf /home/$NEW/.cargo /home/$NEW/go 2>/dev/null
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
sync; fstrim -av 2>&1 | head -2
df -h / | tail -1
echo ""
echo "==> TRIM_OK"
