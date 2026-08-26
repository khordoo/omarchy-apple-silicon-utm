#!/bin/bash
# Hook post-update para instalaciones ARM.
#
# En esta instalacion Omarchy no viene de su paquete pacman (que solo existe
# para x86_64) sino de un checkout de git. omarchy-update-dev solo hace `git
# pull` cuando OMARCHY_PATH apunta FUERA de /usr/share/omarchy, y aqui apunta
# justo ahi, asi que sin este hook el arbol de Omarchy no se actualizaria nunca:
# el sistema recibiria paquetes nuevos pero los scripts, temas y configuracion
# de Omarchy se quedarian congelados en la version clonada.
set -uo pipefail
if [ -z "${OMARCHY_LANG+x}" ] && [ -r /etc/omarchy-arm-language ]; then
  OMARCHY_LANG=$(cat /etc/omarchy-arm-language)
fi
export OMARCHY_LANG
if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" /usr/local/share/omarchy/catalog.sh /root/prov/catalog.sh /media/prov/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }
TREE=/usr/share/omarchy

git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# El arbol puede ser del usuario (VM de desarrollo) o de root (imagen distribuida)
if [ -w "$TREE/.git" ]; then GIT=(git -C "$TREE"); else GIT=(sudo git -C "$TREE"); fi

echo -e "\e[32m\n$(msg armsync_title)\e[0m"
before=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if ! "${GIT[@]}" pull --ff-only 2>&1 | sed 's/^/  /'; then
  echo "  $(msg armsync_pull_failed)"
  exit 0
fi
after=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if [ "$before" = "$after" ]; then echo "  $(msg armsync_current "$after")"; exit 0; fi
echo "  $before → $after"

# Enlazar los binarios nuevos, respetando los envoltorios propios de ARM
# (omarchy-pkg-add es un fichero real, no un enlace: no debe pisarse).
n=0
for f in "$TREE"/bin/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); t="/usr/local/bin/$b"
  [ -e "$t" ] && [ ! -L "$t" ] && continue
  [ -L "$t" ] && continue
  sudo ln -sfn "$f" "$t" 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && echo "  $(msg armsync_linked_path "$n" /usr/local/bin)"
sudo find /usr/local/bin -xtype l -delete 2>/dev/null || true
exit 0
