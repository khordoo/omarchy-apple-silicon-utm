#!/bin/bash
#
#  omarchy-arm-extras — instala en Arch Linux ARM apps que no vienen en la imagen
#  ───────────────────────────────────────────────────────────────────────────
#  Las propietarias NO se distribuyen dentro a proposito: empaquetarlas en un
#  .zip que se reparte seria redistribuir binarios de terceros. Este script las
#  descarga de su fuente OFICIAL, en tu maquina y bajo tu criterio.
#
#  Casi todas tienen build arm64 oficial. Las que ya vienen dentro de la imagen
#  (software libre) se marcan como [ya instalada] y se omiten.
#
#  Uso:
#    omarchy-arm-extras                    menu interactivo
#    omarchy-arm-extras --list             ver que puede instalar
#    omarchy-arm-extras 1password obsidian instalar elementos concretos
#    omarchy-arm-extras --all              todo lo que falte
#    omarchy-arm-extras --force <clave>    reinstalar aunque ya este
#
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

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
title() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
fail()  { echo "  ${c_err}✗${c_off} $*" >&2; }

# /tmp es tmpfs y esta limitado por la RAM: compilar .NET u OBS ahi se queda
# sin espacio a medias. Se trabaja en disco real.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalogo ────────────────────────────────────────────────────────────────
#  clave|titulo|descripcion
CATALOG=(
  "1password|app_1password|app_1password_desc"
  "1password-cli|app_1password_cli|app_1password_cli_desc"
  "obsidian|app_obsidian|app_obsidian_desc"
  "typora|app_typora|app_typora_desc"
  "localsend|app_localsend|app_localsend_desc"
  "chrome|app_chrome|app_chrome_desc"
  "spotify-web|app_spotify|app_spotify_desc"
  "pinta|app_pinta|app_pinta_desc"
  "obs|app_obs|app_obs_desc"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { local k; k=$(printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'); msg "$k"; }
catalog_desc()  { local k; k=$(printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $3}'); msg "$k"; }

usage() {
  cat <<EOF
$(msg extras_help_title)

  omarchy-arm-extras                    $(msg extras_help_menu)
  omarchy-arm-extras --list             $(msg extras_help_list)
  omarchy-arm-extras 1password obsidian $(msg extras_help_specific)
  omarchy-arm-extras --all              $(msg extras_help_all)
  omarchy-arm-extras --force <key>      $(msg extras_help_force)
EOF
}

# ── utilidades ──────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Pinta y OBS Studio son software libre y viajan dentro de la imagen; el resto
# no. Sin esta comprobacion, `--all` recompilaria OBS entero (media hora) para
# reinstalar lo que ya esta.
is_installed() {
  case "$1" in
    1password)     pacman -Q 1password        >/dev/null 2>&1 || [ -d /opt/1Password ] ;;
    1password-cli) have op ;;
    obsidian)      [ -d /opt/obsidian ] ;;
    typora)        pacman -Q typora           >/dev/null 2>&1 ;;
    localsend)     pacman -Q localsend-bin    >/dev/null 2>&1 ;;
    chrome)        pacman -Q google-chrome    >/dev/null 2>&1 || have google-chrome-stable ;;
    spotify-web)   grep -q "open.spotify.com" "$HOME/.config/hypr/bindings.lua" 2>/dev/null ;;
    pinta)         pacman -Q pinta            >/dev/null 2>&1 ;;
    obs)           pacman -Q obs-studio       >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  info "$(msg extras_need_sudo)"
  sudo -v || { fail "$(msg extras_no_privileges)"; return 1; }
}

# Construye un paquete de AUR resolviendo las trampas habituales en ARM:
#  · la URL de clonado usa el PackageBase, que no siempre es el nombre
#  · muchos PKGBUILD declaran arch=(x86_64) por omision, no por incompatibilidad
#  · un PKGBUILD puede generar varios subpaquetes y solo uno tener la dependencia rota
aur_build() {
  # Un unico `local` expande TODOS los valores antes de asignar ninguno, asi que
  # $pkg no existiria al construir $dir y con set -u el script aborta.
  local pkg="$1" want="${2:-$1}"
  local dir="$WORK/$pkg" base
  pacman -Q "$want" >/dev/null 2>&1 && { ok "$(msg extras_already_installed "$want")"; return 0; }

  base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
         | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$base" ] || base="$pkg"

  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
  [ -f "$dir/PKGBUILD" ] || { fail "$(msg extras_clone_failed "$pkg" "$base")"; return 1; }

  # Varios PKGBUILD verifican la firma del upstream en check(). Si la clave no
  # esta en el llavero, makepkg aborta. Se importan las que el propio PKGBUILD
  # declara, en vez de saltarse la verificacion.
  local keys k
  keys=$(sed -n '/^validpgpkeys=(/,/)/p' "$dir/PKGBUILD" | grep -oE '[0-9A-Fa-f]{40}')
  for k in $keys; do
    [ ${#k} -ge 16 ] || continue
    gpg --list-keys "$k" >/dev/null 2>&1 && continue
    info "$(msg extras_import_key "${k: -8}")"
    gpg --keyserver keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 \
      || warn "$(msg extras_key_failed "${k: -8}")"
  done

  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    info "$(msg extras_arch_patched)"
  fi

  ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  fail "$(msg extras_build_failed "$pkg" "$dir/build.log")"
  tail -5 "$dir/build.log" | sed 's/^/      /'
  return 1
}

# ── instaladores ────────────────────────────────────────────────────────────

do_1password() {
  title "1Password"
  info "$(msg extras_1password_info)"
  local url=https://downloads.1password.com/linux/tar/stable/aarch64/1password-latest.tar.gz
  mkdir -p "$WORK"; rm -rf "$WORK/1p"; mkdir -p "$WORK/1p"
  curl -fL --progress-bar "$url" -o "$WORK/1p/1p.tar.gz" || { fail "$(msg extras_download_failed)"; return 1; }
  # Es un gestor de contrasenas: se verifica la firma antes de instalarlo.
  local KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
  if curl -fsSL "$url.sig" -o "$WORK/1p/1p.tar.gz.sig" 2>/dev/null; then
    gpg --list-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keyserver.ubuntu.com --recv-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$KEY" >/dev/null 2>&1
    if gpg --verify "$WORK/1p/1p.tar.gz.sig" "$WORK/1p/1p.tar.gz" >/dev/null 2>&1; then
      ok "$(msg extras_signature_ok)"
    else
      fail "$(msg extras_signature_bad)"; return 1
    fi
  else
    warn "$(msg extras_signature_missing)"
  fi
  tar -xzf "$WORK/1p/1p.tar.gz" -C "$WORK/1p" || { fail "$(msg extras_extract_failed)"; return 1; }
  local src; src=$(find "$WORK/1p" -maxdepth 1 -type d -name '1password-*' | head -1)
  [ -n "$src" ] || { fail "$(msg extras_archive_invalid)"; return 1; }
  sudo mkdir -p /opt/1Password
  sudo cp -a "$src"/. /opt/1Password/
  ( cd /opt/1Password && sudo ./after-install.sh ) >/dev/null 2>&1 || warn "$(msg extras_postinstall_warning)"
  have 1password && ok "$(1password --version 2>/dev/null | head -1 || msg extras_installed)" || { fail "$(msg extras_not_in_path)"; return 1; }
  info "${c_dim}$(msg extras_wayland_hint)${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "$(msg extras_obsidian_info)"
  # OJO: releases/latest puede ser una release SOLO de Android (un .apk suelto).
  # Hay que buscar la ultima que publique de verdad el tarball arm64 de escritorio.
  local url
  url=$(curl -fsSL --max-time 30 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=15" \
        | grep -oE '"browser_download_url": *"[^"]*obsidian-[0-9.]+-arm64\.tar\.gz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [ -n "$url" ] || { fail "$(msg extras_obsidian_missing)"; return 1; }
  info "$(basename "$url")"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url" -o "$WORK/obsidian.tar.gz" || { fail "$(msg extras_download_failed)"; return 1; }
  sudo rm -rf /opt/obsidian; sudo mkdir -p /opt/obsidian
  sudo tar -xzf "$WORK/obsidian.tar.gz" -C /opt/obsidian --strip-components=1 || { fail "$(msg extras_extract_failed)"; return 1; }
  sudo ln -sfn /opt/obsidian/obsidian /usr/local/bin/obsidian
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/obsidian.desktop <<'DESK'
[Desktop Entry]
Name=Obsidian
Exec=obsidian --ozone-platform-hint=auto %u
Icon=obsidian
Type=Application
Categories=Office;
MimeType=x-scheme-handler/obsidian;
DESK
  [ -f /opt/obsidian/resources/app.asar ] && sudo find /opt/obsidian -name 'icon.png' -exec \
    sudo install -Dm644 {} /usr/local/share/icons/hicolor/512x512/apps/obsidian.png \; 2>/dev/null
  ok "$(msg extras_obsidian_ok "$(basename "$url")")"
}

do_typora() {
  title "Typora"
  info "$(msg extras_typora_info)"
  aur_build typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "$(msg extras_chrome_info)"
  info "$(msg extras_chromium_info)"
  aur_build google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}$(msg extras_widevine_hint)${c_off}"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy trata Spotify como paquete nativo, no como webapp — y ese paquete es
  # x86_64. En ARM la via que funciona es la web, que necesita Widevine.
  if ! have google-chrome-stable; then
    warn "$(msg extras_spotify_chrome_required)"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "$(msg extras_launcher_ok)"
  else
    warn "$(msg extras_webapp_missing)"
  fi
  # Reasignar SUPER+SHIFT+M, que en Omarchy apunta al binario nativo
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify no tiene cliente nativo para aarch64: SUPER+SHIFT+M abre la webapp.
-- Necesita Google Chrome, que es quien trae Widevine en arm64.
o.bind("SUPER + SHIFT + M", "Spotify", o.launch("google-chrome-stable --app=https://open.spotify.com"))
LUA
    ok "$(msg extras_spotify_binding_ok)"
  fi
  info "${c_dim}$(msg extras_spotify_terminal)${c_off}"
}

do_pinta() {
  title "Pinta"
  info "$(msg extras_pinta_info)"
  info "$(msg extras_pinta_install_info)"
  aur_build dotnet-runtime-bin dotnet-runtime-bin || { fail "$(msg extras_pinta_runtime_missing)"; return 1; }
  local url=https://geo.mirror.pkgbuild.com/extra/os/x86_64/
  local file; file=$(curl -fsSL --max-time 30 "$url" | grep -o 'pinta-[0-9][^"]*-any\.pkg\.tar\.zst' | sort -V | tail -1)
  [ -n "$file" ] || { fail "$(msg extras_pinta_missing)"; return 1; }
  info "$file  ${c_dim}($(msg extras_path_arch_any))${c_off}"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url$file" -o "$WORK/$file" || return 1
  sudo pacman -U --noconfirm "$WORK/$file" >/dev/null 2>&1 && ok "$(pacman -Q pinta)" || { fail "$(msg extras_pacman_failed)"; return 1; }
  warn "$(msg extras_manual_updates)"
}

do_obs() {
  title "OBS Studio"
  info "$(msg extras_obs_info)"
  info "$(msg extras_obs_browser_info)"
  warn "$(msg extras_obs_slow)"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git "$dir" \
    || { fail "$(msg extras_arch_clone_failed)"; return 1; }
  cd "$dir" || return 1
  sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" PKGBUILD
  # OJO: 'cef' va en la MISMA linea que makedepends=, no en una propia, asi que
  # hay que quitarlo como token y no como linea completa.
  sed -i "s/'cef'[[:space:]]*//g" PKGBUILD
  sed -i "/cef_api_versions\.h/d; /-DCEF_API_VERSION/d; /_cef_api_version/d" PKGBUILD
  sed -i 's/-DENABLE_BROWSER=ON/-DENABLE_BROWSER=OFF/' PKGBUILD
  # package_obs-studio() aparta los ficheros del plugin de navegador para el
  # subpaquete aparte. Sin browser esos ficheros no existen y el `mv` aborta el
  # empaquetado DESPUES de haber compilado todo: hay que quitar esas dos lineas.
  sed -i '/mv \$pkgdir\/usr\/lib\/obs-plugins\/{obs-browser-page,obs-browser.so}/d' PKGBUILD
  sed -i '/mv \$pkgdir\/usr\/share\/obs\/obs-plugins\/obs-browser /d' PKGBUILD
  # y los parches del plugin, que ya no se aplican a nada
  sed -i '/patch -d plugins\/obs-browser/d' PKGBUILD
  # NO se tocan source=() ni sha256sums=(): borrar entradas de una sin la otra
  # hace que makepkg aborte con "Integrity checks differ in size from the source
  # array". Descargar obs-browser de mas es solo ancho de banda.
  sed -i '/INSTALL_RPATH.*cef/d' PKGBUILD
  # El subpaquete del navegador ya no se genera
  sed -i '/^package_obs-studio-plugin-browser()/,/^}/d' PKGBUILD
  sed -i "s/^pkgname=(.*)/pkgname=('obs-studio')/" PKGBUILD
  info "PKGBUILD parcheado: aarch64, sin CEF, sin plugin de navegador"
  if makepkg -si --noconfirm --needed --noprogressbar >"$dir/build.log" 2>&1; then
    ok "$(pacman -Q obs-studio)"
    info "${c_dim}$(msg extras_no_hw_accel)${c_off}"
  else
  fail "$(msg extras_build_failed_generic "$dir/build.log")"
    tail -6 "$dir/build.log" | sed 's/^/      /'
    return 1
  fi
}

run_item() {
  local k="$1"
  if [ "${FORCE:-0}" != "1" ] && is_installed "$k"; then
    title "$(catalog_title "$k")"
    ok "$(msg extras_already_in_image)"
    return 0
  fi
  case "$k" in
    1password)     do_1password ;;
    1password-cli) do_1password_cli ;;
    obsidian)      do_obsidian ;;
    typora)        do_typora ;;
    localsend)     do_localsend ;;
    chrome)        do_chrome ;;
    spotify-web)   do_spotify_web ;;
    pinta)         do_pinta ;;
    obs)           do_obs ;;
    *) fail "$(msg extras_unknown_key "$k")"; return 1 ;;
  esac
}

show_list() {
  echo
  echo "${c_hi}$(msg extras_list_title)${c_off}"
  echo "${c_dim}$(msg extras_list_explanation_1)"
  echo "$(msg extras_list_explanation_2)"
  echo "$(msg extras_list_explanation_3)${c_off}"
  echo
  local k
  while read -r k; do
    if is_installed "$k"; then
      printf "  ${c_hi}%-15s${c_off} %s ${c_dim}[%s]${c_off}\n" "$k" "$(catalog_desc "$k")" "$(msg extras_installed_marker)"
    else
      printf "  ${c_hi}%-15s${c_off} %s\n" "$k" "$(catalog_desc "$k")"
    fi
  done < <(catalog_keys)
  echo
  echo "${c_dim}$(msg extras_usage)${c_off}"
  echo
}

# ── main ────────────────────────────────────────────────────────────────────
SELECTED=()
FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then FORCE=1; shift; fi
case "${1:-}" in
  --list|-l) show_list; exit 0 ;;
  --all|-a)  mapfile -t SELECTED < <(catalog_keys) ;;
  -h|--help) usage; exit 0 ;;
  "")
    if have gum; then
      show_list
      mapfile -t SELECTED < <(
        while read -r k; do printf '%s — %s\n' "$k" "$(catalog_title "$k")"; done < <(catalog_keys) \
        | gum choose --no-limit --header "$(msg extras_choose_header)" \
        | cut -d' ' -f1
      )
    else
      show_list; exit 0
    fi ;;
  *) SELECTED=("$@") ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { info "$(msg extras_nothing_selected)"; exit 0; }

need_sudo || exit 1
mkdir -p "$WORK"

for k in "${SELECTED[@]}"; do
  [ -z "$k" ] && continue
  if run_item "$k"; then OK_LIST+=("$k"); else KO_LIST+=("$k"); fi
done

title "$(msg extras_summary)"
[ ${#OK_LIST[@]} -gt 0 ] && ok "$(msg extras_installed_list "${OK_LIST[*]}")"
if [ ${#KO_LIST[@]} -gt 0 ]; then
  fail "$(msg extras_failed_list "${KO_LIST[*]}")"
  # No se borra el directorio de trabajo: dentro estan los build.log, que son
  # lo unico que permite averiguar por que fallo.
  info "$(msg extras_logs "$WORK/<package>/build.log")"
else
  rm -rf "$WORK"
fi
echo
