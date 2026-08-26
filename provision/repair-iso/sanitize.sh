#!/bin/bash
# Sanitizado para distribucion: quita todo lo identificativo del sistema y deja
# un usuario generico. Se ejecuta como ROOT dentro del chroot.
set -uo pipefail
if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" /root/prov/catalog.sh /usr/local/share/omarchy/catalog.sh /media/prov/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }
if [ -f /root/prov/catalog.sh ]; then
  install -Dm644 /root/prov/catalog.sh /usr/local/share/omarchy/catalog.sh
elif [ -f /media/prov/catalog.sh ]; then
  install -Dm644 /media/prov/catalog.sh /usr/local/share/omarchy/catalog.sh
fi
printf '%s\n' "${OMARCHY_LANG:-en}" > /etc/omarchy-arm-language
OLD="${DIST_OLD_USER:-gabriel}"
NEW="${DIST_NEW_USER:-omarchy}"
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "$(msg sanitize_step1)"
# Era un symlink a /home/gabriel/.local/share/omarchy, lo que ata el sistema a
# ese usuario. Se convierte en directorio real (como haria el paquete pacman) y
# el home pasa a apuntar ahi.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  cp -a "$TARGET" /usr/share/omarchy
  chown -R root:root /usr/share/omarchy
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy ahora es un directorio real ($(du -sh /usr/share/omarchy | cut -f1))"
fi

log "$(msg sanitize_step2 "$OLD" "$NEW")"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# el home del usuario apunta al arbol del sistema
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "$(msg sanitize_step3)"
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$NEW
Session=omarchy
EOF
grep -rl "$OLD" /etc/sddm.conf.d/ 2>/dev/null | while read -r f; do sed -i "s/\b$OLD\b/$NEW/g" "$f"; done
cat /etc/sddm.conf.d/20-autologin.conf

log "$(msg sanitize_step4)"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # se regeneran solas en el primer arranque
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "$(msg sanitize_step5)"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "$(msg sanitize_step6)"
rm -f "/home/$NEW/.gitconfig" "/home/$NEW/.config/git/config"
rm -f "/home/$NEW/.bash_history" "/home/$NEW/.zsh_history" "/home/$NEW/.local/share/fish/fish_history"
rm -rf "/home/$NEW/.cache" "/home/$NEW/.local/state/omarchy/first-run.log"
rm -rf "/home/$NEW/.local/share/omarchy-"* 2>/dev/null || true
rm -rf "/home/$NEW/shots" "/home/$NEW"/*.sh "/home/$NEW/config.env" 2>/dev/null || true
# NetworkManager: quita redes wifi guardadas
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "$(msg sanitize_step7b)"
# Estas se instalan con omarchy-arm-extras en la maquina del usuario final.
# Empaquetarlas en un .zip que se reparte seria redistribuir binarios de
# terceros, asi que se retiran aunque estuvieran en la VM de origen.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  $(msg sanitize_removed "$pkg")"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  $(msg sanitize_removed_path "$d")"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Los rastros que dejan al instalarse: si se retira Chrome hay que retirar
# tambien el atajo y el lanzador de la webapp de Spotify, que lo invocan. Si no,
# la imagen sale con un SUPER+SHIFT+M que apunta a un binario inexistente.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify no tiene cliente nativo/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  $(msg sanitize_spotify_binding_removed)"
fi
rm -f "/home/$NEW/.local/share/applications/Spotify.desktop" \
      "/home/$NEW/.local/share/applications/spotify.desktop" 2>/dev/null || true
rm -rf "/home/$NEW/.local/share/omarchy/webapps" 2>/dev/null || true
echo "  ($(msg sanitize_reinstall_with))"

log "$(msg sanitize_step7)"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
rm -rf /root/prov /root/.bash_history /root/.cache 2>/dev/null || true

log "$(msg sanitize_step8)"
{
  printf '%s\n' "$(msg sanitize_motd_title)"
  printf '%s\n' "$(msg sanitize_motd_credentials "$NEW" "$NEW")"
  printf '%s\n' "$(msg sanitize_motd_change_password)"
  printf '%s\n' "$(msg sanitize_motd_keys)"
  printf '%s\n' "$(msg sanitize_motd_shortcuts)"
  printf '%s\n' "$(msg sanitize_motd_missing_apps)"
  printf '%s\n' "$(msg sanitize_motd_license)"
  printf '%s\n' "$(msg sanitize_motd_extras_list)"
  printf '%s\n' "$(msg sanitize_motd_extras_menu)"
} > /etc/motd
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/LEEME.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/LEEME.txt"

log "$(msg sanitize_step8a)"
# omarchy-update-dev no actualiza el arbol cuando OMARCHY_PATH es
# /usr/share/omarchy, que es nuestro caso: sin este hook Omarchy se congela.
if [ -f /root/prov/10-arm-sync ]; then
  install -Dm755 /root/prov/10-arm-sync "/home/$NEW/.config/omarchy/hooks/post-update.d/10-arm-sync"
  chown -R "$NEW:$NEW" "/home/$NEW/.config/omarchy/hooks" 2>/dev/null || true
  echo "  post-update.d/10-arm-sync"
fi
# El checkout no debe ensuciarse por cambios de permisos, o el pull fallara
git -C /usr/share/omarchy config core.fileMode false 2>/dev/null || true
git -C /usr/share/omarchy checkout -- . 2>/dev/null || true
echo "  checkout limpio: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) ficheros"

log "$(msg sanitize_step8b)"
# repair.sh copia extras.sh como omarchy-arm-extras, pero si esa copia no
# ocurriera el bloque entero se saltaba en silencio y la imagen salia sin la
# entrada de menu. Se aceptan los dos nombres y se avisa si falta.
EXTRAS_SRC=""
for c in /root/prov/omarchy-arm-extras /root/prov/extras.sh; do
  [ -f "$c" ] && { EXTRAS_SRC="$c"; break; }
done
if [ -n "$EXTRAS_SRC" ]; then
  install -Dm755 "$EXTRAS_SRC" /usr/local/bin/omarchy-arm-extras
  install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=$(msg desktop_name)
Comment=1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  chown "$NEW:$NEW" /usr/local/share/applications/omarchy-arm-extras.desktop 2>/dev/null || true
  echo "  $(msg sanitize_extras_ready)"
else
  warn "$(msg sanitize_extras_missing)"
fi

log "$(msg sanitize_step9 "$OLD")"
echo "  $(msg sanitize_refs_etc):"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    $(msg sanitize_none)"
echo "  $(msg sanitize_home):"; ls -ld "/home/$NEW"; ls /home/
echo "  $(msg sanitize_loose_files):"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    $(msg sanitize_all_ok)"

log "$(msg sanitize_step10)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "$(msg sanitize_backups)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "$(msg sanitize_subid)"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "$(msg sanitize_final_scan "$OLD")"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    $(msg sanitize_none)"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    $(msg sanitize_none)"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    $(msg sanitize_none)"
echo "  /usr/share/omarchy (no debe apuntar a /home):"; ls -ld /usr/share/omarchy

log "$(msg sanitize_consistency)"
echo "  $(msg sanitize_passwd): $(getent passwd $NEW)"
echo "  $(msg sanitize_home_label):   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  $(msg sanitize_symlink): $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  $(msg sanitize_binaries): $(ls /usr/local/bin | wc -l)"
echo "  ttfx: $(command -v ttfx || echo "$(msg sanitize_no)")"
echo "  migraciones selladas: $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
log "$(msg sanitize_bookmarks)"
for f in /home/$NEW/.config/gtk-3.0/bookmarks /home/$NEW/.config/gtk-4.0/bookmarks; do
  [ -f "$f" ] && { sed -i "s#/home/$OLD#/home/$NEW#g" "$f"; echo "  $f:"; cat "$f"; }
done

log "$(msg sanitize_real_name)"
chfn -f "Omarchy" "$NEW" 2>/dev/null || usermod -c "Omarchy" "$NEW"
getent passwd "$NEW"

log "$(msg sanitize_user_dirs)"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/$OLD#/home/$NEW#g" "$f"
done

log "$(msg sanitize_symlinks)"
# grep -rl solo mira el CONTENIDO de los ficheros: el destino de un enlace
# simbolico no es contenido, asi que el barrido de texto los da por limpios.
# Omarchy guarda el tema y el fondo activos como enlaces
# (~/.local/state/omarchy/current/{theme,background}), de modo que un enlace
# colgado deja el escritorio en gris y sin estilo, sin ningun error visible.
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/local /opt -xdev -type l \
  -lname "*/home/$OLD/*" 2>/dev/null)
echo "  encontrados: ${#BADLINKS[@]}"
for l in "${BADLINKS[@]:-}"; do
  [ -n "$l" ] || continue
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
  echo "  $l -> $(readlink "$l")"
done
chown -h $NEW:$NEW "${BADLINKS[@]:-/home/$NEW}" 2>/dev/null || true

log "$(msg sanitize_final_check)"
echo "  /etc:   $(grep -rl "\b$OLD\b" /etc 2>/dev/null | wc -l) $(msg sanitize_matches)"
echo "  /home:  $(grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc /home/$NEW/.bash_profile 2>/dev/null | wc -l) $(msg sanitize_matches)"
echo "  $(msg sanitize_old_home_links) /home/$OLD: $(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  $(msg sanitize_broken_links): $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  $(msg sanitize_active_background): $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo "$(msg sanitize_none_upper)")"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  $(msg sanitize_background_resolves): $(msg sanitize_ok)" || echo "  $(msg sanitize_background_resolves): $(msg sanitize_broken)"
echo "  $(msg sanitize_ttfx_note1)"
echo "  $(msg sanitize_ttfx_note2)"

log "$(msg sanitize_distribution_state)"
echo "  $(msg sanitize_user):    $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:  $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:       $(systemctl is-enabled sshd 2>&1)"
echo "  $(msg sanitize_optional_installer): $(test -x /usr/local/bin/omarchy-arm-extras && msg sanitize_yes || msg sanitize_missing)"
echo "  $(msg sanitize_menu_entry):     $(test -f /usr/local/share/applications/omarchy-arm-extras.desktop && msg sanitize_yes || msg sanitize_missing)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes (vacio = se regenera)"
echo ""
echo "  $(msg sanitize_do_not_boot_1)"
echo "  $(msg sanitize_do_not_boot_2)"
echo "  $(msg sanitize_do_not_boot_3)"
echo "  $(msg sanitize_do_not_boot_4)"
echo "  $(msg sanitize_host_keys): $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = $(msg sanitize_regenerated))"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true
echo ""
echo ""
echo "==> SANITIZE_OK"
