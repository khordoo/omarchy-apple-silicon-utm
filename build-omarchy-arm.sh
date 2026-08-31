#!/usr/bin/env bash
#
#  build-omarchy-arm.sh
#  ────────────────────────────────────────────────────────────────────────────
#  Construye, de forma autonoma y sin intervencion, una maquina virtual UTM con
#  Arch Linux ARM (aarch64 nativo, acelerado con HVF) + Hyprland + la
#  configuracion de Omarchy 4, y la empaqueta para distribuir.
#
#  Omarchy 4 NO se puede instalar en ARM64: su guard aborta si uname -m no es
#  x86_64, su mirror no sirve aarch64 y su paquete pacman es x86_64-only. Esto
#  reconstruye el equivalente sobre Arch Linux ARM y le aplica el contenido real
#  del repositorio de Omarchy.
#
#  Uso:
#    ./build-omarchy-arm.sh                  # todas las fases
#    ./build-omarchy-arm.sh --from build     # reanudar desde una fase
#    ./build-omarchy-arm.sh --only package   # ejecutar solo una fase
#    ./build-omarchy-arm.sh --list           # listar fases
#
#  Fases:
#    deps      comprobar dependencias del anfitrion
#    fetch     descargar Alpine ISO + rootfs ALARM (con verificacion MD5)
#    prepare   calcular la lista de paquetes desde la rama viva de Omarchy
#    build     construir el disco (headless, QEMU + HVF, tres etapas en chroot)
#    utm       crear el bundle .utm y registrarlo en UTM
#    verify    arrancar y verificar por consola serie
#    sanitize  limpiar una copia para distribuirla
#    package   compactar, comprimir y firmar con sha256
#
#  Requisitos: macOS en Apple Silicon, Homebrew, UTM 4.7+, Command Line Tools
#  (git, python3) y ~40 GB libres. No necesita sudo.
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ───────────────────────────────── parametros ──────────────────────────────
# Remember explicit regional choices before applying fallbacks. Host detection
# must not overwrite values supplied for a reproducible distribution build.
VM_TIMEZONE_EXPLICIT=${VM_TIMEZONE+x}
VM_KEYMAP_EXPLICIT=${VM_KEYMAP+x}
VM_XKB_EXPLICIT=${VM_XKB+x}
: "${W:=$HOME/omarchy-arm-build}"        # directorio de trabajo
: "${VM_NAME:=Omarchy ARM}"              # nombre de la VM en UTM
: "${VM_USER:=builder}"                  # usuario durante la construccion
: "${VM_PASSWORD:=builder}"              # se pregunta; la imagen distribuible lo renombra
: "${VM_FULLNAME:=Omarchy ARM}"
: "${VM_EMAIL:=usuario@ejemplo.com}"
: "${VM_HOSTNAME:=omarchy}"
: "${VM_TIMEZONE:=UTC}"
: "${VM_KEYMAP:=us}"                     # consola de texto
: "${VM_XKB:=us}"                        # Hyprland/Wayland
: "${VM_LOCALE:=en_US.UTF-8}"
: "${VM_LOCALE_EXTRA:=es_ES.UTF-8}"
: "${DISK_SIZE:=80G}"
: "${BUILD_SMP:=8}"                      # vCPU durante la construccion
: "${BUILD_MEM:=8192}"                   # MiB durante la construccion
: "${UTM_CPUS:=6}"                       # vCPU de la VM final
: "${UTM_MEM:=6144}"                     # MiB de la VM final
: "${OMARCHY_REF:=quattro}"              # rama de Omarchy (¡NO master!)
: "${DIST_NEW_USER:=omarchy}"            # usuario en la imagen distribuible
: "${ALPINE_VER:=v3.24}"
: "${ALPINE_ISO:=alpine-virt-3.24.1-aarch64.iso}"
: "${ALARM_URL:=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"

# ── self-contained localization catalog ────────────────────────────────────
# OMARCHY_LOCALIZATION_CATALOG is kept in sync with localization/catalog.sh.
# Do not source a file here: this builder is intentionally distributable as one
# standalone script.  The catalog uses only Bash 3.2 features.
# OMARCHY_LOCALIZATION_CATALOG
omarchy_msg() {
  local key="${1:-}"; shift || true
  local text
  if [ -z "${OMARCHY_LANG:-}" ] && [ -r /etc/omarchy-arm-language ]; then
    OMARCHY_LANG=$(cat /etc/omarchy-arm-language 2>/dev/null || true)
  fi
  case "${OMARCHY_LANG:-en}:$key" in
    en:usage) text='Usage: ./build-omarchy-arm.sh [options]\n\nOptions:\n  --lang en|es       Installer language (default: English)\n  --from PHASE       Resume from a phase\n  --only PHASE       Run one phase\n  --list             List phases\n  --yes              Accept defaults and run without prompts\n  -h, --help         Show this help\n' ;;
    es:usage) text='Uso: ./build-omarchy-arm.sh [opciones]\n\nOpciones:\n  --lang en|es       Idioma del instalador (por defecto: ingles)\n  --from FASE        Reanudar desde una fase\n  --only FASE        Ejecutar una fase\n  --list             Listar fases\n  --yes              Aceptar valores y ejecutar sin preguntas\n  -h, --help         Mostrar esta ayuda\n' ;;
    en:build_login) text='the Alpine live did not reach the login' ;;
    es:build_login) text='el live de Alpine no llego al login' ;;
    en:build_shell) text='no Alpine root shell' ;;
    es:build_shell) text='no hay shell de root en Alpine' ;;
    en:build_prompt) text='could not set the prompt' ;;
    es:build_prompt) text='no se pudo fijar el prompt' ;;
    en:build_iso) text='provisioning ISO not found' ;;
    es:build_iso) text='no se encontro el ISO de aprovisionamiento' ;;
    en:build_rootfs) text='Arch Linux ARM rootfs missing from the ISO' ;;
    es:build_rootfs) text='falta el rootfs de Arch Linux ARM en el ISO' ;;
    en:build_tail) text='tail' ;;
    es:build_tail) text='tail' ;;
    en:build_success) text='   BUILD COMPLETED' ;;
    es:build_success) text='   CONSTRUCCION COMPLETADA' ;;
    en:build_failed) text='!!!!!! BUILD FAILED !!!!!!' ;;
    es:build_failed) text='!!!!!! LA CONSTRUCCION FALLO !!!!!!' ;;
    en:build_eof) text='EOF during build' ;;
    es:build_eof) text='EOF durante la construccion' ;;
    en:build_shutdown) text='===== BUILD VM SHUT DOWN =====' ;;
    es:build_shutdown) text='===== VM DE CONSTRUCCION APAGADA =====' ;;
    en:verification) text='verification' ;;
    es:verification) text='verificacion' ;;
    en:verify_heading) text='==== VERIFICATION ====' ;;
    es:verify_heading) text='==== VERIFICACION ====' ;;
    en:verify_esp) text='-- ESP --' ;;
    es:verify_esp) text='-- ESP --' ;;
    en:verify_kernel) text='-- kernel --' ;;
    es:verify_kernel) text='-- kernel --' ;;
    en:verify_user) text='-- user --' ;;
    es:verify_user) text='-- usuario --' ;;
    en:verify_dotfiles) text='-- dotfiles --' ;;
    es:verify_dotfiles) text='-- dotfiles --' ;;
    en:verify_hyprland) text='-- Hyprland --' ;;
    es:verify_hyprland) text='-- hyprland --' ;;
    en:no_login) text='login did not appear' ;;
    es:no_login) text='no aparece el login' ;;
    en:no_shell) text='shell did not appear' ;;
    es:no_shell) text='no hay shell' ;;
    en:system) text='system' ;;
    es:system) text='sistema' ;;
    en:storage) text='storage' ;;
    es:storage) text='almacenamiento' ;;
    en:services) text='services' ;;
    es:services) text='servicios' ;;
    en:failed) text='failed' ;;
    es:failed) text='fallidos' ;;
    en:packages) text='packages' ;;
    es:packages) text='paquetes' ;;
    en:theme) text='theme' ;;
    es:theme) text='tema' ;;
    en:network) text='network' ;;
    es:network) text='red' ;;
    en:session) text='graphical session' ;;
    es:session) text='sesion grafica' ;;
    en:gpu) text='GPU / virgl' ;;
    es:gpu) text='GPU / virgl' ;;
    en:boot_errors) text='boot errors' ;;
    es:boot_errors) text='errores del arranque' ;;
    en:end) text='END' ;;
    es:end) text='FIN' ;;
    en:omssh_missing_host) text='OM_HOST is required (example: OM_HOST=192.168.64.20)' ;;
    es:omssh_missing_host) text='Hace falta OM_HOST (ejemplo: OM_HOST=192.168.64.20)' ;;
    en:host_macos) text='this runs only on macOS' ;;
    es:host_macos) text='esto solo corre en macOS' ;;
    en:host_arm64) text='Apple Silicon is required (HVF for aarch64)' ;;
    es:host_arm64) text='hace falta Apple Silicon (HVF para aarch64)' ;;
    en:host_homebrew) text='Homebrew is required: https://brew.sh' ;;
    es:host_homebrew) text='falta Homebrew: https://brew.sh' ;;
    en:host_installing) text='installing %s...' ;;
    es:host_installing) text='instalando %s...' ;;
    en:host_qemu) text='qemu-system-aarch64 is missing' ;;
    es:host_qemu) text='falta qemu-system-aarch64' ;;
    en:host_expect) text='expect is missing' ;;
    es:host_expect) text='falta expect' ;;
    en:host_clt) text='%s is missing (did you run xcode-select --install?)' ;;
    es:host_clt) text='falta %s (¿ejecutaste xcode-select --install?)' ;;
    en:host_utm) text='UTM is missing: brew install --cask utm' ;;
    es:host_utm) text='falta UTM: brew install --cask utm' ;;
    en:host_disk_space) text='about 40 GB free space is required (%s GB available)' ;;
    es:host_disk_space) text='hacen falta ~40 GB libres (hay %s GB)' ;;
    en:host_deps_ok) text='qemu %s, UTM %s, %s GB free' ;;
    es:host_deps_ok) text='qemu %s, UTM %s, %s GB libres' ;;
    en:fetch_index_failed) text='could not read the Alpine index; using %s' ;;
    es:fetch_index_failed) text='no pude leer el indice de Alpine; uso %s' ;;
    en:fetch_alpine_info) text='Alpine %s (live environment for bootstrap)' ;;
    es:fetch_alpine_info) text='Alpine %s (entorno live para el bootstrap)' ;;
    en:fetch_alpine_failed) text='could not download Alpine (%s)' ;;
    es:fetch_alpine_failed) text='no se pudo descargar Alpine (%s)' ;;
    en:fetch_checksum_failed) text='Alpine ISO does not match its published sha256' ;;
    es:fetch_checksum_failed) text='el ISO de Alpine no cuadra con su sha256 publicado' ;;
    en:fetch_checksum_missing) text='no published sha256: not verified' ;;
    es:fetch_checksum_missing) text='sin sha256 publicado: no verificado' ;;
    en:fetch_checksum_ok) text='sha256 verified' ;;
    es:fetch_checksum_ok) text='sha256 verificado' ;;
    en:fetch_alpine_done) text='Alpine %s' ;;
    es:fetch_alpine_done) text='Alpine %s' ;;
    en:fetch_rootfs_info) text='Arch Linux ARM rootfs (~800 MB)' ;;
    es:fetch_rootfs_info) text='rootfs de Arch Linux ARM (~800 MB)' ;;
    en:fetch_rootfs_failed) text='could not download the ALARM rootfs' ;;
    es:fetch_rootfs_failed) text='no se pudo descargar el rootfs de ALARM' ;;
    en:fetch_md5_missing) text='could not read %s.md5: rootfs is NOT verified' ;;
    es:fetch_md5_missing) text='no pude leer %s.md5: el rootfs queda SIN verificar' ;;
    en:fetch_md5_mismatch) text='MD5 mismatch (expected %s, got %s); downloading again' ;;
    es:fetch_md5_mismatch) text='MD5 no coincide (esperado %s, obtenido %s); se vuelve a descargar' ;;
    en:fetch_md5_failed) text='the ALARM rootfs still fails verification after retrying' ;;
    es:fetch_md5_failed) text='el rootfs de ALARM sigue sin cuadrar tras reintentar' ;;
    en:fetch_md5_unverified) text='rootfs ALARM %s, not verified' ;;
    es:fetch_md5_unverified) text='rootfs ALARM %s, sin verificar' ;;
    en:fetch_md5_ok) text='rootfs ALARM %s, MD5 verified' ;;
    es:fetch_md5_ok) text='rootfs ALARM %s, MD5 verificado' ;;
    en:prepare_ref_missing) text="branch '%s' does not exist and the default branch could not be read" ;;
    es:prepare_ref_missing) text="la rama '%s' no existe y no pude leer la rama por defecto de Omarchy" ;;
    en:prepare_ref_fallback) text="branch '%s' no longer exists; using '%s'" ;;
    es:prepare_ref_fallback) text="la rama '%s' ya no existe en Omarchy; se usa '%s'" ;;
    en:prepare_ref_warning) text='check that the structure has not changed: this build assumes Omarchy 4' ;;
    es:prepare_ref_warning) text='revisa que la estructura no haya cambiado: este build asume Omarchy 4' ;;
    en:prepare_packages_failed) text='could not read the Omarchy package list' ;;
    es:prepare_packages_failed) text='no se pudo leer la lista de paquetes de Omarchy' ;;
    en:prepare_mirror_failed) text='ALARM mirror is not responding' ;;
    es:prepare_mirror_failed) text='mirror ALARM no responde' ;;
    en:prepare_lists_failed) text='could not write package lists' ;;
    es:prepare_lists_failed) text='no se pudieron escribir las listas de paquetes' ;;
    en:prepare_lists_ok) text="lists generated for branch '%s': %s core, %s extra" ;;
    es:prepare_lists_ok) text="listas generadas contra la rama '%s': %s en el nucleo, %s extras" ;;
    en:build_iso_done) text='provisioning ISO %s' ;;
    es:build_iso_done) text='ISO de aprovisionamiento %s' ;;
    en:build_rebuild_previous) text='the previous disk remains at %s' ;;
    es:build_rebuild_previous) text='el anterior queda en %s' ;;
    en:build_start) text='starting the builder (Alpine live → chroot → 3 stages)' ;;
    es:build_start) text='arrancando el constructor (Alpine live → chroot → 3 etapas)' ;;
    en:build_duration) text='this takes about 40 min depending on the network; full log: %s' ;;
    es:build_duration) text='esto tarda ~40 min segun la red; el log completo en %s' ;;
    en:build_stage3_failed) text='stage3 failed: disk exists but lacks the Omarchy configuration. Log: %s' ;;
    es:build_stage3_failed) text='stage3 fallo: el disco existe pero no tiene la configuracion de Omarchy. Log: %s' ;;
    en:build_failed_rc) text='build failed (rc=%s); see %s' ;;
    es:build_failed_rc) text='la construccion fallo (rc=%s); revisa %s' ;;
    en:build_disk_done) text='built disk: %s' ;;
    es:build_disk_done) text='disco construido: %s' ;;
    en:build_disk_missing) text='no built disk; run the build phase' ;;
    es:build_disk_missing) text='no hay disco construido; ejecuta la fase build' ;;
    en:utm_registering) text="will register as '%s'" ;;
    es:utm_registering) text="se registrara como '%s'" ;;
    en:utm_make_failed) text='make-utm.sh failed; full log: %s' ;;
    es:utm_make_failed) text='make-utm.sh fallo; log completo: %s' ;;
    en:utm_bundle_missing) text='bundle was not left in %s' ;;
    es:utm_bundle_missing) text='el bundle no quedo en %s' ;;
    en:utm_bundle_done) text='bundle created at %s' ;;
    es:utm_bundle_done) text='bundle creado en %s' ;;
    en:verify_waiting) text='waiting for boot...' ;;
    es:verify_waiting) text='esperando al arranque...' ;;
    en:verify_pty_missing) text='could not obtain the serial port; check manually' ;;
    es:verify_pty_missing) text='no se pudo obtener el puerto serie; comprueba a mano' ;;
    en:verify_ok) text="VM '%s' verified: Omarchy 4, Hyprland + quickshell alive, commands and units present" ;;
    es:verify_ok) text="VM '%s' verificada: Omarchy 4, Hyprland + quickshell vivos, comandos y unidades en su sitio" ;;
    en:verify_incomplete) text='VM boots but the desktop is incomplete; log: %s' ;;
    es:verify_incomplete) text='la VM arranca pero el escritorio no esta completo; log en %s' ;;
    en:verify_no_response) text='no response on the serial port; check the UTM window manually' ;;
    es:verify_no_response) text='no hubo respuesta por el puerto serie; comprueba a mano la ventana de UTM' ;;
    en:sanitize_copy_done) text='working copy created (the original VM is untouched)' ;;
    es:sanitize_copy_done) text='copia de trabajo hecha (la VM original no se toca)' ;;
    en:sanitize_start) text='sanitizing (generic user, no keys or identity)...' ;;
    es:sanitize_start) text='limpiando (usuario generico, sin claves ni identidad)...' ;;
    en:sanitize_failed) text='sanitize failed; see %s' ;;
    es:sanitize_failed) text='la limpieza fallo; revisa %s' ;;
    en:sanitize_done) text='sanitized image' ;;
    es:sanitize_done) text='imagen sanitizada' ;;
    en:package_missing) text='no sanitized image; run the sanitize phase' ;;
    es:package_missing) text='no hay imagen sanitizada; ejecuta la fase sanitize' ;;
    en:package_compacting) text='compacting and compressing qcow2 clusters...' ;;
    es:package_compacting) text='compactando y comprimiendo los clusters del qcow2...' ;;
    en:package_convert_failed) text='qemu-img convert failed' ;;
    es:package_convert_failed) text='qemu-img convert fallo' ;;
    en:package_check_failed) text='the compacted image did not validate' ;;
    es:package_check_failed) text='la imagen compactada no valida' ;;
    en:package_bundle_failed) text='could not create the distributable bundle' ;;
    es:package_bundle_failed) text='no se pudo crear el bundle distribuible' ;;
    en:package_config_user) text="bundle config.plist mentions '%s'; check make-utm.sh" ;;
    es:package_config_user) text="el config.plist del bundle menciona a '%s'; revisa make-utm.sh" ;;
    en:package_compressing) text='compressing...' ;;
    es:package_compressing) text='comprimiendo...' ;;
    en:package_done) text='ready: %s (%s)' ;;
    es:package_done) text='listo: %s (%s)' ;;
    en:package_sizes) text='%s → %s' ;;
    es:package_sizes) text='%s → %s' ;;
    en:sanitize_motd_title) text='Omarchy on Arch Linux ARM (aarch64) — UTM image for Apple Silicon' ;;
    es:sanitize_motd_title) text='Omarchy sobre Arch Linux ARM (aarch64) — imagen para UTM en Apple Silicon' ;;
    en:sanitize_motd_credentials) text='User: %s · Password: %s (also root).' ;;
    es:sanitize_motd_credentials) text='Usuario: %s · Contrasena: %s (tambien root).' ;;
    en:sanitize_motd_change_password) text='Change it with passwd.' ;;
    es:sanitize_motd_change_password) text='Cambiala con passwd.' ;;
    en:sanitize_motd_keys) text='SSH keys were removed for distribution.' ;;
    es:sanitize_motd_keys) text='Las claves SSH se eliminaron para distribuirla.' ;;
    en:sanitize_motd_shortcuts) text='The Option key (⌥) acts as SUPER.' ;;
    es:sanitize_motd_shortcuts) text='La tecla Option (⌥) actua como SUPER.' ;;
    en:sanitize_motd_missing_apps) text='Some proprietary apps may be missing; see omarchy-arm-extras.' ;;
    es:sanitize_motd_missing_apps) text='Pueden faltar apps propietarias; mira omarchy-arm-extras.' ;;
    en:sanitize_motd_license) text='Omarchy is free software; see the project license.' ;;
    es:sanitize_motd_license) text='Omarchy es software libre; consulta la licencia del proyecto.' ;;
    en:sanitize_motd_extras_list) text='Available optional apps: 1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta.' ;;
    es:sanitize_motd_extras_list) text='Apps opcionales disponibles: 1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta.' ;;
    en:sanitize_motd_extras_menu) text='Run omarchy-arm-extras for the interactive menu.' ;;
    es:sanitize_motd_extras_menu) text='Ejecuta omarchy-arm-extras para abrir el menu interactivo.' ;;
    en:unknown_option) text='unknown option: %s' ;;
    es:unknown_option) text='opcion desconocida: %s' ;;
    en:unknown_phase) text='unknown phase: %s' ;;
    es:unknown_phase) text='fase desconocida: %s' ;;
    en:phase_failed) text='phase failed: %s' ;;
    es:phase_failed) text='fallo en la fase: %s' ;;
    en:invalid_lang) text='Invalid language: %s (expected en or es)' ;;
    es:invalid_lang) text='Idioma no valido: %s (se esperaba en o es)' ;;
    en:missing_lang) text='Missing value for --lang (expected en or es)' ;;
    es:missing_lang) text='Falta el valor de --lang (se esperaba en o es)' ;;
    en:phase_deps) text='deps · host dependencies' ;;
    es:phase_deps) text='deps · dependencias del anfitrion' ;;
    en:phase_fetch) text='fetch · base images' ;;
    es:phase_fetch) text='fetch · imagenes base' ;;
    en:phase_prepare) text='prepare · package list' ;;
    es:phase_prepare) text='prepare · lista de paquetes' ;;
    en:phase_build) text='build · disk construction (headless, QEMU + HVF)' ;;
    es:phase_build) text='build · construccion del disco (headless, QEMU + HVF)' ;;
    en:phase_utm) text='utm · .utm bundle' ;;
    es:phase_utm) text='utm · bundle .utm' ;;
    en:phase_verify) text='verify · boot and check' ;;
    es:phase_verify) text='verify · arranque y comprobacion' ;;
    en:phase_sanitize) text='sanitize · clean copy for distribution' ;;
    es:phase_sanitize) text='sanitize · copia limpia para distribuir' ;;
    en:phase_package) text='package · compact and compress' ;;
    es:phase_package) text='package · compactar y comprimir' ;;
    en:config) text='configuration' ;;
    es:config) text='configuracion' ;;
    en:config_hint) text='Press Enter to accept the value in brackets. Detected from your Mac.' ;;
    es:config_hint) text='Enter acepta el valor entre corchetes. Detectados de tu Mac.' ;;
    en:timezone) text='Timezone' ;;
    es:timezone) text='Zona horaria' ;;
    en:keyboard_console) text='Keyboard (console)' ;;
    es:keyboard_console) text='Teclado (consola)' ;;
    en:keyboard_wayland) text='Keyboard (Hyprland/Wayland)' ;;
    es:keyboard_wayland) text='Teclado (Hyprland/Wayland)' ;;
    en:vm_cpus) text='VM CPUs' ;;
    es:vm_cpus) text='Nucleos para la VM' ;;
    en:vm_memory) text='VM memory (MiB)' ;;
    es:vm_memory) text='Memoria para la VM (MiB)' ;;
    en:disk_size) text='Disk size' ;;
    es:disk_size) text='Tamano del disco' ;;
    en:confirm_tools) text='Compile the 17 Omarchy tools unavailable for ARM (~40 min)?' ;;
    es:confirm_tools) text='Compilar las 17 herramientas de Omarchy que no existen para ARM (~40 min)?' ;;
    en:no_tools) text='Without them, ttfx, tensaku, omacalc, omacut, omawrite, aether and cliamp will be missing.' ;;
    es:no_tools) text='Sin ellas faltaran ttfx, tensaku, omacalc, omacut, omawrite, aether, cliamp...' ;;
    en:confirm_free) text='Include OBS Studio and Pinta (free software, compile time: ~45 min)?' ;;
    es:confirm_free) text='Incluir OBS Studio y Pinta (software libre, se compilan: ~45 min)?' ;;
    en:free_after) text='You can add them later from inside the VM: omarchy-arm-extras pinta obs' ;;
    es:free_after) text='Se pueden anadir despues desde dentro: omarchy-arm-extras pinta obs' ;;
    en:use_choices) text='Two possible uses:' ;;
    es:use_choices) text='Dos usos posibles:' ;;
    en:dist_desc) text='distribution image → renames the user to %s, removes SSH keys and identity, and creates a ~6.5 GB zip (~30 min extra)' ;;
    es:dist_desc) text='imagen para repartir → renombra el usuario a %s, borra claves SSH e identidad, y genera un zip de ~6,5 GB (~30 min extra)' ;;
    en:personal_desc) text='personal VM → keeps the current %s user' ;;
    es:personal_desc) text='VM para ti → se queda como esta, con el usuario %s' ;;
    en:confirm_dist) text='Prepare the image for distribution?' ;;
    es:confirm_dist) text='Preparar la imagen para repartir?' ;;
    en:dist_user) text='Distribution image user' ;;
    es:dist_user) text='Usuario de la imagen distribuible' ;;
    en:vm_user) text='VM user' ;;
    es:vm_user) text='Usuario de la VM' ;;
    en:password) text='Password' ;;
    es:password) text='Contrasena' ;;
    en:fullname) text='Full name' ;;
    es:fullname) text='Nombre completo' ;;
    en:summary) text='Summary: %s/%s · %s · %s CPUs · %s MiB · disk %s' ;;
    es:summary) text='resumen: %s/%s · %s · %s nucleos · %s MiB · disco %s' ;;
    en:summary_tools) text='         tools: %s · OBS+Pinta: %s · distribution: %s' ;;
    es:summary_tools) text='         herramientas: %s · OBS+Pinta: %s · repartir: %s' ;;
    en:display_yes) text='yes' ;;
    es:display_yes) text='si' ;;
    en:display_no) text='no' ;;
    es:display_no) text='no' ;;
    en:yesno_yes) text='Y/n' ;;
    es:yesno_yes) text='S/n' ;;
    en:yesno_no) text='y/N' ;;
    es:yesno_no) text='s/N' ;;
    en:cancelled) text='cancelled' ;;
    es:cancelled) text='cancelado' ;;
    en:complete) text='Completed in %s min.' ;;
    es:complete) text='Completado en %s min.' ;;
    en:confirm_rebuild) text='A disk already exists (%s). Discard it and rebuild?' ;;
    es:confirm_rebuild) text='Ya existe un disco construido (%s). ¿Descartarlo y reconstruir?' ;;
    en:confirm_vm_delete) text='A VM named %s already exists in UTM. Delete and replace it?' ;;
    es:confirm_vm_delete) text='Ya existe una VM llamada %s en UTM. ¿Borrarla y reemplazarla?' ;;
    en:confirm_start) text='Start?' ;;
    es:confirm_start) text='Empezar?' ;;
    en:dist_motd) text='Omarchy on Arch Linux ARM (aarch64) — UTM image for Apple Silicon' ;;
    es:dist_motd) text='Omarchy sobre Arch Linux ARM (aarch64) — imagen para UTM en Apple Silicon' ;;
    en:extra_desktop_name) text='Install missing apps (ARM)' ;;
    es:extra_desktop_name) text='Instalar apps que faltan (ARM)' ;;
    en:extra_desktop_comment) text='1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta' ;;
    es:extra_desktop_comment) text='1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta' ;;
    en:stage1_network) text='network' ;;
    es:stage1_network) text='red' ;;
    en:stage1_tools) text='Alpine repositories and tools' ;;
    es:stage1_tools) text='repositorios y herramientas de Alpine' ;;
    en:stage2_locale) text='timezone, locales, keyboard, hostname' ;;
    es:stage2_locale) text='zona horaria, locales, teclado, hostname' ;;
    en:stage3_clone) text='cloning basecamp/omarchy (branch %s = Omarchy 4; master is 3.8.5)' ;;
    es:stage3_clone) text='clonando basecamp/omarchy (rama %s = Omarchy 4; master es 3.8.5)' ;;
    en:repair_mount) text='mounting installed system' ;;
    es:repair_mount) text='montando el sistema instalado' ;;
    en:sanitize_motd) text='notice for the recipient' ;;
    es:sanitize_motd) text='aviso al destinatario' ;;
    en:armsync_title) text='Updating the Omarchy tree (git checkout)' ;;
    es:armsync_title) text='Actualizar el arbol de Omarchy (checkout git)' ;;
    en:armsync_pull_failed) text='fast-forward failed; the tree is unchanged' ;;
    es:armsync_pull_failed) text='no se pudo hacer fast-forward; el arbol queda como estaba' ;;
    en:armsync_current) text='already up to date (%s)' ;;
    es:armsync_current) text='ya estaba al dia (%s)' ;;
    en:armsync_linked) text='%s new binaries linked in /usr/bin' ;;
    es:armsync_linked) text='%s binarios nuevos enlazados en /usr/bin' ;;
    en:clipboard_help_title) text='Shared clipboard via the UTM shared folder' ;;
    es:clipboard_help_title) text='Portapapeles compartido mediante la carpeta de UTM' ;;
    en:clipboard_help_watch) text='watch (started by the user service)' ;;
    es:clipboard_help_watch) text='vigila (lo lanza el servicio de usuario)' ;;
    en:clipboard_help_install) text='install and start the service' ;;
    es:clipboard_help_install) text='instala el servicio y lo arranca' ;;
    en:clipboard_help_host) text='print the Mac host script' ;;
    es:clipboard_help_host) text='imprime el script para el Mac' ;;
    en:clipboard_service_active) text='service active' ;;
    es:clipboard_service_active) text='servicio activo' ;;
    en:clipboard_missing_package) text='wl-clipboard is missing' ;;
    es:clipboard_missing_package) text='falta wl-clipboard' ;;
    en:clipboard_share_missing) text='no shared folder at %s' ;;
    es:clipboard_share_missing) text='no hay carpeta compartida en %s' ;;
    en:clipboard_share_setup) text='In UTM: VM Settings → Sharing → choose a folder, then restart.' ;;
    es:clipboard_share_setup) text='En UTM: Ajustes de la VM → Compartir → elige una carpeta, y reinicia.' ;;
    en:clipboard_write_failed) text='cannot write %s' ;;
    es:clipboard_write_failed) text='no puedo escribir en %s' ;;
    en:clipboard_unknown_option) text='unknown option: %s' ;;
    es:clipboard_unknown_option) text='opcion desconocida: %s' ;;
    en:desktop_name) text='Install missing apps (ARM)' ;;
    es:desktop_name) text='Instalar apps que faltan (ARM)' ;;
    en:script_prepare_iso) text='preparing provisioning ISO' ;;
    es:script_prepare_iso) text='preparando ISO de aprovisionamiento' ;;
    en:script_clean_disk) text='removing previous disk' ;;
    es:script_clean_disk) text='eliminando el disco anterior' ;;
    en:script_building) text='building the VM' ;;
    es:script_building) text='construyendo la VM' ;;
    en:qemu_missing_disk) text='DISK_IMG is not set' ;;
    es:qemu_missing_disk) text='DISK_IMG no esta definido' ;;
    en:qemu_shot_starting) text='starting screenshot VM' ;;
    es:qemu_shot_starting) text='arrancando la VM para capturar' ;;
    en:qemu_shot_waiting) text='waiting' ;;
    es:qemu_shot_waiting) text='esperando' ;;
    en:qemu_shot_capture) text='screenshot' ;;
    es:qemu_shot_capture) text='captura' ;;
    en:utm_missing_disk) text='missing disk: %s' ;;
    es:utm_missing_disk) text='falta el disco: %s' ;;
    en:utm_missing_vars) text='missing UEFI NVRAM template: %s' ;;
    es:utm_missing_vars) text='falta la plantilla de NVRAM UEFI: %s' ;;
    en:utm_running_vms) text='VMs currently running in UTM:' ;;
    es:utm_running_vms) text='HAY VMs EN MARCHA en UTM:' ;;
    en:utm_restart_warning) text='Registering the bundle requires restarting UTM, which stops them.' ;;
    es:utm_restart_warning) text='Para registrar el bundle hay que reiniciar UTM, y eso las cortaria.' ;;
    en:utm_close_prompt) text='Close them and restart UTM?' ;;
    es:utm_close_prompt) text='¿Cerrarlas y reiniciar UTM?' ;;
    en:utm_manual_import) text='UTM was not restarted: import the bundle manually.' ;;
    es:utm_manual_import) text='no se reinicia UTM: importa el bundle a mano' ;;
    en:utm_unattended) text='unattended mode: UTM is not closed; import the bundle manually' ;;
    es:utm_unattended) text='modo desatendido: NO se cierra UTM. Importa el bundle a mano.' ;;
    en:utm_closing) text='closing UTM so it rescans Documents' ;;
    es:utm_closing) text='cerrando UTM para que reescanee Documents' ;;
    en:utm_creating) text='creating' ;;
    es:utm_creating) text='creando' ;;
    en:utm_copying) text='copying disk' ;;
    es:utm_copying) text='copiando disco' ;;
    en:utm_notes) text='Arch Linux ARM (aarch64) + Hyprland + Omarchy 4 dotfiles. User: %s · Password: %s (also root). Change it with passwd. The Option key (⌥) acts as SUPER. Read LEEME.md.' ;;
    es:utm_notes) text='Arch Linux ARM (aarch64) + Hyprland + dotfiles de Omarchy 4. Usuario: %s · Contraseña: %s (también root). Cámbiala con passwd. La tecla Option (⌥) actúa como SUPER. Lee LEEME.md.' ;;
    en:utm_validate) text='validating plist' ;;
    es:utm_validate) text='validando el plist' ;;
    en:utm_opening) text='opening UTM to register the bundle' ;;
    es:utm_opening) text='abriendo UTM para que registre el bundle' ;;
    en:utm_not_registered) text='bundle created outside UTM Documents (not registered)' ;;
    es:utm_not_registered) text='bundle creado fuera de la carpeta de UTM (no se registra)' ;;
    en:utm_bundle) text='Bundle' ;;
    es:utm_bundle) text='Bundle' ;;
    en:utm_uuid) text='UUID' ;;
    es:utm_uuid) text='UUID' ;;
    en:utm_start) text='Start' ;;
    es:utm_start) text='Arrancar' ;;
    en:stage1_network) text='network' ;;
    es:stage1_network) text='red' ;;
    en:stage1_no_ipv4) text='no IPv4' ;;
    es:stage1_no_ipv4) text='sin IPv4' ;;
    en:stage1_tools) text='Alpine repositories and tools' ;;
    es:stage1_tools) text='repositorios y herramientas de Alpine' ;;
    en:stage1_ok) text='ok' ;;
    es:stage1_ok) text='ok' ;;
    en:stage1_fs_modules) text='loading live-kernel filesystem modules' ;;
    es:stage1_fs_modules) text='cargando modulos de sistema de ficheros del kernel del live' ;;
    en:stage1_btrfs_fallback) text='btrfs is unavailable in the live kernel; using ext4 for the root' ;;
    es:stage1_btrfs_fallback) text='btrfs no disponible en el kernel del live -> se usara ext4 para la raiz' ;;
    en:stage1_vfat_missing) text='vfat is not listed in /proc/filesystems' ;;
    es:stage1_vfat_missing) text='vfat no listado en /proc/filesystems' ;;
    en:stage1_root) text='root' ;;
    es:stage1_root) text='raiz' ;;
    en:stage1_filesystems) text='filesystems' ;;
    es:stage1_filesystems) text='filesystems' ;;
    en:stage1_partition) text='partitioning %s (GPT: ESP 1GiB + root %s)' ;;
    es:stage1_partition) text='particionando %s (GPT: ESP 1GiB + raiz %s)' ;;
    en:stage1_subvolumes) text='btrfs subvolumes @ and @home' ;;
    es:stage1_subvolumes) text='subvolumenes btrfs @ y @home' ;;
    en:stage1_deploy_rootfs) text='deploying Arch Linux ARM rootfs (bsdtar -xpf, preserving xattr/ACL)' ;;
    es:stage1_deploy_rootfs) text='desplegando rootfs de Arch Linux ARM (bsdtar -xpf, preserva xattr/ACL)' ;;
    en:stage1_contents) text='contents' ;;
    es:stage1_contents) text='contenido' ;;
    en:stage1_rootfs_incomplete) text='incomplete rootfs' ;;
    es:stage1_rootfs_incomplete) text='rootfs incompleto' ;;
    en:stage1_mount_esp) text='mounting the ESP at /boot' ;;
    es:stage1_mount_esp) text='montando la ESP en /boot' ;;
    en:stage1_mounts) text='chroot mounts' ;;
    es:stage1_mounts) text='montajes del chroot' ;;
    en:stage1_dns) text='DNS inside chroot' ;;
    es:stage1_dns) text='DNS dentro del chroot' ;;
    en:stage1_copy_payload) text='copying payload' ;;
    es:stage1_copy_payload) text='copiando payload' ;;
    en:stage1_chroot) text='entering chroot -> stage2' ;;
    es:stage1_chroot) text='entrando en chroot -> stage2' ;;
    en:stage1_unmount) text='unmounting' ;;
    es:stage1_unmount) text='desmontando' ;;
    en:stage1_finished) text='finished rc=%s' ;;
    es:stage1_finished) text='terminado rc=%s' ;;
    en:stage2_line_failed) text='failed at line %s' ;;
    es:stage2_line_failed) text='fallo en la linea %s' ;;
    en:stage2_keyring) text='initializing Arch Linux ARM keyring' ;;
    es:stage2_keyring) text='inicializando el llavero de Arch Linux ARM' ;;
    en:stage2_update) text='updating the system' ;;
    es:stage2_update) text='actualizando el sistema' ;;
    en:stage2_base) text='base system' ;;
    es:stage2_base) text='sistema base' ;;
    en:stage2_locale) text='timezone, locales, keyboard, hostname' ;;
    es:stage2_locale) text='zona horaria, locales, teclado, hostname' ;;
    en:stage2_fstab) text='fstab' ;;
    es:stage2_fstab) text='fstab' ;;
    en:stage2_user) text='user %s' ;;
    es:stage2_user) text='usuario %s' ;;
    en:stage2_initramfs) text='mkinitcpio (virtio + btrfs modules)' ;;
    es:stage2_initramfs) text='mkinitcpio (modulos virtio + btrfs)' ;;
    en:stage2_boot_empty) text='/boot is empty: reinstalling linux-aarch64' ;;
    es:stage2_boot_empty) text='/boot vacio: reinstalando linux-aarch64' ;;
    en:stage2_kernel_reinstall_failed) text='could not reinstall the kernel' ;;
    es:stage2_kernel_reinstall_failed) text='no se pudo reinstalar el kernel' ;;
    en:stage2_initramfs_failed) text='mkinitcpio failed after reinstall' ;;
    es:stage2_initramfs_failed) text='mkinitcpio fallo tras reinstalar' ;;
    en:stage2_kernel_missing) text='kernel image not found in /boot' ;;
    es:stage2_kernel_missing) text='no encuentro la imagen del kernel en /boot' ;;
    en:stage2_initramfs_missing) text='initramfs not found' ;;
    es:stage2_initramfs_missing) text='no encuentro el initramfs' ;;
    en:stage2_verbose) text='verbose' ;;
    es:stage2_verbose) text='verboso' ;;
    en:stage2_network) text='network: NetworkManager' ;;
    es:stage2_network) text='red: NetworkManager (se desactiva systemd-networkd del tarball)' ;;
    en:stage2_desktop) text='installing desktop stack (Hyprland + Omarchy tools)' ;;
    es:stage2_desktop) text='instalando el stack de escritorio (Hyprland + herramientas de Omarchy)' ;;
    en:stage2_packages) text='packages' ;;
    es:stage2_packages) text='paquetes' ;;
    en:stage2_batch_failed) text='%s batch installation failed; retrying one by one' ;;
    es:stage2_batch_failed) text='%s: instalacion en bloque fallida; reintentando uno a uno' ;;
    en:stage2_packages_failed) text='%s packages not installed: %s' ;;
    es:stage2_packages_failed) text='%s no instalados: %s' ;;
    en:stage2_core) text='core' ;;
    es:stage2_core) text='nucleo' ;;
    en:stage2_extras) text='extras' ;;
    es:stage2_extras) text='extras' ;;
    en:stage2_services) text='system services' ;;
    es:stage2_services) text='servicios de sistema' ;;
    en:stage2_sddm_missing) text='sddm unavailable' ;;
    es:stage2_sddm_missing) text='sddm no disponible' ;;
    en:stage2_udev_rule) text='udev rule for' ;;
    es:stage2_udev_rule) text='regla udev para' ;;
    en:stage2_share_ready) text='/mnt/share ready for the shared UTM folder' ;;
    es:stage2_share_ready) text='/mnt/share listo para la carpeta compartida de UTM' ;;
    en:stage2_stage3) text='stage 3: Omarchy dotfiles as %s' ;;
    es:stage2_stage3) text='etapa 3: dotfiles de Omarchy como %s' ;;
    en:stage2_stage3_available) text='stage3 available files' ;;
    es:stage2_stage3_available) text='disponible para stage3' ;;
    en:stage2_stage3_failed) text='stage3 finished with errors (rc=%s)' ;;
    es:stage2_stage3_failed) text='stage3 termino con errores (rc=%s)' ;;
    en:stage2_sddm_session) text='SDDM: Omarchy session with autologin' ;;
    es:stage2_sddm_session) text='SDDM: sesion Omarchy con autologin' ;;
    en:stage2_session) text='session' ;;
    es:stage2_session) text='sesion' ;;
    en:stage2_vm_tuning) text='virtual-machine settings' ;;
    es:stage2_vm_tuning) text='ajustes propios de maquina virtual' ;;
    en:stage2_cleanup) text='cleanup' ;;
    es:stage2_cleanup) text='limpieza' ;;
    en:stage2_summary) text='summary' ;;
    es:stage2_summary) text='resumen' ;;
    en:stage2_not_installed) text='NOT INSTALLED' ;;
    es:stage2_not_installed) text='NO INSTALADO' ;;
    en:stage2_user_label) text='user' ;;
    es:stage2_user_label) text='usuario' ;;
    en:stage2_missing) text='MISSING' ;;
    es:stage2_missing) text='FALTAN' ;;
    en:stage2_completed) text='COMPLETED' ;;
    es:stage2_completed) text='COMPLETADO' ;;
    en:stage3_clone) text='cloning basecamp/omarchy (branch %s = Omarchy 4)' ;;
    es:stage3_clone) text='clonando basecamp/omarchy (rama %s = Omarchy 4)' ;;
    en:stage3_clone_failed) text='clone failed' ;;
    es:stage3_clone_failed) text='clone fallido' ;;
    en:stage3_copy_dotfiles) text='copying dotfiles to ~/.config' ;;
    es:stage3_copy_dotfiles) text='copiando dotfiles a ~/.config' ;;
    en:stage3_aur) text='AUR components unavailable in Arch Linux ARM repositories' ;;
    es:stage3_aur) text='AUR: piezas de Omarchy que no estan en los repos de Arch Linux ARM' ;;
    en:stage3_clone_package) text='could not clone %s' ;;
    es:stage3_clone_package) text='no pude clonar %s' ;;
    en:stage3_makepkg_failed) text='makepkg failed for %s' ;;
    es:stage3_makepkg_failed) text='makepkg fallo para %s' ;;
    en:stage3_ok) text='ok' ;;
    es:stage3_ok) text='ok' ;;
    en:stage3_none) text='none' ;;
    es:stage3_none) text='ninguno' ;;
    en:stage3_failed) text='failed' ;;
    es:stage3_failed) text='fallo' ;;
    en:stage3_terminal_missing) text='xdg-terminal-exec is missing; installing a wrapper' ;;
    es:stage3_terminal_missing) text='xdg-terminal-exec ausente: instalando un envoltorio' ;;
    en:stage3_integrate) text='integrating Omarchy into system paths' ;;
    es:stage3_integrate) text='integrando Omarchy en las rutas de sistema' ;;
    en:stage3_binaries) text='%s binaries linked in /usr/bin' ;;
    es:stage3_binaries) text='%s binarios en /usr/bin' ;;
    en:stage3_units) text='%s user units installed' ;;
    es:stage3_units) text='%s unidades de usuario instaladas' ;;
    en:stage3_sddm) text='SDDM: Omarchy theme and session' ;;
    es:stage3_sddm) text='SDDM: tema Omarchy y sesion' ;;
    en:stage3_theme) text='applying Tokyo Night theme' ;;
    es:stage3_theme) text='aplicando el tema Tokyo Night' ;;
    en:stage3_theme_failed) text='omarchy-theme-set failed' ;;
    es:stage3_theme_failed) text='omarchy-theme-set fallo' ;;
    en:stage3_vm_tuning) text='virtual-machine settings' ;;
    es:stage3_vm_tuning) text='ajustes para maquina virtual' ;;
    en:stage3_migrations) text='migrations sealed: %s' ;;
    es:stage3_migrations) text='migraciones selladas: %s' ;;
    en:stage3_tools_disabled) text='tool compilation disabled; ARM-only tools will be missing' ;;
    es:stage3_tools_disabled) text='compilacion de herramientas desactivada: faltaran herramientas ARM' ;;
    en:stage3_tools_build) text='building missing Omarchy tools for aarch64' ;;
    es:stage3_tools_build) text='compilando las herramientas de Omarchy ausentes en aarch64' ;;
    en:stage3_built) text='built' ;;
    es:stage3_built) text='compiladas' ;;
    en:stage3_not_built) text='not built: %s' ;;
    es:stage3_not_built) text='no compilaron: %s' ;;
    en:stage3_kernel_wrapper) text='omarchy-update-restart wrapper' ;;
    es:stage3_kernel_wrapper) text='envoltorio de omarchy-update-restart' ;;
    en:stage3_ttfx_build) text='building ttfx from source' ;;
    es:stage3_ttfx_build) text='compilando ttfx desde fuente' ;;
    en:stage3_ttfx_failed) text='ttfx build failed; the screensaver will show the logo without effects' ;;
    es:stage3_ttfx_failed) text='ttfx no compilo; el salvapantallas mostrara el logo sin efectos' ;;
    en:stage3_optional_installer) text='optional-app installer' ;;
    es:stage3_optional_installer) text='instalador de apps opcionales' ;;
    en:stage3_available_menu) text='available as a command and in the application menu' ;;
    es:stage3_available_menu) text='disponible como comando y en el menu de aplicaciones' ;;
    en:stage3_clipboard_agent) text='native Wayland clipboard agent' ;;
    es:stage3_clipboard_agent) text='agente de portapapeles nativo para Wayland' ;;
    en:stage3_vdagent_ready) text='vdagent service installed' ;;
    es:stage3_vdagent_ready) text='servicio vdagent instalado' ;;
    en:stage3_clipboard_fallback) text='shared-folder clipboard fallback installed' ;;
    es:stage3_clipboard_fallback) text='alternativa de portapapeles por carpeta compartida instalada' ;;
    en:stage3_free_apps) text='OBS Studio and Pinta (free software, included in the image)' ;;
    es:stage3_free_apps) text='OBS Studio y Pinta (software libre, van dentro de la imagen)' ;;
    en:stage3_free_apps_failed) text='OBS or Pinta could not be installed' ;;
    es:stage3_free_apps_failed) text='OBS o Pinta no se instalaron' ;;
    en:stage3_free_apps_skipped) text='OBS and Pinta skipped (HACER_LIBRES=no)' ;;
    es:stage3_free_apps_skipped) text='OBS y Pinta omitidos (HACER_LIBRES=no)' ;;
    en:stage3_updates) text='updates: snapper + post-update hook' ;;
    es:stage3_updates) text='actualizaciones: snapper + hook post-update' ;;
    en:stage3_snapper_missing) text='snapper unavailable' ;;
    es:stage3_snapper_missing) text='snapper no disponible' ;;
    en:stage3_snapper_ready) text='snapper configured' ;;
    es:stage3_snapper_ready) text='snapper configurado' ;;
    en:stage3_snapper_failed) text='snapper configuration failed' ;;
    es:stage3_snapper_failed) text='no se pudo configurar snapper' ;;
    en:stage3_hook_ready) text='post-update hook installed' ;;
    es:stage3_hook_ready) text='hook post-update instalado' ;;
    en:stage3_summary) text='summary' ;;
    es:stage3_summary) text='resumen' ;;
    en:stage3_unlinked) text='not linked' ;;
    es:stage3_unlinked) text='sin enlazar' ;;
    en:stage3_completed) text='COMPLETED' ;;
    es:stage3_completed) text='COMPLETADO' ;;
    en:repair_kernel_modules) text='kernel modules' ;;
    es:repair_kernel_modules) text='modulos del kernel' ;;
    en:repair_btrfs_missing) text='live kernel does not support btrfs' ;;
    es:repair_btrfs_missing) text='el kernel del live no soporta btrfs' ;;
    en:repair_filesystems) text='filesystems' ;;
    es:repair_filesystems) text='filesystems' ;;
    en:repair_network) text='network (best effort, for convenience)' ;;
    es:repair_network) text='red (best-effort, solo por comodidad)' ;;
    en:repair_no_network) text='no network; continuing anyway' ;;
    es:repair_no_network) text='sin red; se continua igualmente' ;;
    en:repair_mount) text='mounting installed system' ;;
    es:repair_mount) text='montando el sistema instalado' ;;
    en:repair_run_fix) text='running %s inside chroot' ;;
    es:repair_run_fix) text='ejecutando %s dentro del chroot' ;;
    en:repair_remove_payload) text='removing /root/prov from installed system' ;;
    es:repair_remove_payload) text='retirando /root/prov del sistema instalado' ;;
    en:repair_unmount) text='unmounting' ;;
    es:repair_unmount) text='desmontando' ;;
    en:sanitize_source_user_missing) text='no source user is configured' ;;
    es:sanitize_source_user_missing) text='no se de que usuario partir' ;;
    en:sanitize_user_missing) text='user %s does not exist' ;;
    es:sanitize_user_missing) text='el usuario %s no existe' ;;
    en:sanitize_step1) text='1/10 detaching /usr/share/omarchy from the old home' ;;
    es:sanitize_step1) text='1/10 desanclando /usr/share/omarchy del home del usuario' ;;
    en:sanitize_step2) text='2/10 renaming user %s -> %s' ;;
    es:sanitize_step2) text='2/10 renombrando el usuario %s -> %s' ;;
    en:sanitize_step3) text='3/10 SDDM: autologin to generic user' ;;
    es:sanitize_step3) text='3/10 SDDM: autologin al usuario generico' ;;
    en:sanitize_step4) text='4/10 credentials and keys' ;;
    es:sanitize_step4) text='4/10 credenciales y claves' ;;
    en:sanitize_step5) text='5/10 machine identity' ;;
    es:sanitize_step5) text='5/10 identidad de la maquina' ;;
    en:sanitize_step6) text='6/10 personal identity (git, histories, cache)' ;;
    es:sanitize_step6) text='6/10 identidad personal (git, historiales, cache)' ;;
    en:sanitize_step7b) text='7b/10 proprietary apps outside the distribution image' ;;
    es:sanitize_step7b) text='7b/10 apps propietarias fuera de la imagen distribuible' ;;
    en:sanitize_removed) text='removed %s' ;;
    es:sanitize_removed) text='retirado %s' ;;
    en:sanitize_spotify_binding_removed) text='removed Spotify shortcut' ;;
    es:sanitize_spotify_binding_removed) text='retirado el atajo de Spotify' ;;
    en:sanitize_reinstall_with) text='reinstall with: omarchy-arm-extras' ;;
    es:sanitize_reinstall_with) text='se reinstalan con: omarchy-arm-extras' ;;
    en:sanitize_step7c) text='7c/10 slimming: build-only dependencies' ;;
    es:sanitize_step7c) text='7c/10 adelgazando: lo que solo hacia falta para compilar' ;;
    en:sanitize_step7d) text='7d/10 slimming: hardware not needed in a VM' ;;
    es:sanitize_step7d) text='7d/10 adelgazando: lo que no puede hacer falta en una VM' ;;
    en:sanitize_usage_after_trim) text='space after trimming' ;;
    es:sanitize_usage_after_trim) text='ocupacion tras el recorte' ;;
    en:sanitize_step7) text='7/10 system logs and caches' ;;
    es:sanitize_step7) text='7/10 logs y caches del sistema' ;;
    en:sanitize_step8) text='8/10 recipient notice' ;;
    es:sanitize_step8) text='8/10 aviso al destinatario' ;;
    en:sanitize_step8a) text='8a/10 ARM update hook' ;;
    es:sanitize_step8a) text='8a/10 hook de actualizacion para ARM' ;;
    en:sanitize_step8b) text='8b/10 optional-app installer' ;;
    es:sanitize_step8b) text='8b/10 instalador de apps opcionales' ;;
    en:sanitize_extras_ready) text='optional app installer installed' ;;
    es:sanitize_extras_ready) text='instalador de apps opcionales instalado' ;;
    en:sanitize_extras_missing) text='optional app installer was not included in the ISO' ;;
    es:sanitize_extras_missing) text='el instalador de apps opcionales no venia en el ISO' ;;
    en:sanitize_step9) text='9/10 checking that nothing remains tied to %s' ;;
    es:sanitize_step9) text='9/10 comprobando que nada quedo atado a %s' ;;
    en:sanitize_step10) text='10/10 freeing unused space for compression' ;;
    es:sanitize_step10) text='10/10 liberando espacio no usado para comprimir mejor' ;;
    en:sanitize_backups) text='usermod backup files' ;;
    es:sanitize_backups) text='ficheros de respaldo de usermod' ;;
    en:sanitize_subid) text='subuid/subgid' ;;
    es:sanitize_subid) text='subuid/subgid' ;;
    en:sanitize_final_scan) text='final scan for references to %s' ;;
    es:sanitize_final_scan) text='barrido final de referencias a %s' ;;
    en:sanitize_broken_usr_bin) text='broken symlinks in /usr/bin' ;;
    es:sanitize_broken_usr_bin) text='enlaces rotos en /usr/bin' ;;
    en:sanitize_omarchy_path) text='/usr/share/omarchy (must not point into /home)' ;;
    es:sanitize_omarchy_path) text='/usr/share/omarchy (no debe apuntar a /home)' ;;
    en:sanitize_consistency) text='system consistency' ;;
    es:sanitize_consistency) text='coherencia del sistema' ;;
    en:sanitize_bookmarks) text='Nautilus/GTK bookmarks pointing to old home' ;;
    es:sanitize_bookmarks) text='marcadores de Nautilus/GTK apuntando al home antiguo' ;;
    en:sanitize_real_name) text='real name in passwd (shown in greeter)' ;;
    es:sanitize_real_name) text='nombre real en passwd (aparece en el greeter)' ;;
    en:sanitize_user_dirs) text='user-dirs with absolute paths' ;;
    es:sanitize_user_dirs) text='user-dirs con rutas absolutas' ;;
    en:sanitize_symlinks) text='symlinks pointing to old home' ;;
    es:sanitize_symlinks) text='symlinks que apuntan al home antiguo' ;;
    en:sanitize_final_check) text='final check' ;;
    es:sanitize_final_check) text='comprobacion final' ;;
    en:sanitize_links_old) text='links to /home/%s' ;;
    es:sanitize_links_old) text='enlaces a /home/%s' ;;
    en:sanitize_broken_home) text='broken symlinks in home' ;;
    es:sanitize_broken_home) text='enlaces rotos en el home' ;;
    en:sanitize_ttfx_note) text='ttfx contains a build path in debug information; harmless' ;;
    es:sanitize_ttfx_note) text='ttfx contiene la ruta de compilacion en su informacion de depuracion; inocuo' ;;
    en:sanitize_distribution_state) text='final state for distribution' ;;
    es:sanitize_distribution_state) text='estado final para distribuir' ;;
    en:sanitize_user_label) text='user' ;;
    es:sanitize_user_label) text='usuario' ;;
    en:sanitize_do_not_boot_1) text='WARNING: do not boot this image again after sanitizing.' ;;
    es:sanitize_do_not_boot_1) text='AVISO: no arranques esta imagen otra vez despues de sanitizar.' ;;
    en:sanitize_do_not_boot_2) text='The first boot regenerates machine identity and logs.' ;;
    es:sanitize_do_not_boot_2) text='El primer arranque regenera la identidad y los logs.' ;;
    en:sanitize_do_not_boot_3) text='Repeat sanitize after any verification boot.' ;;
    es:sanitize_do_not_boot_3) text='Repite sanitize despues de cualquier arranque de verificacion.' ;;
    en:sanitize_do_not_boot_4) text='SSH host keys will be regenerated on first boot.' ;;
    es:sanitize_do_not_boot_4) text='Las claves SSH se regeneraran en el primer arranque.' ;;
    en:extras_help_title) text='omarchy-arm-extras — install ARM64 apps from official sources' ;;
    es:extras_help_title) text='omarchy-arm-extras — instala apps ARM64 desde fuentes oficiales' ;;
    en:extras_help_menu) text='interactive menu' ;;
    es:extras_help_menu) text='menu interactivo' ;;
    en:extras_help_list) text='list available apps' ;;
    es:extras_help_list) text='ver que puede instalar' ;;
    en:extras_help_specific) text='install selected items' ;;
    es:extras_help_specific) text='instalar elementos concretos' ;;
    en:extras_help_all) text='install everything missing' ;;
    es:extras_help_all) text='todo lo que falte' ;;
    en:extras_help_force) text='reinstall even if already installed' ;;
    es:extras_help_force) text='reinstalar aunque ya este' ;;
    en:extras_need_sudo) text='sudo is required to install packages.' ;;
    es:extras_need_sudo) text='Se necesita sudo para instalar paquetes.' ;;
    en:extras_no_privileges) text='no privileges' ;;
    es:extras_no_privileges) text='sin privilegios' ;;
    en:extras_already_installed) text='%s already installed' ;;
    es:extras_already_installed) text='%s ya instalado' ;;
    en:extras_clone_failed) text='could not clone %s (base: %s)' ;;
    es:extras_clone_failed) text='no se pudo clonar %s (base: %s)' ;;
    en:extras_import_key) text='importing GPG key %s' ;;
    es:extras_import_key) text='importando clave GPG %s' ;;
    en:extras_key_failed) text='could not import %s; signature verification may fail' ;;
    es:extras_key_failed) text='no pude importar %s: la verificacion de firma fallara' ;;
    en:extras_arch_patched) text='arch= patched to include aarch64' ;;
    es:extras_arch_patched) text='arch= parcheado para incluir aarch64' ;;
    en:extras_build_failed) text='build failed for %s — log: %s' ;;
    es:extras_build_failed) text='fallo la compilacion de %s — log: %s' ;;
    en:armsync_linked_path) text='armsync linked path' ;;
    es:armsync_linked_path) text='armsync linked path' ;;
    en:extras_1password_info) text='extras 1password info' ;;
    es:extras_1password_info) text='extras 1password info' ;;
    en:extras_already_in_image) text='extras already in image' ;;
    es:extras_already_in_image) text='extras already in image' ;;
    en:extras_arch_clone_failed) text='extras arch clone failed' ;;
    es:extras_arch_clone_failed) text='extras arch clone failed' ;;
    en:extras_archive_invalid) text='extras archive invalid' ;;
    es:extras_archive_invalid) text='extras archive invalid' ;;
    en:extras_build_failed_generic) text='extras build failed generic' ;;
    es:extras_build_failed_generic) text='extras build failed generic' ;;
    en:extras_choose_header) text='extras choose header' ;;
    es:extras_choose_header) text='extras choose header' ;;
    en:extras_chrome_info) text='extras chrome info' ;;
    es:extras_chrome_info) text='extras chrome info' ;;
    en:extras_chromium_info) text='extras chromium info' ;;
    es:extras_chromium_info) text='extras chromium info' ;;
    en:extras_download_failed) text='extras download failed' ;;
    es:extras_download_failed) text='extras download failed' ;;
    en:extras_extract_failed) text='extras extract failed' ;;
    es:extras_extract_failed) text='extras extract failed' ;;
    en:extras_failed_list) text='extras failed list' ;;
    es:extras_failed_list) text='extras failed list' ;;
    en:extras_installed) text='extras installed' ;;
    es:extras_installed) text='extras installed' ;;
    en:extras_installed_list) text='extras installed list' ;;
    es:extras_installed_list) text='extras installed list' ;;
    en:extras_installed_marker) text='extras installed marker' ;;
    es:extras_installed_marker) text='extras installed marker' ;;
    en:extras_launcher_ok) text='extras launcher ok' ;;
    es:extras_launcher_ok) text='extras launcher ok' ;;
    en:extras_list_explanation_1) text='extras list explanation 1' ;;
    es:extras_list_explanation_1) text='extras list explanation 1' ;;
    en:extras_list_explanation_2) text='extras list explanation 2' ;;
    es:extras_list_explanation_2) text='extras list explanation 2' ;;
    en:extras_list_explanation_3) text='extras list explanation 3' ;;
    es:extras_list_explanation_3) text='extras list explanation 3' ;;
    en:extras_list_title) text='extras list title' ;;
    es:extras_list_title) text='extras list title' ;;
    en:extras_logs) text='extras logs' ;;
    es:extras_logs) text='extras logs' ;;
    en:extras_manual_updates) text='extras manual updates' ;;
    es:extras_manual_updates) text='extras manual updates' ;;
    en:extras_no_hw_accel) text='extras no hw accel' ;;
    es:extras_no_hw_accel) text='extras no hw accel' ;;
    en:extras_not_in_path) text='extras not in path' ;;
    es:extras_not_in_path) text='extras not in path' ;;
    en:extras_nothing_selected) text='extras nothing selected' ;;
    es:extras_nothing_selected) text='extras nothing selected' ;;
    en:extras_obs_browser_info) text='extras obs browser info' ;;
    es:extras_obs_browser_info) text='extras obs browser info' ;;
    en:extras_obs_info) text='extras obs info' ;;
    es:extras_obs_info) text='extras obs info' ;;
    en:extras_obs_slow) text='extras obs slow' ;;
    es:extras_obs_slow) text='extras obs slow' ;;
    en:extras_obsidian_info) text='extras obsidian info' ;;
    es:extras_obsidian_info) text='extras obsidian info' ;;
    en:extras_obsidian_missing) text='extras obsidian missing' ;;
    es:extras_obsidian_missing) text='extras obsidian missing' ;;
    en:extras_obsidian_ok) text='extras obsidian ok' ;;
    es:extras_obsidian_ok) text='extras obsidian ok' ;;
    en:extras_pacman_failed) text='extras pacman failed' ;;
    es:extras_pacman_failed) text='extras pacman failed' ;;
    en:extras_path_arch_any) text='extras path arch any' ;;
    es:extras_path_arch_any) text='extras path arch any' ;;
    en:extras_pinta_info) text='extras pinta info' ;;
    es:extras_pinta_info) text='extras pinta info' ;;
    en:extras_pinta_install_info) text='extras pinta install info' ;;
    es:extras_pinta_install_info) text='extras pinta install info' ;;
    en:extras_pinta_missing) text='extras pinta missing' ;;
    es:extras_pinta_missing) text='extras pinta missing' ;;
    en:extras_pinta_runtime_missing) text='extras pinta runtime missing' ;;
    es:extras_pinta_runtime_missing) text='extras pinta runtime missing' ;;
    en:extras_postinstall_warning) text='extras postinstall warning' ;;
    es:extras_postinstall_warning) text='extras postinstall warning' ;;
    en:extras_signature_bad) text='extras signature bad' ;;
    es:extras_signature_bad) text='extras signature bad' ;;
    en:extras_signature_missing) text='extras signature missing' ;;
    es:extras_signature_missing) text='extras signature missing' ;;
    en:extras_signature_ok) text='extras signature ok' ;;
    es:extras_signature_ok) text='extras signature ok' ;;
    en:extras_spotify_binding_ok) text='extras spotify binding ok' ;;
    es:extras_spotify_binding_ok) text='extras spotify binding ok' ;;
    en:extras_spotify_chrome_required) text='extras spotify chrome required' ;;
    es:extras_spotify_chrome_required) text='extras spotify chrome required' ;;
    en:extras_spotify_terminal) text='extras spotify terminal' ;;
    es:extras_spotify_terminal) text='extras spotify terminal' ;;
    en:extras_summary) text='extras summary' ;;
    es:extras_summary) text='extras summary' ;;
    en:extras_typora_info) text='extras typora info' ;;
    es:extras_typora_info) text='extras typora info' ;;
    en:extras_unknown_key) text='extras unknown key' ;;
    es:extras_unknown_key) text='extras unknown key' ;;
    en:extras_usage) text='extras usage' ;;
    es:extras_usage) text='extras usage' ;;
    en:extras_wayland_hint) text='extras wayland hint' ;;
    es:extras_wayland_hint) text='extras wayland hint' ;;
    en:extras_webapp_missing) text='extras webapp missing' ;;
    es:extras_webapp_missing) text='extras webapp missing' ;;
    en:extras_widevine_hint) text='extras widevine hint' ;;
    es:extras_widevine_hint) text='extras widevine hint' ;;
    en:paths_check) text='paths check' ;;
    es:paths_check) text='paths check' ;;
    en:paths_linked) text='paths linked' ;;
    es:paths_linked) text='paths linked' ;;
    en:paths_missing) text='paths missing' ;;
    es:paths_missing) text='paths missing' ;;
    en:paths_step1) text='paths step1' ;;
    es:paths_step1) text='paths step1' ;;
    en:paths_step2) text='paths step2' ;;
    es:paths_step2) text='paths step2' ;;
    en:paths_step3) text='paths step3' ;;
    es:paths_step3) text='paths step3' ;;
    en:paths_step4) text='paths step4' ;;
    es:paths_step4) text='paths step4' ;;
    en:paths_step5) text='paths step5' ;;
    es:paths_step5) text='paths step5' ;;
    en:paths_step6) text='paths step6' ;;
    es:paths_step6) text='paths step6' ;;
    en:paths_step7) text='paths step7' ;;
    es:paths_step7) text='paths step7' ;;
    en:paths_step8) text='paths step8' ;;
    es:paths_step8) text='paths step8' ;;
    en:paths_theme_failed) text='paths theme failed' ;;
    es:paths_theme_failed) text='paths theme failed' ;;
    en:sanitize_active_background) text='sanitize active background' ;;
    es:sanitize_active_background) text='sanitize active background' ;;
    en:sanitize_all_ok) text='sanitize all ok' ;;
    es:sanitize_all_ok) text='sanitize all ok' ;;
    en:sanitize_background_resolves) text='sanitize background resolves' ;;
    es:sanitize_background_resolves) text='sanitize background resolves' ;;
    en:sanitize_binaries) text='sanitize binaries' ;;
    es:sanitize_binaries) text='sanitize binaries' ;;
    en:sanitize_broken) text='sanitize broken' ;;
    es:sanitize_broken) text='sanitize broken' ;;
    en:sanitize_broken_link_removed) text='sanitize broken link removed' ;;
    es:sanitize_broken_link_removed) text='sanitize broken link removed' ;;
    en:sanitize_broken_links) text='sanitize broken links' ;;
    es:sanitize_broken_links) text='sanitize broken links' ;;
    en:sanitize_do_not_boot_1) text='sanitize do not boot 1' ;;
    es:sanitize_do_not_boot_1) text='sanitize do not boot 1' ;;
    en:sanitize_do_not_boot_2) text='sanitize do not boot 2' ;;
    es:sanitize_do_not_boot_2) text='sanitize do not boot 2' ;;
    en:sanitize_do_not_boot_3) text='sanitize do not boot 3' ;;
    es:sanitize_do_not_boot_3) text='sanitize do not boot 3' ;;
    en:sanitize_do_not_boot_4) text='sanitize do not boot 4' ;;
    es:sanitize_do_not_boot_4) text='sanitize do not boot 4' ;;
    en:sanitize_home) text='sanitize home' ;;
    es:sanitize_home) text='sanitize home' ;;
    en:sanitize_home_label) text='sanitize home label' ;;
    es:sanitize_home_label) text='sanitize home label' ;;
    en:sanitize_host_keys) text='sanitize host keys' ;;
    es:sanitize_host_keys) text='sanitize host keys' ;;
    en:sanitize_in_usr_bin) text='sanitize in usr bin' ;;
    es:sanitize_in_usr_bin) text='sanitize in usr bin' ;;
    en:sanitize_loose_files) text='sanitize loose files' ;;
    es:sanitize_loose_files) text='sanitize loose files' ;;
    en:sanitize_matches) text='sanitize matches' ;;
    es:sanitize_matches) text='sanitize matches' ;;
    en:sanitize_menu_entry) text='sanitize menu entry' ;;
    es:sanitize_menu_entry) text='sanitize menu entry' ;;
    en:sanitize_missing) text='sanitize missing' ;;
    es:sanitize_missing) text='sanitize missing' ;;
    en:sanitize_missing_pkg) text='sanitize missing pkg' ;;
    es:sanitize_missing_pkg) text='sanitize missing pkg' ;;
    en:sanitize_no) text='sanitize no' ;;
    es:sanitize_no) text='sanitize no' ;;
    en:sanitize_none) text='sanitize none' ;;
    es:sanitize_none) text='sanitize none' ;;
    en:sanitize_none_upper) text='sanitize none upper' ;;
    es:sanitize_none_upper) text='sanitize none upper' ;;
    en:sanitize_ok) text='sanitize ok' ;;
    es:sanitize_ok) text='sanitize ok' ;;
    en:sanitize_old_home_links) text='sanitize old home links' ;;
    es:sanitize_old_home_links) text='sanitize old home links' ;;
    en:sanitize_optional_installer) text='sanitize optional installer' ;;
    es:sanitize_optional_installer) text='sanitize optional installer' ;;
    en:sanitize_passwd) text='sanitize passwd' ;;
    es:sanitize_passwd) text='sanitize passwd' ;;
    en:sanitize_refs_etc) text='sanitize refs etc' ;;
    es:sanitize_refs_etc) text='sanitize refs etc' ;;
    en:sanitize_regenerated) text='sanitize regenerated' ;;
    es:sanitize_regenerated) text='sanitize regenerated' ;;
    en:sanitize_remove_failed) text='sanitize remove failed' ;;
    es:sanitize_remove_failed) text='sanitize remove failed' ;;
    en:sanitize_removed_path) text='sanitize removed path' ;;
    es:sanitize_removed_path) text='sanitize removed path' ;;
    en:sanitize_required) text='sanitize required' ;;
    es:sanitize_required) text='sanitize required' ;;
    en:sanitize_step1) text='sanitize step1' ;;
    es:sanitize_step1) text='sanitize step1' ;;
    en:sanitize_step10) text='sanitize step10' ;;
    es:sanitize_step10) text='sanitize step10' ;;
    en:sanitize_step2) text='sanitize step2' ;;
    es:sanitize_step2) text='sanitize step2' ;;
    en:sanitize_step3) text='sanitize step3' ;;
    es:sanitize_step3) text='sanitize step3' ;;
    en:sanitize_step4) text='sanitize step4' ;;
    es:sanitize_step4) text='sanitize step4' ;;
    en:sanitize_step5) text='sanitize step5' ;;
    es:sanitize_step5) text='sanitize step5' ;;
    en:sanitize_step6) text='sanitize step6' ;;
    es:sanitize_step6) text='sanitize step6' ;;
    en:sanitize_step7) text='sanitize step7' ;;
    es:sanitize_step7) text='sanitize step7' ;;
    en:sanitize_step7b) text='sanitize step7b' ;;
    es:sanitize_step7b) text='sanitize step7b' ;;
    en:sanitize_step7c) text='sanitize step7c' ;;
    es:sanitize_step7c) text='sanitize step7c' ;;
    en:sanitize_step7d) text='sanitize step7d' ;;
    es:sanitize_step7d) text='sanitize step7d' ;;
    en:sanitize_step8) text='sanitize step8' ;;
    es:sanitize_step8) text='sanitize step8' ;;
    en:sanitize_step8a) text='sanitize step8a' ;;
    es:sanitize_step8a) text='sanitize step8a' ;;
    en:sanitize_step8b) text='sanitize step8b' ;;
    es:sanitize_step8b) text='sanitize step8b' ;;
    en:sanitize_step9) text='sanitize step9' ;;
    es:sanitize_step9) text='sanitize step9' ;;
    en:sanitize_symlink) text='sanitize symlink' ;;
    es:sanitize_symlink) text='sanitize symlink' ;;
    en:sanitize_ttfx_note1) text='sanitize ttfx note1' ;;
    es:sanitize_ttfx_note1) text='sanitize ttfx note1' ;;
    en:sanitize_ttfx_note2) text='sanitize ttfx note2' ;;
    es:sanitize_ttfx_note2) text='sanitize ttfx note2' ;;
    en:sanitize_user) text='sanitize user' ;;
    es:sanitize_user) text='sanitize user' ;;
    en:sanitize_yes) text='sanitize yes' ;;
    es:sanitize_yes) text='sanitize yes' ;;
    en:sshd_check) text='sshd check' ;;
    es:sshd_check) text='sshd check' ;;
    en:sshd_cleanup) text='sshd cleanup' ;;
    es:sshd_cleanup) text='sshd cleanup' ;;
    en:sshd_disable) text='sshd disable' ;;
    es:sshd_disable) text='sshd disable' ;;
    en:sshd_host_key) text='sshd host key' ;;
    es:sshd_host_key) text='sshd host key' ;;
    en:sshd_sudoers) text='sshd sudoers' ;;
    es:sshd_sudoers) text='sshd sudoers' ;;
    en:sshd_sudoers_valid) text='sshd sudoers valid' ;;
    es:sshd_sudoers_valid) text='sshd sudoers valid' ;;
    en:stage1_btrfs_fallback) text='stage1 btrfs fallback' ;;
    es:stage1_btrfs_fallback) text='stage1 btrfs fallback' ;;
    en:stage1_chroot) text='stage1 chroot' ;;
    es:stage1_chroot) text='stage1 chroot' ;;
    en:stage1_contents) text='stage1 contents' ;;
    es:stage1_contents) text='stage1 contents' ;;
    en:stage1_copy_payload) text='stage1 copy payload' ;;
    es:stage1_copy_payload) text='stage1 copy payload' ;;
    en:stage1_deploy_rootfs) text='stage1 deploy rootfs' ;;
    es:stage1_deploy_rootfs) text='stage1 deploy rootfs' ;;
    en:stage1_dns) text='stage1 dns' ;;
    es:stage1_dns) text='stage1 dns' ;;
    en:stage1_filesystems) text='stage1 filesystems' ;;
    es:stage1_filesystems) text='stage1 filesystems' ;;
    en:stage1_finished) text='stage1 finished' ;;
    es:stage1_finished) text='stage1 finished' ;;
    en:stage1_fs_modules) text='stage1 fs modules' ;;
    es:stage1_fs_modules) text='stage1 fs modules' ;;
    en:stage1_mount_esp) text='stage1 mount esp' ;;
    es:stage1_mount_esp) text='stage1 mount esp' ;;
    en:stage1_mounts) text='stage1 mounts' ;;
    es:stage1_mounts) text='stage1 mounts' ;;
    en:stage1_network) text='stage1 network' ;;
    es:stage1_network) text='stage1 network' ;;
    en:stage1_no_ipv4) text='stage1 no ipv4' ;;
    es:stage1_no_ipv4) text='stage1 no ipv4' ;;
    en:stage1_ok) text='stage1 ok' ;;
    es:stage1_ok) text='stage1 ok' ;;
    en:stage1_partition) text='stage1 partition' ;;
    es:stage1_partition) text='stage1 partition' ;;
    en:stage1_root) text='stage1 root' ;;
    es:stage1_root) text='stage1 root' ;;
    en:stage1_rootfs_incomplete) text='stage1 rootfs incomplete' ;;
    es:stage1_rootfs_incomplete) text='stage1 rootfs incomplete' ;;
    en:stage1_subvolumes) text='stage1 subvolumes' ;;
    es:stage1_subvolumes) text='stage1 subvolumes' ;;
    en:stage1_tools) text='stage1 tools' ;;
    es:stage1_tools) text='stage1 tools' ;;
    en:stage1_unmount) text='stage1 unmount' ;;
    es:stage1_unmount) text='stage1 unmount' ;;
    en:stage1_vfat_missing) text='stage1 vfat missing' ;;
    es:stage1_vfat_missing) text='stage1 vfat missing' ;;
    en:stage2_base) text='stage2 base' ;;
    es:stage2_base) text='stage2 base' ;;
    en:stage2_batch_failed) text='stage2 batch failed' ;;
    es:stage2_batch_failed) text='stage2 batch failed' ;;
    en:stage2_boot_empty) text='stage2 boot empty' ;;
    es:stage2_boot_empty) text='stage2 boot empty' ;;
    en:stage2_cleanup) text='stage2 cleanup' ;;
    es:stage2_cleanup) text='stage2 cleanup' ;;
    en:stage2_completed) text='stage2 completed' ;;
    es:stage2_completed) text='stage2 completed' ;;
    en:stage2_core) text='stage2 core' ;;
    es:stage2_core) text='stage2 core' ;;
    en:stage2_desktop) text='stage2 desktop' ;;
    es:stage2_desktop) text='stage2 desktop' ;;
    en:stage2_extras) text='stage2 extras' ;;
    es:stage2_extras) text='stage2 extras' ;;
    en:stage2_fstab) text='stage2 fstab' ;;
    es:stage2_fstab) text='stage2 fstab' ;;
    en:stage2_initramfs) text='stage2 initramfs' ;;
    es:stage2_initramfs) text='stage2 initramfs' ;;
    en:stage2_initramfs_failed) text='stage2 initramfs failed' ;;
    es:stage2_initramfs_failed) text='stage2 initramfs failed' ;;
    en:stage2_initramfs_missing) text='stage2 initramfs missing' ;;
    es:stage2_initramfs_missing) text='stage2 initramfs missing' ;;
    en:stage2_kernel_missing) text='stage2 kernel missing' ;;
    es:stage2_kernel_missing) text='stage2 kernel missing' ;;
    en:stage2_kernel_reinstall_failed) text='stage2 kernel reinstall failed' ;;
    es:stage2_kernel_reinstall_failed) text='stage2 kernel reinstall failed' ;;
    en:stage2_keyring) text='stage2 keyring' ;;
    es:stage2_keyring) text='stage2 keyring' ;;
    en:stage2_line_failed) text='stage2 line failed' ;;
    es:stage2_line_failed) text='stage2 line failed' ;;
    en:stage2_locale) text='stage2 locale' ;;
    es:stage2_locale) text='stage2 locale' ;;
    en:stage2_missing) text='stage2 missing' ;;
    es:stage2_missing) text='stage2 missing' ;;
    en:stage2_network) text='stage2 network' ;;
    es:stage2_network) text='stage2 network' ;;
    en:stage2_not_installed) text='stage2 not installed' ;;
    es:stage2_not_installed) text='stage2 not installed' ;;
    en:stage2_packages) text='stage2 packages' ;;
    es:stage2_packages) text='stage2 packages' ;;
    en:stage2_packages_failed) text='stage2 packages failed' ;;
    es:stage2_packages_failed) text='stage2 packages failed' ;;
    en:stage2_sddm_missing) text='stage2 sddm missing' ;;
    es:stage2_sddm_missing) text='stage2 sddm missing' ;;
    en:stage2_sddm_session) text='stage2 sddm session' ;;
    es:stage2_sddm_session) text='stage2 sddm session' ;;
    en:stage2_services) text='stage2 services' ;;
    es:stage2_services) text='stage2 services' ;;
    en:stage2_session) text='stage2 session' ;;
    es:stage2_session) text='stage2 session' ;;
    en:stage2_share_ready) text='stage2 share ready' ;;
    es:stage2_share_ready) text='stage2 share ready' ;;
    en:stage2_stage3) text='stage2 stage3' ;;
    es:stage2_stage3) text='stage2 stage3' ;;
    en:stage2_stage3_available) text='stage2 stage3 available' ;;
    es:stage2_stage3_available) text='stage2 stage3 available' ;;
    en:stage2_stage3_failed) text='stage2 stage3 failed' ;;
    es:stage2_stage3_failed) text='stage2 stage3 failed' ;;
    en:stage2_summary) text='stage2 summary' ;;
    es:stage2_summary) text='stage2 summary' ;;
    en:stage2_udev_rule) text='stage2 udev rule' ;;
    es:stage2_udev_rule) text='stage2 udev rule' ;;
    en:stage2_update) text='stage2 update' ;;
    es:stage2_update) text='stage2 update' ;;
    en:stage2_user) text='stage2 user' ;;
    es:stage2_user) text='stage2 user' ;;
    en:stage2_user_label) text='stage2 user label' ;;
    es:stage2_user_label) text='stage2 user label' ;;
    en:stage2_verbose) text='stage2 verbose' ;;
    es:stage2_verbose) text='stage2 verbose' ;;
    en:stage2_vm_tuning) text='stage2 vm tuning' ;;
    es:stage2_vm_tuning) text='stage2 vm tuning' ;;
    en:stage3_aur) text='stage3 aur' ;;
    es:stage3_aur) text='stage3 aur' ;;
    en:stage3_available_menu) text='stage3 available menu' ;;
    es:stage3_available_menu) text='stage3 available menu' ;;
    en:stage3_binaries) text='stage3 binaries' ;;
    es:stage3_binaries) text='stage3 binaries' ;;
    en:stage3_built) text='stage3 built' ;;
    es:stage3_built) text='stage3 built' ;;
    en:stage3_clipboard_agent) text='stage3 clipboard agent' ;;
    es:stage3_clipboard_agent) text='stage3 clipboard agent' ;;
    en:stage3_clipboard_fallback) text='stage3 clipboard fallback' ;;
    es:stage3_clipboard_fallback) text='stage3 clipboard fallback' ;;
    en:stage3_clone) text='stage3 clone' ;;
    es:stage3_clone) text='stage3 clone' ;;
    en:stage3_clone_failed) text='stage3 clone failed' ;;
    es:stage3_clone_failed) text='stage3 clone failed' ;;
    en:stage3_clone_package) text='stage3 clone package' ;;
    es:stage3_clone_package) text='stage3 clone package' ;;
    en:stage3_completed) text='stage3 completed' ;;
    es:stage3_completed) text='stage3 completed' ;;
    en:stage3_copy_dotfiles) text='stage3 copy dotfiles' ;;
    es:stage3_copy_dotfiles) text='stage3 copy dotfiles' ;;
    en:stage3_entries) text='stage3 entries' ;;
    es:stage3_entries) text='stage3 entries' ;;
    en:stage3_failed) text='stage3 failed' ;;
    es:stage3_failed) text='stage3 failed' ;;
    en:stage3_free_apps) text='stage3 free apps' ;;
    es:stage3_free_apps) text='stage3 free apps' ;;
    en:stage3_free_apps_failed) text='stage3 free apps failed' ;;
    es:stage3_free_apps_failed) text='stage3 free apps failed' ;;
    en:stage3_free_apps_skipped) text='stage3 free apps skipped' ;;
    es:stage3_free_apps_skipped) text='stage3 free apps skipped' ;;
    en:stage3_hook_ready) text='stage3 hook ready' ;;
    es:stage3_hook_ready) text='stage3 hook ready' ;;
    en:stage3_integrate) text='stage3 integrate' ;;
    es:stage3_integrate) text='stage3 integrate' ;;
    en:stage3_kernel_wrapper) text='stage3 kernel wrapper' ;;
    es:stage3_kernel_wrapper) text='stage3 kernel wrapper' ;;
    en:stage3_makepkg_failed) text='stage3 makepkg failed' ;;
    es:stage3_makepkg_failed) text='stage3 makepkg failed' ;;
    en:stage3_migrations) text='stage3 migrations' ;;
    es:stage3_migrations) text='stage3 migrations' ;;
    en:stage3_missing) text='stage3 missing' ;;
    es:stage3_missing) text='stage3 missing' ;;
    en:stage3_none) text='stage3 none' ;;
    es:stage3_none) text='stage3 none' ;;
    en:stage3_not_built) text='stage3 not built' ;;
    es:stage3_not_built) text='stage3 not built' ;;
    en:stage3_ok) text='stage3 ok' ;;
    es:stage3_ok) text='stage3 ok' ;;
    en:stage3_optional_installer) text='stage3 optional installer' ;;
    es:stage3_optional_installer) text='stage3 optional installer' ;;
    en:stage3_sddm) text='stage3 sddm' ;;
    es:stage3_sddm) text='stage3 sddm' ;;
    en:stage3_snapper_failed) text='stage3 snapper failed' ;;
    es:stage3_snapper_failed) text='stage3 snapper failed' ;;
    en:stage3_snapper_missing) text='stage3 snapper missing' ;;
    es:stage3_snapper_missing) text='stage3 snapper missing' ;;
    en:stage3_snapper_ready) text='stage3 snapper ready' ;;
    es:stage3_snapper_ready) text='stage3 snapper ready' ;;
    en:stage3_summary) text='stage3 summary' ;;
    es:stage3_summary) text='stage3 summary' ;;
    en:stage3_terminal_missing) text='stage3 terminal missing' ;;
    es:stage3_terminal_missing) text='stage3 terminal missing' ;;
    en:stage3_theme) text='stage3 theme' ;;
    es:stage3_theme) text='stage3 theme' ;;
    en:stage3_theme_failed) text='stage3 theme failed' ;;
    es:stage3_theme_failed) text='stage3 theme failed' ;;
    en:stage3_tools_build) text='stage3 tools build' ;;
    es:stage3_tools_build) text='stage3 tools build' ;;
    en:stage3_tools_disabled) text='stage3 tools disabled' ;;
    es:stage3_tools_disabled) text='stage3 tools disabled' ;;
    en:stage3_ttfx_build) text='stage3 ttfx build' ;;
    es:stage3_ttfx_build) text='stage3 ttfx build' ;;
    en:stage3_ttfx_failed) text='stage3 ttfx failed' ;;
    es:stage3_ttfx_failed) text='stage3 ttfx failed' ;;
    en:stage3_units) text='stage3 units' ;;
    es:stage3_units) text='stage3 units' ;;
    en:stage3_unlinked) text='stage3 unlinked' ;;
    es:stage3_unlinked) text='stage3 unlinked' ;;
    en:stage3_updates) text='stage3 updates' ;;
    es:stage3_updates) text='stage3 updates' ;;
    en:stage3_vdagent_ready) text='stage3 vdagent ready' ;;
    es:stage3_vdagent_ready) text='stage3 vdagent ready' ;;
    en:stage3_vm_tuning) text='stage3 vm tuning' ;;
    es:stage3_vm_tuning) text='stage3 vm tuning' ;;
    en:trim_before) text='trim before' ;;
    es:trim_before) text='trim before' ;;
    en:trim_build_deps) text='trim build deps' ;;
    es:trim_build_deps) text='trim build deps' ;;
    en:trim_check) text='trim check' ;;
    es:trim_check) text='trim check' ;;
    en:trim_final) text='trim final' ;;
    es:trim_final) text='trim final' ;;
    en:trim_largest) text='trim largest' ;;
    es:trim_largest) text='trim largest' ;;
    en:trim_missing) text='trim missing' ;;
    es:trim_missing) text='trim missing' ;;
    en:trim_orphans) text='trim orphans' ;;
    es:trim_orphans) text='trim orphans' ;;
    en:trim_remove_failed) text='trim remove failed' ;;
    es:trim_remove_failed) text='trim remove failed' ;;
    en:trim_removed) text='trim removed' ;;
    es:trim_removed) text='trim removed' ;;
   *) text="$key" ;;
  esac
  printf "$text" "$@"
}
# OMARCHY_LOCALIZATION_CATALOG_END

UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
PHASES=(deps fetch prepare build utm verify sanitize package)

# ─────────────────────────────────── salida ────────────────────────────────
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_off=$'\033[0m'
phase() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
die()   { echo "  ${c_err}✗ $*${c_off}" >&2; exit 1; }

# ── interaccion ─────────────────────────────────────────────────────────────
# El script nacio desatendido y debe seguir siendolo: sin terminal, o con
# --yes, nadie pregunta nada y valen los valores por defecto. Con terminal
# pregunta lo que de verdad es una decision, y solo eso.
INTERACTIVO=0
[[ -t 0 && -t 1 ]] && INTERACTIVO=1
[[ -n ${ASSUME_YES:-} ]] && INTERACTIVO=0

ask() {  # ask <variable> <pregunta> [valor por defecto]
  local var="$1" q="$2" def="${3:-}" cur ans
  cur="${!var:-$def}"
  if (( ! INTERACTIVO )); then printf -v "$var" '%s' "$cur"; return; fi
  read -r -p "  $q [${cur}]: " ans </dev/tty || ans=""
  printf -v "$var" '%s' "${ans:-$cur}"
}

confirm() {  # confirm <pregunta> <si|no por defecto>
  local q="$1" def="${2:-si}" ans
  if (( ! INTERACTIVO )); then [[ $def == si ]]; return; fi
  local prompt_yes prompt_no
  prompt_yes=$(omarchy_msg yesno_yes)
  prompt_no=$(omarchy_msg yesno_no)
  read -r -p "  $q [$([[ $def == si ]] && printf '%s' "$prompt_yes" || printf '%s' "$prompt_no")]: " ans </dev/tty || ans=""
  ans="${ans:-$def}"
  # ${var,,} es de bash 4 y macOS trae bash 3.2: ahi es un error de expansion
  # que aborta la funcion entera, y confirm devolvia "si" por accidente.
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  case "$ans" in s|si|sí|y|yes) return 0 ;; *) return 1 ;; esac
}

# Valores por defecto tomados del propio Mac: asi la mayoria de las preguntas se
# contestan con Enter en vez de obligar a buscar el nombre de una zona horaria.
detectar_del_anfitrion() {
  local tz kb ncpu ram detected_keymap="" detected_xkb=""
  tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
  [[ -z $VM_TIMEZONE_EXPLICIT && -n $tz ]] && VM_TIMEZONE="$tz"
  kb=$(defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleSelectedInputSources 2>/dev/null \
       | sed -n 's/.*"KeyboardLayout Name" = "\([^"]*\)".*/\1/p' | head -1)
  case "$kb" in
    Spanish*)    detected_keymap=es; detected_xkb=es ;;
    U.S.*|ABC*|US*) detected_keymap=us; detected_xkb=us ;;
    British*)    detected_keymap=uk; detected_xkb=gb ;;
    German*)     detected_keymap=de; detected_xkb=de ;;
    French*)     detected_keymap=fr; detected_xkb=fr ;;
    Portuguese*) detected_keymap=pt; detected_xkb=pt ;;
    Italian*)    detected_keymap=it; detected_xkb=it ;;
  esac
  [[ -z $VM_KEYMAP_EXPLICIT && -n $detected_keymap ]] && VM_KEYMAP=$detected_keymap
  [[ -z $VM_XKB_EXPLICIT && -n $detected_xkb ]] && VM_XKB=$detected_xkb
  ncpu=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)
  ram=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  (( ncpu > 2 )) && UTM_CPUS=$(( ncpu / 2 ))
  (( ram >= 16384 )) && UTM_MEM=8192
  (( ram >= 32768 )) && UTM_MEM=12288
  BUILD_SMP=$(( ncpu > 8 ? 8 : ncpu ))
  (( ram >= 16384 )) && BUILD_MEM=8192
}

# ─────────────────────────────── fase: deps ────────────────────────────────
ph_deps() {
  phase "$(omarchy_msg phase_deps)"
  [[ $(uname -s) == Darwin ]] || die "$(omarchy_msg host_macos)"
  [[ $(uname -m) == arm64  ]] || die "$(omarchy_msg host_arm64)"
  command -v brew >/dev/null || die "$(omarchy_msg host_homebrew)"
  for f in qemu expect aria2; do
    brew list --formula "$f" >/dev/null 2>&1 || { info "$(omarchy_msg host_installing "$f")"; brew install "$f" >/dev/null; }
  done
  command -v qemu-system-aarch64 >/dev/null || die "$(omarchy_msg host_qemu)"
  command -v expect >/dev/null || die "$(omarchy_msg host_expect)"
  # git y python3 vienen de las Command Line Tools, que en un Mac recien
  # estrenado no estan. Se usan en 'prepare' y en la comprobacion de la rama.
  for c in git python3 zip shasum curl hdiutil; do
    command -v "$c" >/dev/null || die "$(omarchy_msg host_clt "$c")"
  done
  [[ -x $UTMCTL ]] || die "$(omarchy_msg host_utm)"
  # Medido en una construccion real: el disco llega a 9,5 GB, la copia para
  # sanitizar a otros 6,5 y el zip a 4. Con clones de APFS el pico ronda los 30.
  local free; free=$(df -g "$HOME" | tail -1 | awk '{print $4}')
  (( free > 40 )) || die "$(omarchy_msg host_disk_space "$free")"
  ok "$(omarchy_msg host_deps_ok "$(qemu-system-aarch64 --version | head -1 | awk '{print $4}')" "$(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString)" "$free")"
}

# Toda fase puede ejecutarse suelta con --only/--from, asi que los directorios
# no pueden depender de que se haya pasado por deps.
ensure_dirs() { mkdir -p "$W"/{dl,vm,provision,scripts,logs,dist,shots}; }

# ─────────────────────────────── fase: fetch ───────────────────────────────
ph_fetch() {
  phase "$(omarchy_msg phase_fetch)"
  local iso="$W/dl/alpine-virt-aarch64.iso"
  local tgz="$W/dl/alarm-rootfs.tgz"

  if [[ ! -s $iso ]]; then
    # Alpine RETIRA del CDN los parches antiguos al publicar el siguiente, asi
    # que fijar 3.24.1 caduca solo. Se resuelve el ultimo virt aarch64 de la
    # rama leyendo el indice, y ALPINE_ISO queda como respaldo.
    local base="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VER/releases/aarch64"
    local latest
    latest=$(curl -fsSL --max-time 30 "$base/" 2>/dev/null \
             | grep -oE 'alpine-virt-[0-9.]+-aarch64\.iso' | sort -V | tail -1)
    [[ -n $latest ]] || { warn "$(omarchy_msg fetch_index_failed "$ALPINE_ISO")"; latest="$ALPINE_ISO"; }
    info "$(omarchy_msg fetch_alpine_info "$latest")"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$iso").parcial" \
      "$base/$latest" || die "$(omarchy_msg fetch_alpine_failed "$base/$latest")"
    # Se verifica contra el sha256 publicado antes de darlo por bueno: una
    # descarga interrumpida deja un fichero no vacio que se reutilizaria siempre.
    local wsha gsha
    wsha=$(curl -fsSL --max-time 30 "$base/$latest.sha256" 2>/dev/null | awk '{print $1}')
    gsha=$(shasum -a 256 "$W/dl/$(basename "$iso").parcial" | awk '{print $1}')
    if [[ -n $wsha && $wsha != "$gsha" ]]; then
      rm -f "$W/dl/$(basename "$iso").parcial"
      die "$(omarchy_msg fetch_checksum_failed)"
    fi
    mv "$W/dl/$(basename "$iso").parcial" "$iso"
    [[ -n $wsha ]] && info "$(omarchy_msg fetch_checksum_ok)" || warn "$(omarchy_msg fetch_checksum_missing)"
  fi
  ok "$(omarchy_msg fetch_alpine_done "$(du -h "$iso" | cut -f1)")"

  if [[ ! -s $tgz ]]; then
    info "$(omarchy_msg fetch_rootfs_info)"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$tgz")" \
      "$ALARM_URL" || die "$(omarchy_msg fetch_rootfs_failed)"
  fi
  # El tarball se rehace cada pocas semanas: se verifica contra el MD5 publicado
  local want got
  want=$(curl -fsSL --max-time 30 "$ALARM_URL.md5" | awk '{print $1}')
  got=$(md5 -q "$tgz")
  if [[ -z $want ]]; then
    # Antes se anunciaba "MD5 verificado" aunque el curl del checksum fallara.
    warn "$(omarchy_msg fetch_md5_missing "$ALARM_URL")"
    ok "$(omarchy_msg fetch_md5_unverified "$(du -h "$tgz" | cut -f1)")"
  elif [[ $want != "$got" ]]; then
    warn "$(omarchy_msg fetch_md5_mismatch "$want" "$got")"
    rm -f "$tgz"
    [[ ${FETCH_RETRY:-0} -ge 1 ]] && die "$(omarchy_msg fetch_md5_failed)"
    FETCH_RETRY=1 ph_fetch; return
  else
    ok "$(omarchy_msg fetch_md5_ok "$(du -h "$tgz" | cut -f1)")"
  fi
}

# ────────────────────────────── fase: prepare ──────────────────────────────
ph_prepare() {
  phase "$(omarchy_msg phase_prepare)"
  # quattro es una rama de pre-release: cuando la fusionen o la borren, todo lo
  # que sigue falla sin decir por que. Se comprueba antes y se cae a la rama por
  # defecto del repositorio, avisando.
  if ! git ls-remote --exit-code --heads https://github.com/basecamp/omarchy.git "$OMARCHY_REF" >/dev/null 2>&1; then
    local defref
    defref=$(git ls-remote --symref https://github.com/basecamp/omarchy.git HEAD 2>/dev/null \
             | sed -n 's#^ref: refs/heads/\([^\t ]*\).*#\1#p' | head -1)
    [[ -n $defref ]] || die "$(omarchy_msg prepare_ref_missing "$OMARCHY_REF")"
    warn "$(omarchy_msg prepare_ref_fallback "$OMARCHY_REF" "$defref")"
    warn "$(omarchy_msg prepare_ref_warning)"
    OMARCHY_REF="$defref"
  fi
  # La lista se calcula contra la rama VIVA de Omarchy interseccionada con lo que
  # existe en Arch Linux ARM. Hacerlo aqui, y no con una lista fija, evita que el
  # build se rompa cuando Omarchy cambie de paquetes.
  local base=/tmp/om-base.$$ core=/tmp/alarm-core.$$ extra=/tmp/alarm-extra.$$
  curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/basecamp/omarchy/$OMARCHY_REF/install/omarchy-base.packages" \
    -o "$base" || die "$(omarchy_msg prepare_packages_failed)"
  curl -fsSL --max-time 120 http://mirror.archlinuxarm.org/aarch64/core/core.db   -o "$core"  || die "$(omarchy_msg prepare_mirror_failed)"
  curl -fsSL --max-time 180 http://mirror.archlinuxarm.org/aarch64/extra/extra.db -o "$extra" || die "$(omarchy_msg prepare_mirror_failed)"

  local d=/tmp/alarmdb.$$; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && tar -xzf "$core"; tar -xzf "$extra" )
  ls -1 "$d" | sed -E 's/-[^-]+-[^-]+$//' | sort -u > /tmp/alarm-pkgs.$$

  # quickshell-git no existe en ALARM; quickshell 0.3.x lo sustituye.
  # nvim y ttf-jetbrains-mono-nerd-basic son nombres propios de Omarchy.
  python3 - "$base" /tmp/alarm-pkgs.$$ "$W/provision" <<'PYEOF'
import sys, pathlib
base, alarm_f, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
alarm = set(open(alarm_f).read().split())
subs = {'quickshell-git':'quickshell','ttf-jetbrains-mono-nerd-basic':'ttf-jetbrains-mono-nerd','nvim':'neovim'}
pkgs = [l.strip() for l in open(base) if l.strip() and not l.startswith('#')]
infra = """mesa vulkan-swrast vulkan-icd-loader xorg-xwayland qt6-wayland qt5-wayland
pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber xdg-user-dirs xdg-utils polkit
sddm uwsm hypridle hyprlock hyprpaper hyprshot swaybg wl-clipboard slurp satty
noto-fonts noto-fonts-cjk noto-fonts-emoji terminus-font woff2-font-awesome
go nodejs npm python openssh htop wget curl unzip zip rsync mesa-utils wayland-utils pacman-contrib
networkmanager btrfs-progs efibootmgr spice-vdagent qemu-guest-agent""".split()
heavy = set("""libreoffice-fresh kdenlive signal-desktop obs-studio moonlight-qt tesseract
tesseract-data-eng gpu-screen-recorder xournalpp evince system-config-printer cups cups-browsed
cups-filters cups-pdf docker docker-buildx docker-compose rust ruby clang llvm luarocks
mariadb-libs postgresql-libs python-poetry-core tree-sitter-cli usage ufw fcitx5 fcitx5-gtk
fcitx5-qt bolt kernel-modules-hook ffmpegthumbnailer lazydocker firefox dotnet-runtime""".split())
core, ext, miss = [], [], []
for p in pkgs + infra:
    p = subs.get(p, p)
    if p not in alarm: miss.append(p); continue
    (ext if p in heavy else core).append(p)
def dd(xs):
    s=set(); o=[]
    for x in xs:
        if x not in s: s.add(x); o.append(x)
    return o
core, ext = dd(core), dd(ext)
(out/'packages-core.txt').write_text("# nucleo\n"+"\n".join(core)+"\n")
(out/'packages-extra.txt').write_text("# extras best-effort\n"+"\n".join(ext)+"\n")
print(f"  nucleo={len(core)}  extras={len(ext)}  sin equivalente en ARM={len(set(miss))}")
print("  no disponibles:", " ".join(sorted(set(miss))))
PYEOF
  rm -rf "$d" "$base" "$core" "$extra" /tmp/alarm-pkgs.$$
  # Sin esto un fallo de escritura pasaria inadvertido y el build moriria mas
  # tarde, lejos de la causa.
  [ -s "$W/provision/packages-core.txt" ] || die "$(omarchy_msg prepare_lists_failed)"
  ok "$(omarchy_msg prepare_lists_ok "$OMARCHY_REF" "$(grep -cvE '^#|^$' "$W/provision/packages-core.txt")" "$(grep -cvE '^#|^$' "$W/provision/packages-extra.txt")")"
}

# ─────────────────────────── payloads (se escriben en $W) ──────────────────
write_payloads() {
  # Los ficheros de provision y los arneses expect se materializan aqui para que
  # este script sea autocontenido: un solo fichero reproduce todo el proceso.
mkdir -p "$W/provision"
# Materialize the exact embedded catalog alongside every payload. The standalone
# payloads source this file, so copied scripts retain the selected language.
declare -f omarchy_msg > "$W/provision/catalog.sh"
chmod 0644 "$W/provision/catalog.sh"
cat > "$W/provision/stage1.sh" <<'__PAYLOAD_PROVISION_STAGE1_SH__'
#!/bin/sh
# Etapa 1 — se ejecuta en el live de Alpine (busybox ash).
# Particiona el disco, despliega el rootfs de Arch Linux ARM y entra en chroot.
set -eu
PROV=/media/prov
if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" "$PROV/catalog.sh" /usr/local/share/omarchy/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }
log()  { echo ""; echo "==> [stage1] $*"; }
warn() { echo "!!  [stage1] $*"; }

# Marcador de salida fiable: un pipe a tee enmascara el codigo de retorno,
# asi que el propio script emite el token.
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_BUILD_$rc"' EXIT

log "$(msg stage1_network)"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 15 >/dev/null 2>&1 || true
ip -4 addr show eth0 | grep -o 'inet [0-9.]*' || echo "  ($(msg stage1_no_ipv4))"

log "$(msg stage1_tools)"
V=$(cut -d. -f1,2 < /etc/alpine-release)
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v$V/main
https://dl-cdn.alpinelinux.org/alpine/v$V/community
EOF
apk update >/dev/null
apk add --no-cache parted dosfstools btrfs-progs libarchive-tools e2fsprogs >/dev/null
echo "  $(msg stage1_ok): $(parted --version | head -1)"

log "$(msg stage1_fs_modules)"
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
if grep -qw btrfs /proc/filesystems; then
  ROOTFS=btrfs
else
  warn "$(msg stage1_btrfs_fallback)"
  ROOTFS=ext4
fi
grep -qw vfat /proc/filesystems || warn "$(msg stage1_vfat_missing)"
echo "  $(msg stage1_root): $ROOTFS   $(msg stage1_filesystems): $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "$(msg stage1_partition "$DISK" "$ROOTFS")"
umount -R /mnt 2>/dev/null || true
wipefs -a "$DISK" >/dev/null 2>&1 || true
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart OMBOOT fat32 1MiB 1025MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart OMROOT "$ROOTFS" 1025MiB 100%
sync; sleep 1
mkfs.vfat -F32 -n OMBOOT "${DISK}1" >/dev/null
if [ "$ROOTFS" = btrfs ]; then
  mkfs.btrfs -f -L OMROOT "${DISK}2" >/dev/null
else
  mkfs.ext4 -qF -L OMROOT "${DISK}2"
fi
sync
parted -s "$DISK" print

MOPT_ROOT=""
if [ "$ROOTFS" = btrfs ]; then
  log "$(msg stage1_subvolumes)"
  mount -t btrfs "${DISK}2" /mnt
  btrfs subvolume create /mnt/@     >/dev/null
  btrfs subvolume create /mnt/@home >/dev/null
  umount /mnt
  MOPT="rw,noatime,compress=zstd:3"
  mount -t btrfs -o "$MOPT,subvol=@" "${DISK}2" /mnt
  mkdir -p /mnt/home
  mount -t btrfs -o "$MOPT,subvol=@home" "${DISK}2" /mnt/home
  MOPT_ROOT="$MOPT,subvol=@"
else
  mount -t ext4 "${DISK}2" /mnt
  mkdir -p /mnt/home
  MOPT_ROOT="rw,noatime"
fi
df -h /mnt

log "$(msg stage1_deploy_rootfs)"
# La ESP se monta DESPUES: vfat no admite los symlinks que trae /boot en el
# tarball. El kernel lo repuebla pacman en stage2 sobre la ESP ya montada.
bsdtar -xpf "$PROV/alarm-rootfs.tgz" -C /mnt
echo "  $(msg stage1_contents): $(ls /mnt | tr '\n' ' ')"
[ -d /mnt/etc ] && [ -d /mnt/usr ] || { warn "$(msg stage1_rootfs_incomplete)"; exit 1; }

log "$(msg stage1_mount_esp)"
rm -rf /mnt/boot
mkdir -p /mnt/boot
mount -t vfat "${DISK}1" /mnt/boot
df -h /mnt /mnt/boot

log "$(msg stage1_mounts)"
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc  none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true

log "$(msg stage1_dns)"
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf

log "$(msg stage1_copy_payload)"
mkdir -p /mnt/root/prov
cp "$PROV/stage2.sh" "$PROV/stage3.sh" "$PROV/config.env" \
   "$PROV/packages-core.txt" "$PROV/packages-extra.txt" /mnt/root/prov/
[ -f "$PROV/catalog.sh" ] && {
  cp "$PROV/catalog.sh" /mnt/root/prov/catalog.sh
  mkdir -p /mnt/usr/local/share/omarchy
  cp "$PROV/catalog.sh" /mnt/usr/local/share/omarchy/catalog.sh
}
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
cat > /mnt/root/prov/fsinfo.env <<EOF
ROOTFS=$ROOTFS
ROOT_MOUNT_OPTS=$MOPT_ROOT
EOF
chmod +x /mnt/root/prov/stage2.sh /mnt/root/prov/stage3.sh

log "$(msg stage1_chroot)"
set +e
chroot /mnt /bin/bash /root/prov/stage2.sh
rc=$?
set -e

log "$(msg stage1_unmount)"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "==> [stage1] $(msg stage1_finished "$rc")"
echo "TOK_BUILD_$rc"
trap - EXIT
exit $rc
__PAYLOAD_PROVISION_STAGE1_SH__
chmod +x "$W/provision/stage1.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage2.sh" <<'__PAYLOAD_PROVISION_STAGE2_SH__'
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
__PAYLOAD_PROVISION_STAGE2_SH__
chmod +x "$W/provision/stage2.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage3.sh" <<'__PAYLOAD_PROVISION_STAGE3_SH__'
#!/bin/bash
# Etapa 3 — como usuario normal dentro del chroot.
# Dotfiles de Omarchy, tema, y las piezas que solo existen en AUR.
set -uo pipefail   # sin -e: esta etapa es best-effort por partes
. ~/config.env

if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" /root/prov/catalog.sh /usr/local/share/omarchy/catalog.sh /media/prov/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }

log()  { echo ""; echo "==> [stage3] $*"; }
warn() { echo "!!  [stage3] $*"; }

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export PATH="$OMARCHY_PATH/bin:$PATH:$HOME/.local/bin"
export OMARCHY_CHROOT_INSTALL=1

# ------------------------------------------------------------ repo de Omarchy
log "$(msg stage3_clone "${OMARCHY_REF:-quattro}")"
rm -rf "$OMARCHY_PATH"
mkdir -p "$(dirname "$OMARCHY_PATH")"
git clone --depth 1 --branch "${OMARCHY_REF:-quattro}" https://github.com/basecamp/omarchy.git "$OMARCHY_PATH" || { warn "$(msg stage3_clone_failed)"; exit 1; }
# core.fileMode=false ANTES del chmod: si no, los cambios de permiso dejan el
# checkout sucio y `git pull --ff-only` se niega a actualizarlo despues.
git -C "$OMARCHY_PATH" config core.fileMode false
find "$OMARCHY_PATH/bin" -type f -exec chmod +x {} \; 2>/dev/null
echo "  version: $(cat "$OMARCHY_PATH/version" 2>/dev/null)"

# ------------------------------------------------------------ dotfiles
# Equivalente a install/config/config.sh
log "$(msg stage3_copy_dotfiles)"
mkdir -p ~/.config
cp -R "$OMARCHY_PATH"/config/* ~/.config/
cp "$OMARCHY_PATH/default/bashrc" ~/.bashrc
ls ~/.config | tr '\n' ' '; echo

# ------------------------------------------------------------ AUR
log "$(msg stage3_aur)"
mkdir -p /tmp/aur
aur_install() {
  local p="$1"
  echo "  --- $p"
  rm -rf "/tmp/aur/$p"
  git clone --depth 1 -q "https://aur.archlinux.org/$p.git" "/tmp/aur/$p" || { warn "$(msg stage3_clone_package "$p")"; return 1; }
  ( cd "/tmp/aur/$p" && makepkg -si --noconfirm --needed --noprogressbar ) >"/tmp/aur/$p.log" 2>&1 \
    || { warn "$(msg stage3_makepkg_failed "$p")"; tail -15 "/tmp/aur/$p.log"; return 1; }
  echo "  $(msg stage3_ok): $p"
}

AUR_OK=(); AUR_KO=()
# xdg-terminal-exec resuelve $TERMINAL. walker y elephant NO se instalan:
# quattro los jubila (ver bin/omarchy-upgrade-to-quattro), el lanzador y el
# menu son paneles de quickshell (`omarchy-shell shell toggle omarchy.menu`).
for p in yay xdg-terminal-exec; do
  if aur_install "$p"; then AUR_OK+=("$p"); else AUR_KO+=("$p"); fi
done
echo "  AUR $(msg stage3_ok):    ${AUR_OK[*]:-$(msg stage3_none)}"
echo "  AUR $(msg stage3_failed): ${AUR_KO[*]:-$(msg stage3_none)}"

# Sustituto si xdg-terminal-exec no compiló: Omarchy usa $TERMINAL=xdg-terminal-exec
if ! command -v xdg-terminal-exec >/dev/null 2>&1; then
  warn "$(msg stage3_terminal_missing)"
  sudo install -m 0755 /dev/stdin /usr/local/bin/xdg-terminal-exec <<'EOF'
#!/bin/sh
# Envoltorio minimo: Omarchy exporta TERMINAL=xdg-terminal-exec.
# El respaldo es foot, que si esta en omarchy-base.packages de quattro
# (alacritty no lo esta: apuntar ahi dejaba $TERMINAL roto).
T=$(command -v foot || command -v alacritty || command -v xterm) || exit 127
if [ "$#" -eq 0 ]; then exec "$T"; fi
exec "$T" -e "$@"
EOF
fi

# Terminal por defecto: Omarchy prefiere ghostty, que no existe en aarch64
printf 'Alacritty.desktop\n' > ~/.config/xdg-terminals.list

# ------------------------------------------------ integracion de sistema
# Omarchy 4 se distribuye como paquete pacman que coloca el arbol en
# /usr/share/omarchy, los binarios en el PATH del sistema y hooks en
# /etc/profile.d y /usr/share/uwsm/env.d. Ese paquete solo existe para x86_64,
# asi que aqui se replica a mano. Sin esto OMARCHY_PATH queda vacio y Hyprland
# arranca en modo emergencia por no encontrar default/hypr/bootstrap.lua.
log "$(msg stage3_integrate)"
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
# Los comandos van a /usr/bin, que es donde los pone el package() de upstream.
# Ponerlos en /usr/local/bin parecia mas limpio (no choca con pacman) pero
# rompe cosas: el arbol lleva 13 rutas /usr/bin/omarchy-* cableadas, cinco de
# ellas en ficheros .service. enable-user-units.sh fallaba por eso, y como
# first-run solo se marca hecho si NINGUN paso falla, se repetia en cada login
# reenviando el aviso "Update System" para siempre.
# Comprobado: ninguno de los 433 nombres colisiona con un paquete de ALARM.
sudo mkdir -p /usr/bin
# Los enlaces apuntan a /usr/share/omarchy, NO a $OMARCHY_PATH. Aqui son la
# misma cosa (el primero es un symlink al segundo), pero el sanitizador
# convierte /usr/share/omarchy en directorio real y renombra al usuario: un
# enlace a /home/<constructor>/... queda colgado y se lleva por delante los 433
# comandos. /usr/share/omarchy es la unica ruta estable de las dos.
n=0
for f in "$OMARCHY_PATH"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  sudo ln -sfn "/usr/share/omarchy/bin/$(basename "$f")" "/usr/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $(msg stage3_binaries "$n")"
# Las unidades de usuario van a /usr/lib/systemd/user/, que es donde systemd las
# busca. Las instala el paquete omarchy-settings, que tampoco existe para ARM.
# Sin esto, install/user/first-run/enable-user-units.sh falla en cada login, y
# como omarchy-provision-first-run solo se marca hecho si NINGUN paso falla, el
# first-run se repite indefinidamente reenviando el aviso "Update System".
# Fuente: docs/file-layout.md, "systemd/user/*.service → /usr/lib/systemd/user/".
if [ -d "$OMARCHY_PATH/default/systemd/user" ]; then
  sudo install -d /usr/lib/systemd/user
  sudo cp -a "$OMARCHY_PATH/default/systemd/user/." /usr/lib/systemd/user/
  unit_count=$(ls "$OMARCHY_PATH/default/systemd/user"/*.service 2>/dev/null | wc -l)
  echo "  $(msg stage3_units "$unit_count")"
fi
for d in system-sleep zram-generator.conf.d; do
  [ -d "$OMARCHY_PATH/default/systemd/$d" ] && \
    sudo cp -a "$OMARCHY_PATH/default/systemd/$d" /usr/lib/systemd/ 2>/dev/null || true
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
sudo cp -a "$OMARCHY_PATH/etc/sysctl.d/." /etc/sysctl.d/ 2>/dev/null || true
sudo cp -a "$OMARCHY_PATH/etc/security/." /etc/security/ 2>/dev/null || true
for d in system.conf.d user.conf.d logind.conf.d oomd.conf.d; do
  [ -d "$OMARCHY_PATH/etc/systemd/$d" ] && sudo cp -a "$OMARCHY_PATH/etc/systemd/$d" /etc/systemd/ 2>/dev/null || true
done
[ -d "$OMARCHY_PATH/etc/fastfetch" ] && sudo cp -a "$OMARCHY_PATH/etc/fastfetch" /etc/ 2>/dev/null || true
[ -d "$OMARCHY_PATH/etc/gnupg" ] && sudo cp -a "$OMARCHY_PATH/etc/gnupg/." /etc/gnupg/ 2>/dev/null || true
# systemd-oomd viene configurado en etc/systemd/oomd.conf.d pero hay que
# habilitarlo; NetworkManager-wait-online retrasa el arranque sin aportar nada
# en una VM con red de usuario.
sudo systemctl enable systemd-oomd.service 2>/dev/null || true
sudo systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# gnome-keyring en el PAM de SDDM bloquea el autologin sin llavero configurado
for pf in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
  [ -f "$pf" ] && sudo sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' "$pf"
done

log "$(msg stage3_sddm)"
sudo mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions
sudo cp -a "$OMARCHY_PATH/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OMARCHY_PATH/default/sddm/hyprland.lua" ] && sudo cp -a "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
sudo install -Dm644 "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" 2>&1 | tail -2 || true

export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/local/bin:$PATH"

# ------------------------------------------------------------ tema
log "$(msg stage3_theme)"
mkdir -p ~/.config/omarchy/themes
if command -v omarchy-theme-set >/dev/null 2>&1; then
  omarchy-theme-set "Tokyo Night" || warn "$(msg stage3_theme_failed)"
fi
if [ ! -e ~/.config/omarchy/current/theme ]; then
  mkdir -p ~/.config/omarchy/current
  ln -snf "$OMARCHY_PATH/themes/tokyo-night" ~/.config/omarchy/current/theme
fi
# Enlaces de tema por app. En quattro el tema activo vive en
# ~/.local/state/omarchy/current/theme (bin/omarchy-theme-set:12), no en
# ~/.config/omarchy/current, que es la ruta de Omarchy 3 y aqui no existe.
# No hay enlace de mako: quattro no tiene demonio de notificaciones externo.
mkdir -p ~/.config/btop/themes
ln -snf ~/.local/state/omarchy/current/theme/btop.theme ~/.config/btop/themes/current.theme
ls -l ~/.local/state/omarchy/current/ 2>/dev/null

# ------------------------------------------------------------ ajustes de VM
log "$(msg stage3_vm_tuning)"
# quattro usa configuracion Lua: escribir monitors.conf no serviria de nada.
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Modos disponibles:  hyprctl monitors all
--
-- VM en UTM/QEMU con virtio-gpu. Dos ajustes respecto a los valores de Omarchy:
--
--  1. Escala 1 (Omarchy asume pantallas retina 2x; en la VM deja todo gigante).
--  2. Resolucion fija 1920x1200 en vez de "preferred", que da 1280x800.
--
-- IMPORTANTE: cambiar el modo EN CALIENTE (hyprctl / recarga de config) rompe
-- el renderizado bajo virgl: el escritorio se queda en blanco hasta reiniciar.
-- Aplicado desde el arranque funciona bien. Si tocas esto, reinicia la VM.
--
-- Para que la resolucion siga al tamano de la ventana de UTM:
--   hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
LUA
rm -f ~/.config/hypr/monitors.conf ~/.config/hypr/autostart.conf

# Portapapeles compartido con el host de UTM
cat > ~/.config/hypr/autostart.lua <<'LUA'
-- Procesos extra al iniciar la sesion.
hl.on("hyprland.start", function()
  hl.exec_cmd("uwsm-app -- spice-vdagent")
end)
LUA

# --- sellar migraciones: un install limpio nace con el estado final -------
# Sin esto omarchy-update intenta reproducir ~80 migraciones historicas y muere
# en la primera que instale un paquete propio de Omarchy (x86_64 only).
mkdir -p ~/.local/state/omarchy/migrations
for f in "$OMARCHY_PATH"/migrations/*.sh; do
  [ -f "$f" ] && : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
migration_count=$(ls -1 ~/.local/state/omarchy/migrations | wc -l)
echo "  $(msg stage3_migrations "$migration_count")"

# --- branding (about + salvapantallas) -----------------------------------
mkdir -p ~/.config/omarchy/branding
cp "$OMARCHY_PATH/icon.txt" ~/.config/omarchy/branding/about.txt 2>/dev/null || true
cp "$OMARCHY_PATH/logo.txt" ~/.config/omarchy/branding/screensaver.txt 2>/dev/null || true

# --- omarchy-pkg-add tolerante con lo que no existe en ARM ---------------
# CRITICO: /usr/local/bin/omarchy-pkg-add es un symlink al arbol. Escribir con
# `tee` lo seguiria y reemplazaria el script ORIGINAL de Omarchy por este
# envoltorio, cuyo REAL apuntaria entonces a si mismo: bucle infinito. Hay que
# borrar el symlink y crear un fichero real.
sudo rm -f /usr/local/bin/omarchy-pkg-add
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-pkg-add <<'WRAP'
#!/bin/bash
# Envoltorio para Arch Linux ARM: los paquetes propios de Omarchy (tensaku,
# omarchy-nvim, ttfx...) y varias apps propietarias solo existen para x86_64.
# El original aborta si falta alguno, lo que tumba omarchy-update entero y deja
# las migraciones a medias. Aqui se omiten con un aviso y se instala el resto.
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf '\033[33mOmitido, no existe en Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP

# --- herramientas de Omarchy que no se publican para aarch64 -------------
# Casi ninguna es incompatible: son Rust, Go o Qt/C++ y solo les falta que
# alguien las construya. Varias declaran arch=(x86_64) por omision, no porque
# el codigo no sea portable; en esos casos basta con anadir la arquitectura.
# Se compilan en orden de coste creciente y ninguna es fatal si falla.
build_omarchy_tool() {                 # build_omarchy_tool <aur|omapkgs> <pkg>
  # Un unico `local` expande todos los valores antes de asignar ninguno,
  # asi que $pkg no existe aun al construir $dir. Hay que separarlos.
  local src="$1" pkg="$2"
  local dir="/tmp/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0
  rm -rf "$dir"; mkdir -p "$dir"
  case "$src" in
    aur)
      # Las URL de AUR usan el PackageBase, que no siempre es el nombre del
      # paquete (yaru-icon-theme vive en el repo "yaru").
      local base
      base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
             | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$base" ] || base="$pkg"
      git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null || return 1 ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo" || return 1
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" >/dev/null 2>&1 )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" 2>/dev/null || return 1
      rm -rf "$dir/repo" ;;
  esac
  [ -f "$dir/PKGBUILD" ] || return 1
  # 'any' puede venir sin comillas; mezclarlo con arquitecturas concretas es un
  # error de makepkg, asi que solo se parchea cuando no es 'any' ni trae aarch64.
  grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
  # Un PKGBUILD puede generar varios subpaquetes y que solo uno de ellos tenga
  # una dependencia ausente en ARM (yaru-gtk-theme necesita gtk-engine-murrine).
  # Se compila sin instalar y despues se instala solo el subpaquete pedido.
  # -s instala las dependencias de compilacion. Sin el, la mayoria de estos
  # PKGBUILD fallan en el primer paso por makedepends ausentes. No se usa -i
  # porque la instalacion se hace despues, subpaquete a subpaquete.
  if ( cd "$dir" && makepkg -s --noconfirm --needed --noprogressbar --nocheck ) >"$dir/build.log" 2>&1; then
    local built
    built=$(ls "$dir/$pkg"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$built" ] || built=$(ls "$dir"/*.pkg.tar.* 2>/dev/null | head -1)
    # theme-system.sh ya creo symlinks dentro de /usr/share/icons/Yaru porque el
    # tema no estaba: el paquete real choca con ellos. --overwrite lo resuelve.
    [ -n "$built" ] && sudo pacman -U --noconfirm --needed \
      --overwrite '/usr/share/icons/*' "$built" >>"$dir/build.log" 2>&1
  else
    return 1
  fi
}

# Algunos PKGBUILD invocan zig por ruta fija y versionada (/opt/zig0.15/zig).
# En ARM solo hay una version de zig, asi que se enlaza donde la buscan.
if pacman -Si zig >/dev/null 2>&1; then
  sudo pacman -S --noconfirm --needed zig >/dev/null 2>&1 || true
  for v in zig0.15 zig0.14; do
    sudo mkdir -p "/opt/$v" && sudo ln -sfn "$(command -v zig)" "/opt/$v/zig" 2>/dev/null || true
  done
fi

if [ "${HACER_TOOLS:-si}" != "si" ]; then
  warn "$(msg stage3_tools_disabled)"
else
log "$(msg stage3_tools_build)"
TOOLS_OK=(); TOOLS_KO=()
for spec in \
  "aur:yaru-icon-theme" "aur:ttf-ia-writer" "aur:tzupdate" "aur:ufw-docker" \
  "omapkgs:omarchy-nvim" "omapkgs:tobi-try" "aur:mise-bin" \
  "aur:aether" "aur:cliamp" \
  "omapkgs:omacalc" "omapkgs:omacut" "omapkgs:omawrite" \
  "aur:herdr" "omapkgs:tensaku" "omapkgs:hyprland-preview-share-picker"; do
  src=${spec%%:*}; pkg=${spec#*:}
  if build_omarchy_tool "$src" "$pkg"; then TOOLS_OK+=("$pkg"); else TOOLS_KO+=("$pkg"); fi
done
echo "  $(msg stage3_built): ${TOOLS_OK[*]:-$(msg stage3_none)}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "$(msg stage3_not_built "${TOOLS_KO[*]}")"
rm -rf /tmp/omabuild
fi
# Omarchy sustituye a proposito dos iconos de Yaru por los de Adwaita; si Yaru
# se acaba de instalar hay que volver a aplicarlo.
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" >/dev/null 2>&1 || true

# herdr queda fuera: su PKGBUILD usa `zig fetch` con la semantica de Zig 0.15 y
# Arch Linux ARM solo empaqueta 0.16 ("no build.zig file found"). Construir
# zig0.15 desde fuente son horas y es una herramienta de desarrollo, no del
# escritorio.

# --- el aviso de reinicio por kernel, que en ARM no se apaga nunca -------
# omarchy-update-restart decide si el kernel cambio buscando un vmlinuz dentro
# de /usr/lib/modules/<version>/ que pertenezca a un paquete. En Arch x86_64 el
# paquete linux lo instala ahi; en Arch Linux ARM, linux-aarch64 deja la imagen
# en /boot/Image y NO crea ese vmlinuz. El bucle no encuentra nada, la variable
# se queda en "true" y pide reiniciar en cada actualizacion, para siempre.
# Este envoltorio compara lo que de verdad toca: uname -r contra el directorio
# de modulos que posee el paquete del kernel. /usr/local/bin va antes que
# /usr/bin en el PATH, asi que sustituye al original sin tocar el arbol.
log "$(msg stage3_kernel_wrapper)"
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-update-restart <<'KRN'
#!/bin/bash
# En Arch Linux ARM el kernel no deja vmlinuz en /usr/lib/modules/<ver>/, que es
# lo que busca el original: sin eso pide reiniciar siempre. Se compara uname -r
# con el directorio de modulos que pertenece al paquete del kernel.
if [ -z "${OMARCHY_SKIP_KERNEL_CHECK:-}" ]; then
  # modules.dep lo genera depmod y no pertenece a ningun paquete. modules.builtin
  # si lo trae linux-aarch64, asi que sirve para saber si el directorio de
  # modulos del kernel en ejecucion es el del paquete instalado.
  pkg=$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null \
        || pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.order 2>/dev/null || true)
  if [ -n "$pkg" ]; then
    # El directorio de modulos del kernel en ejecucion pertenece al paquete
    # instalado: no hay kernel nuevo esperando un reinicio.
    export OMARCHY_KERNEL_CURRENT=1
  fi
fi
REAL=/usr/bin/omarchy-update-restart
[ -x "$REAL" ] || exit 0
if [ -n "${OMARCHY_KERNEL_CURRENT:-}" ]; then
  # Se omite solo el bloque del kernel; el resto (Hyprland, servicios, shell)
  # se deja intacto ejecutando el original con esa comprobacion ya resuelta.
  sed 's#^kernel_updated=true$#kernel_updated=false#' "$REAL" | bash -s -- "$@"
else
  exec "$REAL" "$@"
fi
KRN
echo "  /usr/local/bin/omarchy-update-restart"

# --- ttfx: efectos de texto del salvapantallas (Rust, ~12 min) -----------
if ! command -v ttfx >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  log "$(msg stage3_ttfx_build)"
  rm -rf /tmp/ttfx-src
  if git clone --depth 1 -q https://github.com/omacom-io/ttfx.git /tmp/ttfx-src \
     && ( cd /tmp/ttfx-src && cargo build --release -q ); then
    sudo install -Dm755 /tmp/ttfx-src/target/release/ttfx /usr/local/bin/ttfx
    echo "  ttfx $(ttfx --version 2>/dev/null | head -1)"
  else
    warn "$(msg stage3_ttfx_failed)"
  fi
  rm -rf /tmp/ttfx-src
fi

# --- teclado: layout es y Super utilizable desde macOS -------------------
# macOS intercepta Cmd antes de que UTM lo vea (Cmd+Space abre Spotlight), asi
# que los atajos SUPER de Omarchy serian inalcanzables. altwin:swap_lalt_lwin
# intercambia Alt y Super: la tecla Option (⌥) del Mac actua como SUPER.
cat > ~/.config/hypr/input.lua <<LUA
hl.config({
  input = {
    kb_layout  = "$VM_XKB",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
LUA

# --- sin blur: el render va por llvmpipe (ver 90-vm-graphics.conf) --------
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
hl.config({
  decoration = {
    blur   = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

# --- refuerzo del entorno para apps lanzadas por uwsm --------------------
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF

# Directorios de usuario
xdg-user-dirs-update 2>/dev/null || true
mkdir -p ~/Pictures/Screenshots ~/Videos ~/Desktop ~/Documents ~/Downloads

# ------------------------------------------------------------ git
# --- instalador opcional de apps que no vienen en la imagen ---------------
# Varias apps (1Password, Obsidian, Typora, LocalSend) SI tienen build arm64
# oficial, pero son propietarias: incluirlas en una imagen que se distribuye
# seria redistribuir binarios de terceros. Se deja el instalador a mano.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-extras" ]; then
  log "$(msg stage3_optional_installer)"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-extras" /usr/local/bin/omarchy-arm-extras
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=$(msg desktop_name)
Comment=1Password, Obsidian, Typora, LocalSend, Google Chrome
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  echo "  $(msg stage3_available_menu)"
fi

# --- portapapeles compartido con el anfitrion ---------------------------
# UTM expone el canal correcto:
#   -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
# El problema es el agente de referencia: spice-vdagent habla ese canal pero
# entrega el portapapeles solo a X11 (vdagent.c:421 ->
# vdagent_clipboards_new(vdagent_display_get_x11(...)), y cero referencias a
# wlr-data-control en todo su repositorio). Bajo Wayland nativo no tiene con
# quien hablar, y ni el flag -X lo arregla: esa guarda es anterior, la del
# enrutado por sesion de seat0.
# omarchy-arm-vdagent habla el MISMO protocolo por el MISMO puerto, pero al
# otro lado usa wl-copy/wl-paste. Se activa solo, como servicio de usuario.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" ]; then
  log "$(msg stage3_clipboard_agent)"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" /usr/local/bin/omarchy-arm-vdagent
  # spice-vdagent se queda instalado (aporta redimensionado de pantalla) pero
  # NO debe competir por el puerto: se le quita el arranque automatico.
  sudo systemctl disable spice-vdagentd.socket 2>/dev/null || true
  sudo systemctl disable spice-vdagentd.service 2>/dev/null || true
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (SPICE vdagent sobre Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY
ConditionPathExists=/dev/virtio-ports/com.redhat.spice.0

[Service]
Type=simple
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable omarchy-arm-vdagent.service 2>/dev/null || true
  echo "  $(msg stage3_vdagent_ready)"
fi
# Puente por carpeta compartida, como alternativa si el canal SPICE no esta
# disponible (por ejemplo con el backend de virtualizacion de Apple).
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" /usr/local/bin/omarchy-arm-clipboard
  echo "  $(msg stage3_clipboard_fallback)"

  # OBS Studio y Pinta son software libre: pueden viajar dentro de la imagen, y
  # asi es como se distribuye. Se instalan con el mismo instalador para no
  # duplicar su logica (OBS necesita quitar el plugin de navegador, cuyo CEF es
  # x86-only; Pinta necesita el .NET arm64 de Microsoft, que Arch no empaqueta).
  # Es lo mas caro del build: ~45 min. HACER_LIBRES=no lo omite.
  if [ "${HACER_LIBRES:-si}" = "si" ]; then
    log "$(msg stage3_free_apps)"
    if /usr/local/bin/omarchy-arm-extras pinta obs; then
      echo "  pinta: $(pacman -Q pinta 2>/dev/null || msg stage3_missing)"
      echo "  obs:   $(pacman -Q obs-studio 2>/dev/null || msg stage3_missing)"
    else
      warn "$(msg stage3_free_apps_failed)"
      warn "  omarchy-arm-extras pinta obs"
    fi
  else
    echo "  $(msg stage3_free_apps_skipped)"
  fi
fi

# --- actualizaciones: que "Update System" funcione y sea reversible --------
# a) snapper: sin el, omarchy-snapshot devuelve 127 y cada actualizacion se hace
#    sin instantanea previa, es decir sin posibilidad de volver atras.
# b) hook post-update: omarchy-update-dev solo hace `git pull` cuando
#    OMARCHY_PATH apunta FUERA de /usr/share/omarchy, y aqui apunta justo ahi.
#    Sin el hook, el sistema recibe paquetes pero el arbol de Omarchy (scripts,
#    temas, configuracion) se queda congelado en la version clonada.
log "$(msg stage3_updates)"
sudo pacman -S --noconfirm --needed snapper >/dev/null 2>&1 || warn "$(msg stage3_snapper_missing)"
if command -v snapper >/dev/null 2>&1; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh" >/dev/null 2>&1 \
    && echo "  $(msg stage3_snapper_ready)" \
    || warn "$(msg stage3_snapper_failed)"
fi
if [ -f "$HOME/.omarchy-arm-prov/10-arm-sync" ]; then
  install -Dm755 "$HOME/.omarchy-arm-prov/10-arm-sync" ~/.config/omarchy/hooks/post-update.d/10-arm-sync
  echo "  $(msg stage3_hook_ready)"
fi

log "git"
git config --global user.name  "$VM_FULLNAME"
git config --global user.email "$VM_EMAIL"
git config --global init.defaultBranch master

# ------------------------------------------------------------ resumen
log "$(msg stage3_summary)"
echo "  omarchy:   $(ls -d "$OMARCHY_PATH" 2>/dev/null || msg stage3_missing)"
echo "  ~/.config: $(ls ~/.config | wc -l) $(msg stage3_entries)"
echo "  tema:      $(readlink -f ~/.config/omarchy/current/theme 2>/dev/null || echo "$(msg stage3_unlinked)")"
echo "  hyprland:  $(command -v Hyprland || command -v hyprland || echo 'NO')"
echo "  omarchy-shell: $(command -v omarchy-shell || echo 'NO')"
echo "  terminal:  $(command -v xdg-terminal-exec || echo 'NO')"
echo ""
echo "==> [stage3] $(msg stage3_completed)"
__PAYLOAD_PROVISION_STAGE3_SH__
chmod +x "$W/provision/stage3.sh"

mkdir -p "$W/provision"
cat > "$W/provision/repair.sh" <<'__PAYLOAD_PROVISION_REPAIR_SH__'
#!/bin/sh
# Reabre el sistema ya instalado en /dev/vda y ejecuta un script dentro del chroot,
# sin volver a particionar ni descargar nada. Para iterar tras un fallo puntual.
set -eu
PROV=/media/prov
if ! type omarchy_msg >/dev/null 2>&1; then
  for _catalog in "${OMARCHY_CATALOG:-}" "$PROV/catalog.sh" /root/prov/catalog.sh /usr/local/share/omarchy/catalog.sh; do
    [ -n "$_catalog" ] && [ -f "$_catalog" ] && . "$_catalog" && break
  done
fi
msg() { if type omarchy_msg >/dev/null 2>&1; then omarchy_msg "$@"; else printf '%s' "$1"; fi; }
log() { echo ""; echo "==> [repair] $*"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_REPAIR_$rc"' EXIT

log "$(msg repair_kernel_modules)"
# Montar btrfs/vfat solo necesita el modulo del kernel, no las utilidades de
# espacio de usuario: esta etapa NO depende de que haya red.
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
grep -qw btrfs /proc/filesystems || { echo "!! $(msg repair_btrfs_missing)"; exit 1; }
echo "  $(msg repair_filesystems): $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "$(msg repair_network)"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 8 >/dev/null 2>&1 || true
ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' || echo "  ($(msg repair_no_network))"

log "$(msg repair_mount)"
umount -R /mnt 2>/dev/null || true
if mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@ /dev/vda2 /mnt 2>/dev/null; then
  mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@home /dev/vda2 /mnt/home
else
  mount -t ext4 /dev/vda2 /mnt
fi
mount -t vfat /dev/vda1 /mnt/boot
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf
df -h /mnt /mnt/boot

log "$(msg repair_run_fix "$FIXSCRIPT")"
mkdir -p /mnt/root/prov
cp "$PROV/$FIXSCRIPT" /mnt/root/prov/
[ -f "$PROV/config.env" ] && cp "$PROV/config.env" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/fsinfo.env" ] && cp "$PROV/fsinfo.env" /mnt/root/prov/
[ -f "$PROV/catalog.sh" ] && {
  cp "$PROV/catalog.sh" /mnt/root/prov/catalog.sh
  mkdir -p /mnt/usr/local/share/omarchy
  cp "$PROV/catalog.sh" /mnt/usr/local/share/omarchy/catalog.sh
}
[ -f "$PROV/stage3.sh" ] && cp "$PROV/stage3.sh" /mnt/root/prov/
[ -f "$PROV/packages-core.txt" ] && cp "$PROV/packages-core.txt" /mnt/root/prov/
[ -f "$PROV/packages-extra.txt" ] && cp "$PROV/packages-extra.txt" /mnt/root/prov/
chmod +x /mnt/root/prov/*.sh
set +e
chroot /mnt /bin/bash "/root/prov/$FIXSCRIPT"
rc=$?
set -e

# El directorio de trabajo no debe quedarse dentro del sistema: se acumulan ahi
# todos los scripts de reparacion de todas las pasadas.
log "$(msg repair_remove_payload)"
ls /mnt/root/prov 2>/dev/null | tr '\n' ' '; echo
rm -rf /mnt/root/prov

log "$(msg repair_unmount)"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "TOK_REPAIR_$rc"
trap - EXIT
exit $rc
__PAYLOAD_PROVISION_REPAIR_SH__
chmod +x "$W/provision/repair.sh"

mkdir -p "$W/provision"
cat > "$W/provision/sanitize.sh" <<'__PAYLOAD_PROVISION_SANITIZE_SH__'
#!/bin/bash
# Sanitizado para distribucion: quita todo lo identificativo del sistema y deja
# un usuario generico. Se ejecuta como ROOT dentro del chroot.
set -uo pipefail
# config.env lo deja stage1 dentro del invitado: es la unica via por la que el
# anfitrion puede comunicar el usuario de construccion. Sin esto, cambiar
# VM_USER hacia que el sanitizado renombrase a un usuario que no existe.
[ -f /root/prov/config.env ] && . /root/prov/config.env
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
OLD="${DIST_OLD_USER:-${VM_USER:-}}"
NEW="${DIST_NEW_USER:-omarchy}"
[ -n "$OLD" ] || { echo "sanitize: $(msg sanitize_source_user_missing)" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "sanitize: $(msg sanitize_user_missing "$OLD")" >&2; exit 1; }
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "$(msg sanitize_step1)"
# Era un symlink a /home/<usuario>/.local/share/omarchy, lo que ata el sistema a
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
# Retirar /opt/1Password deja sus enlaces de /usr/bin apuntando al vacio. Es el
# mismo descuido de siempre: un barrido de texto no ve el destino de un enlace.
for l in $(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null); do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  $(msg sanitize_broken_link_removed "$l")" ;;
  esac
done
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

log "$(msg sanitize_step7c)"
# Compilar las herramientas deja detras cadenas de compilacion enteras (el SDK
# de .NET son 425 MiB) y toolchains de Rust y Go en el home. Nada de eso hace
# falta para usar la imagen, y se lleva ~2 GB del zip.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  quitado $p"; }
done
# Omarchy 4 jubila estos cuatro: quickshell es la barra, el menu, el OSD y el
# demonio de notificaciones. mako ademas roba org.freedesktop.Notifications por
# activacion D-Bus y deja las notificaciones sin tema. No deberian estar
# instalados, pero si una version futura de la lista los reintroduce, fuera.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  jubilado $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  huerfanos: $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  $(msg sanitize_required): $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo "$(msg sanitize_missing_pkg "$p")")"; done)"

log "$(msg sanitize_step7d)"
# Medido en una imagen real: 675 MiB de firmware para hardware que en una VM
# QEMU con dispositivos virtio no puede existir. linux-firmware no se instala a
# proposito, pero los splits por fabricante entran como dependencias.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  firmware de hardware ausente: $FW"
  # -Rdd: los splits los reclama el metapaquete linux-firmware, que tampoco
  # hace falta. Si algo se opone, se deja como esta y no se rompe nada.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  $(msg sanitize_removed)" || echo "  $(msg sanitize_remove_failed)"
fi
# Documentacion y manuales: 469 MiB. Es una imagen para probar un escritorio,
# no un servidor donde vayas a leer man. Los .md de Omarchy NO se tocan.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  $(msg sanitize_usage_after_trim): $(df -h / | awk 'NR==2{print $3}')"

log "$(msg sanitize_step7)"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
# OJO: /root/prov NO se borra aqui. Los pasos 8a y 8b leen de ahi el hook de
# actualizacion y el instalador de apps opcionales; borrarlo antes dejaba la
# imagen sin ninguno de los dos, en silencio. Lo retira repair.sh al salir del
# chroot, que es donde corresponde.
rm -rf /root/.bash_history /root/.cache 2>/dev/null || true
rm -f /root/STAGE2_OK 2>/dev/null || true
# La fase verify arranca la VM antes de sanitizar, y ese arranque deja semilla
# de aleatoriedad y secreto de credenciales: identicos en todas las copias.
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret 2>/dev/null || true
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true
: > /var/log/lastlog 2>/dev/null || true

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
echo "  $(msg sanitize_broken_usr_bin): $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  $(msg sanitize_omarchy_path):"; ls -ld /usr/share/omarchy

log "$(msg sanitize_consistency)"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  symlink omarchy: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  $(msg sanitize_binaries): $(ls /usr/bin | grep -c '^omarchy-') $(msg sanitize_in_usr_bin)"
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
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l \
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
echo "  $(msg sanitize_links_old "$OLD"): $(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  $(msg sanitize_broken_home): $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  $(msg sanitize_broken_usr_bin): $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  $(msg sanitize_active_background): $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo "$(msg sanitize_none_upper)")"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  $(msg sanitize_background_resolves): $(msg sanitize_ok)" || echo "  $(msg sanitize_background_resolves): $(msg sanitize_broken)"
echo "  ($(msg sanitize_ttfx_note))"

log "$(msg sanitize_distribution_state)"
echo "  $(msg sanitize_user_label): $(getent passwd $NEW | cut -d: -f1,5,6)"
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
__PAYLOAD_PROVISION_SANITIZE_SH__
chmod +x "$W/provision/sanitize.sh"

mkdir -p "$W/provision"
cat > "$W/provision/extras.sh" <<'__PAYLOAD_PROVISION_EXTRAS_SH__'
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
__PAYLOAD_PROVISION_EXTRAS_SH__
chmod +x "$W/provision/extras.sh"

mkdir -p "$W/provision"
cat > "$W/provision/armsync.sh" <<'__PAYLOAD_PROVISION_ARMSYNC_SH__'
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
  b=$(basename "$f"); t="/usr/bin/$b"
  [ -e "$t" ] && [ ! -L "$t" ] && continue
  [ -L "$t" ] && continue
  # A /usr/share/omarchy, no a $TREE: esa ruta sobrevive al renombrado del
  # usuario que hace el sanitizador (ver stage3).
  sudo ln -sfn "/usr/share/omarchy/bin/$b" "$t" 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && echo "  $(msg armsync_linked "$n")"
# Enlaces que apuntan a comandos ya retirados del arbol
sudo find /usr/bin -xtype l -delete 2>/dev/null || true
exit 0
__PAYLOAD_PROVISION_ARMSYNC_SH__
chmod +x "$W/provision/armsync.sh"

cat > "$W/provision/clipbrd.sh" <<'__PAYLOAD_PROVISION_CLIPBRD_SH__'
#!/bin/bash
#
#  omarchy-arm-clipboard — portapapeles compartido con el Mac, vía la carpeta
#  compartida de UTM.
#
#  POR QUE HACE FALTA
#  UTM ofrece "Compartir portapapeles", pero eso solo funciona si el invitado
#  corre spice-vdagent, y el portapapeles de spice-vdagent es X11 puro: su
#  clipboard.c delega todo en vdagent_x11_* y no hay una sola referencia a
#  wlr-data-control en su codigo. Bajo Hyprland (Wayland nativo) no puede
#  funcionar, por mucho que el servicio arranque.
#
#  COMO FUNCIONA
#  Vigila /mnt/share/.clipboard en las dos direcciones: si el fichero cambia,
#  lo copia al portapapeles del invitado; si el portapapeles del invitado
#  cambia, lo escribe al fichero. En el Mac, un script equivalente hace lo
#  mismo con pbcopy/pbpaste. Solo texto.
#
#  USO
#    omarchy-arm-clipboard             vigila (lo lanza el servicio de usuario)
#    omarchy-arm-clipboard --install   instala el servicio y lo arranca
#    omarchy-arm-clipboard --host      imprime el script para el Mac
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

SHARE="${OMARCHY_CLIPBOARD_DIR:-/mnt/share}"
FILE="$SHARE/.clipboard"
INTERVALO="${OMARCHY_CLIPBOARD_INTERVAL:-1}"

uso() {
  cat <<EOF
$(msg clipboard_help_title)

  omarchy-arm-clipboard             $(msg clipboard_help_watch)
  omarchy-arm-clipboard --install   $(msg clipboard_help_install)
  omarchy-arm-clipboard --host      $(msg clipboard_help_host)
EOF
}

instalar() {
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-clipboard.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (via carpeta compartida de UTM)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStart=/usr/local/bin/omarchy-arm-clipboard
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now omarchy-arm-clipboard.service && echo "$(msg clipboard_service_active)"
  systemctl --user --no-pager status omarchy-arm-clipboard.service | head -5
}

script_anfitrion() {
  cat <<'MACEOF'
#!/bin/bash
# Ejecutar EN EL MAC. Sincroniza el portapapeles con la VM a traves de la
# carpeta que tengas compartida en los ajustes de la VM en UTM.
#   ./clipboard-mac.sh ~/ruta/de/la/carpeta/compartida
set -uo pipefail
  DIR="${1:?usage: $0 <shared folder with the VM>}"
F="$DIR/.clipboard"
mkdir -p "$DIR"; touch "$F"
ultimo_local=""; ultimo_remoto="$(cat "$F" 2>/dev/null || true)"
while :; do
  actual="$(pbpaste 2>/dev/null || true)"
  if [ "$actual" != "$ultimo_local" ] && [ -n "$actual" ]; then
    printf '%s' "$actual" > "$F"; ultimo_local="$actual"; ultimo_remoto="$actual"
  fi
  remoto="$(cat "$F" 2>/dev/null || true)"
  if [ "$remoto" != "$ultimo_remoto" ] && [ -n "$remoto" ]; then
    printf '%s' "$remoto" | pbcopy; ultimo_remoto="$remoto"; ultimo_local="$remoto"
  fi
  sleep 1
done
MACEOF
}

vigilar() {
  command -v wl-paste >/dev/null || { echo "$(msg clipboard_missing_package)" >&2; exit 1; }
  if [ ! -d "$SHARE" ]; then
    echo "$(msg clipboard_share_missing "$SHARE")" >&2
    echo "$(msg clipboard_share_setup)" >&2
    exit 1
  fi
  touch "$FILE" 2>/dev/null || { echo "$(msg clipboard_write_failed "$FILE")" >&2; exit 1; }
  local ultimo_local ultimo_remoto actual remoto
  ultimo_local="$(wl-paste --no-newline 2>/dev/null || true)"
  ultimo_remoto="$(cat "$FILE" 2>/dev/null || true)"
  while :; do
    # invitado -> fichero
    actual="$(wl-paste --no-newline 2>/dev/null || true)"
    if [ "$actual" != "$ultimo_local" ] && [ -n "$actual" ]; then
      printf '%s' "$actual" > "$FILE"
      ultimo_local="$actual"; ultimo_remoto="$actual"
    fi
    # fichero -> invitado
    remoto="$(cat "$FILE" 2>/dev/null || true)"
    if [ "$remoto" != "$ultimo_remoto" ] && [ -n "$remoto" ]; then
      printf '%s' "$remoto" | wl-copy
      ultimo_remoto="$remoto"; ultimo_local="$remoto"
    fi
    sleep "$INTERVALO"
  done
}

case "${1:-}" in
  --install) instalar ;;
  --host)    script_anfitrion ;;
  -h|--help) uso ;;
  "")        vigilar ;;
  *)         echo "$(msg clipboard_unknown_option "$1")" >&2; uso >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_CLIPBRD_SH__
chmod +x "$W/provision/clipbrd.sh"

cat > "$W/provision/vdagent.py" <<'__PAYLOAD_PROVISION_VDAGENT_PY__'
#!/usr/bin/env python3
"""
omarchy-arm-vdagent — portapapeles compartido real entre el anfitrión y Hyprland.

POR QUÉ EXISTE
    UTM ofrece "Compartir portapapeles" y expone el canal correcto:
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
        -chardev spicevmc,id=vdagent,debug=0,name=vdagent
    (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1201)

    Lo que no sirve es el agente de referencia. spice-vdagent habla ese canal
    pero entrega el portapapeles solo a X11: vdagent.c:421 hace
        vdagent_clipboards_new(vdagent_display_get_x11(agent->display))
    y en todo su repositorio no hay una sola referencia a wlr-data-control.
    Bajo Wayland nativo no tiene con quién hablar.

    Este agente habla el mismo protocolo por el mismo puerto, pero al otro lado
    usa wl-copy/wl-paste, que sí funcionan en Hyprland.

PROTOCOLO (spice-protocol, spice/vd_agent.h)
    Cada mensaje va precedido de VDIChunkHeader {port:u32, size:u32} y luego
    VDAgentMessage {protocol:u32=1, type:u32, opaque:u64, size:u32}.
    Solo texto UTF-8; ni imágenes ni ficheros.
"""
import os, sys, struct, subprocess, threading, time, select, signal

_lang = os.environ.get("OMARCHY_LANG")
if _lang is None:
    try:
        with open("/etc/omarchy-arm-language", encoding="utf-8") as _f:
            _lang = _f.read().strip()
    except OSError:
        _lang = None
_LANG = "es" if _lang == "es" else "en"
_MESSAGES = {
    "missing_port": {
        "en": "{port} does not exist.",
        "es": "no existe {port}.",
    },
    "clipboard_setup": {
        "en": "In UTM: VM Settings → Sharing → enable 'Share Clipboard'.",
        "es": "En UTM: Ajustes de la VM → Compartir → activa 'Compartir portapapeles'.",
    },
    "missing_command": {
        "en": "missing {cmd} (wl-clipboard package)",
        "es": "falta {cmd} (paquete wl-clipboard)",
    },
    "port_closed": {
        "en": "port closed: {error}",
        "es": "puerto cerrado: {error}",
    },
    "capabilities": {
        "en": "client capabilities: selection = {value}",
        "es": "capacidades del cliente: selección = {value}",
    },
    "clipboard_received": {
        "en": "received from host: {size} bytes",
        "es": "recibido del anfitrión: {size} bytes",
    },
    "wl_copy_failed": {
        "en": "wl-copy failed: {error}",
        "es": "wl-copy falló: {error}",
    },
}

def msg(key, **values):
    return _MESSAGES[key][_LANG].format(**values)

PUERTO = os.environ.get("VDAGENT_PORT", "/dev/virtio-ports/com.redhat.spice.0")

VD_AGENT_PROTOCOL = 1
VDP_CLIENT_PORT = 2                # el puerto del cliente, en VDIChunkHeader

MSG_CLIPBOARD              = 4
MSG_ANNOUNCE_CAPABILITIES  = 6
MSG_CLIPBOARD_GRAB         = 7
MSG_CLIPBOARD_REQUEST      = 8
MSG_CLIPBOARD_RELEASE      = 9

CAP_CLIPBOARD            = 3
CAP_CLIPBOARD_BY_DEMAND  = 5
CAP_CLIPBOARD_SELECTION  = 6

TIPO_UTF8 = 1                      # VD_AGENT_CLIPBOARD_UTF8_TEXT
SEL_CLIPBOARD = 0                  # VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD

DEBUG = bool(os.environ.get("VDAGENT_DEBUG"))

def log(*a):
    if DEBUG:
        print("[vdagent]", *a, file=sys.stderr, flush=True)


class Agente:
    def __init__(self, fd):
        self.fd = fd
        self.lock = threading.Lock()
        self.usa_seleccion = False       # ¿el cliente negoció CAP_CLIPBOARD_SELECTION?
        self.ultimo_local = None         # lo último que vimos en el portapapeles del invitado
        self.pendiente = None            # texto que el anfitrión nos anunció y aún no pedimos
        self.entrante = threading.Event()
        self.dato_entrante = None

    # ── escritura ────────────────────────────────────────────────────────
    def enviar(self, tipo, payload=b""):
        cuerpo = struct.pack("<IIQI", VD_AGENT_PROTOCOL, tipo, 0, len(payload)) + payload
        marco = struct.pack("<II", VDP_CLIENT_PORT, len(cuerpo)) + cuerpo
        with self.lock:
            os.write(self.fd, marco)
        log("→", tipo, len(payload))

    def _sel(self):
        """Prefijo de selección: solo si el cliente lo negoció."""
        return struct.pack("<BBBB", SEL_CLIPBOARD, 0, 0, 0) if self.usa_seleccion else b""

    def anunciar_capacidades(self, solicitar=1):
        caps = 0
        for c in (CAP_CLIPBOARD, CAP_CLIPBOARD_BY_DEMAND, CAP_CLIPBOARD_SELECTION):
            caps |= 1 << c
        self.enviar(MSG_ANNOUNCE_CAPABILITIES, struct.pack("<II", solicitar, caps))

    def grab(self):
        """Avisa al anfitrión de que tenemos algo nuevo que ofrecer."""
        self.enviar(MSG_CLIPBOARD_GRAB, self._sel() + struct.pack("<I", TIPO_UTF8))

    def pedir(self):
        self.enviar(MSG_CLIPBOARD_REQUEST, self._sel() + struct.pack("<I", TIPO_UTF8))

    def entregar(self, texto):
        self.enviar(MSG_CLIPBOARD,
                    self._sel() + struct.pack("<I", TIPO_UTF8) + texto.encode("utf-8"))

    # ── lectura ──────────────────────────────────────────────────────────
    def _leer_exacto(self, n):
        buf = b""
        while len(buf) < n:
            trozo = os.read(self.fd, n - len(buf))
            if not trozo:
                raise EOFError
            buf += trozo
        return buf

    def bucle_lectura(self):
        while True:
            try:
                _puerto, tam = struct.unpack("<II", self._leer_exacto(8))
                cuerpo = self._leer_exacto(tam)
            except (EOFError, OSError) as e:
                log(msg("port_closed", error=e)); return
            if len(cuerpo) < 20:
                continue
            proto, tipo, _opaque, tam_datos = struct.unpack("<IIQI", cuerpo[:20])
            if proto != VD_AGENT_PROTOCOL:
                continue
            datos = cuerpo[20:20 + tam_datos]
            log("←", tipo, tam_datos)
            self._despachar(tipo, datos)

    def _despachar(self, tipo, datos):
        if tipo == MSG_ANNOUNCE_CAPABILITIES:
            if len(datos) >= 8:
                solicitar, caps = struct.unpack("<II", datos[:8])
                self.usa_seleccion = bool(caps & (1 << CAP_CLIPBOARD_SELECTION))
                log(msg("capabilities", value=self.usa_seleccion))
                if solicitar:
                    self.anunciar_capacidades(solicitar=0)

        elif tipo == MSG_CLIPBOARD_GRAB:
            # El anfitrión copió algo. Se lo pedimos.
            self.pedir()

        elif tipo == MSG_CLIPBOARD_REQUEST:
            # El anfitrión quiere lo nuestro.
            texto = leer_portapapeles()
            self.entregar(texto if texto is not None else "")

        elif tipo == MSG_CLIPBOARD:
            d = datos[4:] if self.usa_seleccion else datos
            if len(d) >= 4:
                dtipo, = struct.unpack("<I", d[:4])
                if dtipo == TIPO_UTF8:
                    texto = d[4:].decode("utf-8", "replace")
                    escribir_portapapeles(texto)
                    self.ultimo_local = texto
                    log(msg("clipboard_received", size=len(texto)))

        elif tipo == MSG_CLIPBOARD_RELEASE:
            pass


def leer_portapapeles():
    try:
        r = subprocess.run(["wl-paste", "--no-newline", "--type", "text/plain"],
                           capture_output=True, timeout=5)
        if r.returncode != 0:
            return None
        return r.stdout.decode("utf-8", "replace")
    except Exception:
        return None


def escribir_portapapeles(texto):
    try:
        subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"],
                       input=texto.encode("utf-8"), timeout=5)
    except Exception as e:
        log(msg("wl_copy_failed", error=e))


def vigilar_invitado(ag):
    """Cuando el usuario copia dentro de la VM, avisamos al anfitrión."""
    while True:
        texto = leer_portapapeles()
        if texto is not None and texto != ag.ultimo_local:
            ag.ultimo_local = texto
            if texto:
                ag.grab()
        time.sleep(1)


def main():
    if not os.path.exists(PUERTO):
        print(msg("missing_port", port=PUERTO), file=sys.stderr)
        print(msg("clipboard_setup"), file=sys.stderr)
        return 1
    for cmd in ("wl-paste", "wl-copy"):
        if subprocess.run(["sh", "-c", f"command -v {cmd}"],
                          capture_output=True).returncode != 0:
            print(msg("missing_command", cmd=cmd), file=sys.stderr)
            return 1

    fd = os.open(PUERTO, os.O_RDWR)
    ag = Agente(fd)
    ag.anunciar_capacidades(solicitar=1)
    ag.ultimo_local = leer_portapapeles()

    threading.Thread(target=vigilar_invitado, args=(ag,), daemon=True).start()
    try:
        ag.bucle_lectura()
    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    sys.exit(main())
__PAYLOAD_PROVISION_VDAGENT_PY__
chmod +x "$W/provision/vdagent.py"

mkdir -p "$W/scripts"
cat > "$W/scripts/build.exp" <<'__PAYLOAD_SCRIPTS_BUILD_EXP__'
#!/usr/bin/expect -f
# Conduce la construcción por consola serie del live de Alpine.
set timeout 900
log_user 1
match_max 400000
set lang "en"
if {[info exists ::env(OMARCHY_LANG)] && $::env(OMARCHY_LANG) eq "es"} { set lang "es" }

proc msg {key args} {
    global lang
    set id "$lang:$key"
    switch -- $id {
        en:build_login { set text "the Alpine live did not reach the login" }
        es:build_login { set text "el live de Alpine no llegó al login" }
        en:build_shell { set text "no Alpine root shell" }
        es:build_shell { set text "no hay shell de root en Alpine" }
        en:build_prompt { set text "could not set the prompt" }
        es:build_prompt { set text "no se pudo fijar el prompt" }
        en:build_iso { set text "provisioning ISO not found" }
        es:build_iso { set text "no se encontró el ISO de aprovisionamiento" }
        en:build_rootfs { set text "Arch Linux ARM rootfs missing from the ISO" }
        es:build_rootfs { set text "falta el rootfs de Arch Linux ARM en el ISO" }
        en:build_tail { set text "tail" }
        es:build_tail { set text "tail" }
        en:build_success { set text "   BUILD COMPLETED" }
        es:build_success { set text "   CONSTRUCCION COMPLETADA" }
        en:build_failed { set text "!!!!!! BUILD FAILED !!!!!!" }
        es:build_failed { set text "!!!!!! LA CONSTRUCCION FALLO !!!!!!" }
        en:build_eof { set text "EOF during build" }
        es:build_eof { set text "EOF durante la construcción" }
        en:verify { set text "verification" }
        es:verify { set text "verificación" }
        en:verify_heading { set text "==== VERIFICATION ====" }
        es:verify_heading { set text "==== VERIFICACION ====" }
        en:verify_esp { set text "-- ESP --" }
        es:verify_esp { set text "-- ESP --" }
        en:verify_kernel { set text "-- kernel --" }
        es:verify_kernel { set text "-- kernel --" }
        en:verify_user { set text "-- user --" }
        es:verify_user { set text "-- usuario --" }
        en:verify_dotfiles { set text "-- dotfiles --" }
        es:verify_dotfiles { set text "-- dotfiles --" }
        en:verify_hyprland { set text "-- Hyprland --" }
        es:verify_hyprland { set text "-- hyprland --" }
        en:build_shutdown { set text "===== BUILD VM SHUT DOWN =====" }
        es:build_shutdown { set text "===== VM DE CONSTRUCCION APAGADA =====" }
        default { set text $key }
    }
    if {[llength $args] == 0} { return $text }
    return [format $text {*}$args]
}

proc die {code detail} { puts "\n!! $detail"; exit $code }
proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect {
        -ex $pat {}
        timeout  { die $code "TIMEOUT: $msg" }
        eof      { die [expr {$code+40}] "EOF: $msg" }
    }
}

# write_payloads sustituye @OMARM_ROOT@ al desplegar este fichero. Si el
# marcador sigue ahi es que se esta ejecutando desde un clon del repositorio:
# entonces la raiz viene de OMARM_ROOT o del directorio actual.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh

# --- login del live de Alpine (root sin contraseña)
wait_for "localhost login:" 10 [msg build_login] 300
send "root\r"
wait_for "localhost:~#" 11 [msg build_shell] 120

send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 [msg build_prompt] 60

# --- localizar y montar el ISO de aprovisionamiento
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/stage1.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 [msg build_iso] 120

send "test -s /media/prov/alarm-rootfs.tgz; echo TOK_TGZ_\$?\r"
wait_for "TOK_TGZ_0" 14 [msg build_rootfs] 60

# --- construcción completa (particionado + chroot + paquetes + dotfiles)
set timeout -1
# stage1.sh emite el token TOK_BUILD_<rc> por si mismo (un pipe a tee
# enmascararia el codigo de retorno).
send "export OMARCHY_LANG=$lang; export DISK=/dev/vda; sh /media/prov/stage1.sh 2>&1 | tee /tmp/build.log\r"

expect {
    -ex "TOK_BUILD_0" {
        puts "\n\n==========================================="
        puts [msg build_success]
        puts "===========================================\n"
    }
    -re {TOK_BUILD_[1-9][0-9]*} {
        puts "\n\n[msg build_failed]\n"
        set timeout 300
        send "echo; echo ---- ultimas 80 lineas ----; tail -n 80 /tmp/build.log; echo TOK_TAIL_\$?\r"
        catch { wait_for "TOK_TAIL_" 15 [msg build_tail] 300 }
        exit 20
    }
    eof { die 16 [msg build_eof] }
}

# --- verificación del disco resultante
set timeout 600
send "mount -o subvol=@ /dev/vda2 /mnt 2>/dev/null || mount /dev/vda2 /mnt; mount /dev/vda1 /mnt/boot 2>/dev/null; echo '[msg verify_heading]'; echo '[msg verify_esp]'; find /mnt/boot -maxdepth 3 | head -40; echo '[msg verify_kernel]'; ls -la /mnt/boot/Image* /mnt/boot/initramfs* 2>/dev/null; echo '[msg verify_user]'; ls -la /mnt/home/; echo '[msg verify_dotfiles]'; ls /mnt/home/gabriel/.config 2>/dev/null | tr '\\n' ' '; echo; echo '[msg verify_hyprland]'; ls -la /mnt/usr/bin/Hyprland 2>/dev/null; echo TOK_VERIFY_\$?\r"
catch { wait_for "TOK_VERIFY_" 17 [msg verify] 600 }

send "sync; umount -R /mnt 2>/dev/null; poweroff -f\r"
expect eof
puts "\n[msg build_shutdown]"
exit 0
__PAYLOAD_SCRIPTS_BUILD_EXP__
chmod +x "$W/scripts/build.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/repair.exp" <<'__PAYLOAD_SCRIPTS_REPAIR_EXP__'
#!/usr/bin/expect -f
# Uso: scripts/repair.exp <script-dentro-del-ISO.sh>
# Arranca Alpine con el disco YA instalado y ejecuta ese script en el chroot.
set timeout 900
log_user 1
match_max 400000
set FIX [lindex $argv 0]
set lang "en"
if {[info exists ::env(OMARCHY_LANG)] && $::env(OMARCHY_LANG) eq "es"} { set lang "es" }

proc msg {key args} {
    global lang
    set id "$lang:$key"
    switch -- $id {
        en:usage { set text "Usage: repair.exp <fix.sh>" }
        es:usage { set text "Uso: repair.exp <fix.sh>" }
        en:login { set text "Alpine login" }
        es:login { set text "login de Alpine" }
        en:shell { set text "root shell" }
        es:shell { set text "shell de root" }
        en:prompt { set text "prompt" }
        es:prompt { set text "prompt" }
        en:iso { set text "provisioning ISO" }
        es:iso { set text "ISO de aprovisionamiento" }
        en:success { set text "===== REPAIR COMPLETED =====" }
        es:success { set text "===== REPARACION COMPLETADA =====" }
        en:failed { set text "!!!!! REPAIR FAILED !!!!!" }
        es:failed { set text "!!!!! LA REPARACION FALLO !!!!!" }
        en:eof { set text "EOF" }
        es:eof { set text "EOF" }
        default { set text $key }
    }
    if {[llength $args] == 0} { return $text }
    return [format $text {*}$args]
}

if {$FIX eq ""} { puts [msg usage]; exit 1 }

proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect { -ex $pat {} timeout { puts "\n!! TIMEOUT: $msg"; exit $code }
             eof { puts "\n!! EOF: $msg"; exit [expr {$code+40}] } }
}
# write_payloads sustituye @OMARM_ROOT@ al desplegar este fichero. Si el
# marcador sigue ahi es que se esta ejecutando desde un clon del repositorio:
# entonces la raiz viene de OMARM_ROOT o del directorio actual.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh
wait_for "localhost login:" 10 [msg login] 300
send "root\r"
wait_for "localhost:~#" 11 [msg shell] 120
send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 [msg prompt] 60
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/repair.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 [msg iso] 120

set timeout -1
send "export OMARCHY_LANG=$lang; export FIXSCRIPT=$FIX; sh /media/prov/repair.sh 2>&1 | tee /tmp/repair.log\r"
expect {
    -ex "TOK_REPAIR_0" { puts "\n\n[msg success]\n" }
    -re {TOK_REPAIR_[1-9][0-9]*} { puts "\n\n[msg failed]\n"; exit 20 }
    eof { puts "\n!! [msg eof]"; exit 16 }
}
set timeout 300
send "sync; poweroff -f\r"
expect eof
exit 0
__PAYLOAD_SCRIPTS_REPAIR_EXP__
chmod +x "$W/scripts/repair.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/qemu.sh" <<'__PAYLOAD_SCRIPTS_QEMU_SH__'
#!/bin/bash
# VM de construcción: aarch64 NATIVO con HVF (sin emulación) sobre Apple Silicon.
# Live de Alpine por consola serie + ISO de aprovisionamiento con el rootfs de ALARM.
set -e
# La raiz se deduce de la ubicacion del propio script: asi el repo se puede
# clonar en cualquier sitio sin editar nada.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${VM_SMP:=8}"
: "${VM_MEM:=8192}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
: "${PROV_ISO:=provision/provision.iso}"
: "${DISK_IMG:=vm/omarchy-arm.qcow2}"

[ -f vm/efi-vars.fd ] || dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

exec qemu-system-aarch64 \
  -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
  -M virt,highmem=on,gic-version=3 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,unit=1,file=vm/efi-vars.fd \
  -drive if=none,id=hd,file="$DISK_IMG",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=hd \
  -drive if=none,id=live,file=dl/alpine-virt-aarch64.iso,format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=live,bootindex=0 \
  -drive if=none,id=prov,file="$PROV_ISO",format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=prov \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -nographic
__PAYLOAD_SCRIPTS_QEMU_SH__
chmod +x "$W/scripts/qemu.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/make-utm.sh" <<'__PAYLOAD_SCRIPTS_MAKE-UTM_SH__'
#!/bin/bash
# Crea el bundle .utm a mano y lo registra en UTM.
#
# UTM 4.7 sólo escanea ~/Library/Containers/com.utmapp.UTM/Data/Documents/ una
# vez, al arrancar la app (listRefresh() se llama desde ContentView.onAppear),
# así que hay que cerrar UTM, escribir el bundle y volver a abrirlo.
# El config.plist requiere las DIEZ claves de primer nivel: se decodifican con
# decode(), no decodeIfPresent(), y omitir cualquiera hace que UTM lo rechace.
set -euo pipefail

# La raiz se deduce de la ubicacion del propio script: asi el repo se puede
# clonar en cualquier sitio sin editar nada.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

if ! type omarchy_msg >/dev/null 2>&1; then
  [ -f "${OMARCHY_CATALOG:-$ROOT/localization/catalog.sh}" ] && . "${OMARCHY_CATALOG:-$ROOT/localization/catalog.sh}"
fi
msg() { omarchy_msg "$@"; }
NAME="${1:-Omarchy ARM}"
: "${DEST_DIR:=$DOCS}"
BUNDLE="$DEST_DIR/$NAME.utm"
: "${SRC_QCOW:=$ROOT/vm/omarchy-arm.qcow2}"
VARS_TPL=/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd
: "${UTM_CPUS:=8}"
: "${UTM_MEM:=8192}"

[ -f "$SRC_QCOW" ] || { printf '!! %s\n' "$(msg utm_missing_disk "$SRC_QCOW")"; exit 1; }
[ -f "$VARS_TPL" ] || { printf '!! %s\n' "$(msg utm_missing_vars "$VARS_TPL")"; exit 1; }

VM_UUID=$(uuidgen)
# Quien reciba el bundle lee estas notas en UTM antes de arrancar: tienen que
# decir las credenciales reales, no las del que lo construyo.
NOTES_USER="${NOTES_USER:-omarchy}"
NOTES_PASS="${NOTES_PASS:-$NOTES_USER}"

DISK_UUID=$(uuidgen)
MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# UTM solo escanea Documents al arrancar la app, asi que para que reconozca el
# bundle hay que reiniciarla. Pero cerrarla a la fuerza se lleva por delante las
# VMs que el usuario tenga corriendo, asi que primero se comprueba.
if [ "$DEST_DIR" = "$DOCS" ] && pgrep -x UTM >/dev/null; then
  UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
  CORRIENDO=$("$UTMCTL" list 2>/dev/null | awk '$2=="started"{print $3" "$4}' | grep -v "^$" || true)
  if [ -n "$CORRIENDO" ]; then
    echo "==> $(msg utm_running_vms)"
    echo "$CORRIENDO" | sed 's/^/      /'
    echo "    $(msg utm_restart_warning)"
    if [ -t 0 ] && [ "${ASSUME_YES:-}" != "1" ]; then
      printf '    %s [%s]: ' "$(msg utm_close_prompt)" "$(msg yesno_no)"
      read -r R </dev/tty || R=""
      case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]')" in
        s|si|sí|y|yes) : ;;
        *) echo "==> $(msg utm_manual_import)"; SKIP_RESTART=1 ;;
      esac
    else
      echo "==> $(msg utm_unattended)"
      SKIP_RESTART=1
    fi
  fi
  if [ "${SKIP_RESTART:-0}" != "1" ]; then
    echo "==> $(msg utm_closing)"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x UTM >/dev/null || break; sleep 1; done
    pgrep -x UTM >/dev/null && { pkill -x UTM || true; sleep 2; }
  fi
fi

echo "==> $(msg utm_creating) $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Data"
echo "    $(msg utm_copying) ($(du -h "$SRC_QCOW" | cut -f1))"
cp -c "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2" 2>/dev/null || cp "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2"
# La mitad VARS del UEFI aarch64 usa la plantilla edk2-ARM-vars.fd (no aarch64);
# UTM aporta edk2-aarch64-code.fd en tiempo de ejecución vía -L.
install -m 0644 "$VARS_TPL" "$BUNDLE/Data/efi_vars.fd"

cat > "$BUNDLE/config.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Information</key>
	<dict>
		<key>Name</key>
		<string>$NAME</string>
		<key>UUID</key>
		<string>$VM_UUID</string>
		<key>IconCustom</key>
		<false/>
		<key>Icon</key>
		<string>arch-linux</string>
		<key>Notes</key>
		<string>$(msg utm_notes "$NOTES_USER" "$NOTES_PASS")</string>
	</dict>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>Target</key>
		<string>virt</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>CPUCount</key>
		<integer>$UTM_CPUS</integer>
		<key>ForceMulticore</key>
		<false/>
		<key>MemorySize</key>
		<integer>$UTM_MEM</integer>
		<key>JITCacheSize</key>
		<integer>0</integer>
	</dict>
	<key>QEMU</key>
	<dict>
		<key>DebugLog</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
		<key>RNGDevice</key>
		<true/>
		<key>BalloonDevice</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>PS2Controller</key>
		<false/>
		<key>AdditionalArguments</key>
		<array/>
	</dict>
	<key>Input</key>
	<dict>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
	</dict>
	<key>Sharing</key>
	<dict>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
		<key>ClipboardSharing</key>
		<true/>
	</dict>
	<key>Display</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-gpu-gl-pci</string>
			<key>DynamicResolution</key>
			<true/>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
			<key>DownscalingFilter</key>
			<string>Linear</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>$DISK_UUID</string>
			<key>ImageName</key>
			<string>$DISK_UUID.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Network</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Shared</string>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>MacAddress</key>
			<string>$MAC</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>PortForward</key>
			<array/>
		</dict>
	</array>
	<key>Serial</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Ptty</string>
			<key>Target</key>
			<string>Auto</string>
		</dict>
	</array>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> $(msg utm_validate)"
plutil -lint "$BUNDLE/config.plist"
du -sh "$BUNDLE"
ls -la "$BUNDLE" "$BUNDLE/Data"

if [ "$DEST_DIR" = "$DOCS" ]; then
  echo "==> $(msg utm_opening)"
  open -a UTM
  sleep 6
  /Applications/UTM.app/Contents/MacOS/utmctl list || true
else
  echo "==> $(msg utm_not_registered)"
fi

echo ""
echo "$(msg utm_bundle):  $BUNDLE"
echo "$(msg utm_uuid):    $VM_UUID"
echo "$(msg utm_start): /Applications/UTM.app/Contents/MacOS/utmctl start \"$NAME\""
__PAYLOAD_SCRIPTS_MAKE-UTM_SH__
chmod +x "$W/scripts/make-utm.sh"
  # Todos los valores van entrecomillados: config.env se consume con "source" y
  # cualquiera puede llevar espacios (VM_FULLNAME es el caso obvio, pero tambien
  # una contrasena o un nombre de VM). Sin comillas, la segunda palabra se
  # ejecuta como comando y el chroot muere con 127.
  cat > "$W/provision/config.env" <<CFGEOF
# Payloads source the canonical catalog.sh emitted beside them.
OMARCHY_LANG="$OMARCHY_LANG"
VM_USER="$VM_USER"
VM_PASSWORD="$VM_PASSWORD"
VM_FULLNAME="$VM_FULLNAME"
VM_EMAIL="$VM_EMAIL"
VM_HOSTNAME="$VM_HOSTNAME"
VM_TIMEZONE="$VM_TIMEZONE"
VM_KEYMAP="$VM_KEYMAP"
VM_XKB="$VM_XKB"
VM_LOCALE="$VM_LOCALE"
VM_LOCALE_EXTRA="$VM_LOCALE_EXTRA"
DISK="/dev/vda"
OMARCHY_REF="$OMARCHY_REF"
DIST_OLD_USER="$VM_USER"
DIST_NEW_USER="$DIST_NEW_USER"
HACER_TOOLS="$HACER_TOOLS"
HACER_LIBRES="$HACER_LIBRES"
CFGEOF
  # Los arneses llevan la raiz como marcador @OMARM_ROOT@: se sustituye al
  # desplegarlos. Antes era la ruta literal del Mac donde se escribieron.
  sed -i '' "s#@OMARM_ROOT@#$W#g" \
    "$W/scripts/build.exp" "$W/scripts/repair.exp" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
  sed -i '' "s#scripts/qemu-build.sh#scripts/qemu.sh#g" "$W/scripts/build.exp" "$W/scripts/repair.exp" 2>/dev/null || true
  sed -i '' "s#^ROOT=.*#ROOT=$W#" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
}

make_iso() {  # make_iso <destino.iso> <fichero...>
  local out="$1"; shift
  local d; d=$(mktemp -d)
  cp "$@" "$d"/
  rm -f "$out"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$out" "$d" >/dev/null
  rm -rf "$d"
}

# ─────────────────────────────── fase: build ───────────────────────────────
ph_build() {
  phase "$(omarchy_msg phase_build)"
  write_payloads
  # Nombres cortos: hdiutil trunca los largos en el arbol ISO9660
  make_iso "$W/provision/provision.iso" \
    "$W/provision/stage1.sh" "$W/provision/stage2.sh" "$W/provision/stage3.sh" \
    "$W/provision/config.env" "$W/provision/catalog.sh" "$W/provision/packages-core.txt" "$W/provision/packages-extra.txt"
  ln -f "$W/dl/alarm-rootfs.tgz" /tmp/alarm-rootfs.tgz 2>/dev/null || true
  # el rootfs viaja dentro del ISO de aprovisionamiento
  local d; d=$(mktemp -d)
  cp "$W/provision"/{stage1.sh,stage2.sh,stage3.sh,config.env,catalog.sh,packages-core.txt,packages-extra.txt} "$d"/
  cp "$W/provision"/{extras.sh,armsync.sh,clipbrd.sh,vdagent.py} "$d"/
  ln "$W/dl/alarm-rootfs.tgz" "$d/alarm-rootfs.tgz" 2>/dev/null || cp "$W/dl/alarm-rootfs.tgz" "$d/"
  rm -f "$W/provision/provision.iso"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$W/provision/provision.iso" "$d" >/dev/null
  rm -rf "$d"
  ok "$(omarchy_msg build_iso_done "$(du -h "$W/provision/provision.iso" | cut -f1)")"

  # Reconstruir descarta el disco anterior, que son ~40 min de trabajo. Si hay
  # uno y la sesion es interactiva, se pregunta; si no, se conserva una copia.
  if [[ -s $W/vm/omarchy-arm.qcow2 ]]; then
    if confirm "$(omarchy_msg confirm_rebuild "$(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)")" no; then
      rm -f "$W/vm/omarchy-arm.qcow2"
    else
      mv "$W/vm/omarchy-arm.qcow2" "$W/vm/omarchy-arm.qcow2.anterior"
      info "$(omarchy_msg build_rebuild_previous "$W/vm/omarchy-arm.qcow2.anterior")"
    fi
  fi
  rm -f "$W/vm/efi-vars.fd"
  qemu-img create -f qcow2 "$W/vm/omarchy-arm.qcow2" "$DISK_SIZE" >/dev/null
  dd if=/dev/zero of="$W/vm/efi-vars.fd" bs=1m count=64 status=none

  info "$(omarchy_msg build_start)"
  info "$(omarchy_msg build_duration "$W/logs/build.log")"
  VM_SMP=$BUILD_SMP VM_MEM=$BUILD_MEM PROV_ISO="$W/provision/provision.iso" \
    expect -f "$W/scripts/build.exp" > "$W/logs/build.log" 2>&1
  local rc=$?
  # stage2 emite TOK_STAGE3_<rc>: sin comprobarlo, un stage3 que falla entero
  # (sin dotfiles, sin herramientas, sin tema) pasaba por construccion correcta.
  if grep -qa "TOK_STAGE3_" "$W/logs/build.log" && ! grep -qa "TOK_STAGE3_0" "$W/logs/build.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | grep -aE "^(!!|==>)" | tail -25
    die "$(omarchy_msg build_stage3_failed "$W/logs/build.log")"
  fi
  grep -qa "TOK_BUILD_0" "$W/logs/build.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | tail -40
    die "$(omarchy_msg build_failed_rc "$rc" "$W/logs/build.log")"
  }
  ok "$(omarchy_msg build_disk_done "$(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)")"
}

# ──────────────────────────────── fase: utm ────────────────────────────────
ph_utm() {
  phase "$(omarchy_msg phase_utm)"
  write_payloads
  [[ -s $W/vm/omarchy-arm.qcow2 ]] || die "$(omarchy_msg build_disk_missing)"
  # Borrar una VM homonima destruye su disco. Si ya existe una, se pregunta;
  # sin terminal se elige otro nombre en vez de destruir nada.
  if "$UTMCTL" list 2>/dev/null | grep -q "  $VM_NAME$"; then
    if confirm "$(omarchy_msg confirm_vm_delete "'$VM_NAME'")" no; then
      "$UTMCTL" delete "$VM_NAME" >/dev/null 2>&1 || true; sleep 2
    else
      VM_NAME="$VM_NAME $(date +%H%M)"
      info "$(omarchy_msg utm_registering "$VM_NAME")"
    fi
  fi
  local ulog="$W/logs/make-utm.log"
  if ! SRC_QCOW="$W/vm/omarchy-arm.qcow2" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM OMARCHY_LANG="$OMARCHY_LANG" OMARCHY_CATALOG="$W/provision/catalog.sh" \
       NOTES_USER="$VM_USER" NOTES_PASS="$VM_PASSWORD" ASSUME_YES="${ASSUME_YES:-}" \
       bash "$W/scripts/make-utm.sh" "$VM_NAME" > "$ulog" 2>&1; then
    tail -20 "$ulog"
    die "$(omarchy_msg utm_make_failed "$ulog")"
  fi
  tail -4 "$ulog"
  [[ -f "$DOCS/$VM_NAME.utm/config.plist" ]] || die "$(omarchy_msg utm_bundle_missing "$DOCS")"
  ok "$(omarchy_msg utm_bundle_done "$DOCS/$VM_NAME.utm")"
}

# ─────────────────────────────── fase: verify ──────────────────────────────
ph_verify() {
  phase "$(omarchy_msg phase_verify)"
  "$UTMCTL" start "$VM_NAME" >/dev/null 2>&1 || true
  info "$(omarchy_msg verify_waiting)"
  sleep 60
  local pty; pty=$("$UTMCTL" attach "$VM_NAME" 2>&1 | grep -o '/dev/ttys[0-9]*' | head -1)
  [[ -n $pty ]] || { warn "$(omarchy_msg verify_pty_missing)"; return 0; }
  # Antes esta fase recogia metricas y no las comparaba con nada, asi que
  # terminaba en "ok" pasara lo que pasara. Ahora el invitado emite un veredicto
  # y el anfitrion lo comprueba. Seis condiciones, todas necesarias:
  #   H  Hyprland vivo
  #   Q  quickshell vivo (si fuera waybar, seria Omarchy 3)
  #   B  >=400 comandos omarchy-* en /usr/bin (contados por nombre, no por
  #      total del directorio: /usr/bin tiene ~2900 ficheros del sistema y
  #      "ls | wc -l" pasaria cualquier umbral aunque no hubiera ni uno)
  #   R  <=5 enlaces rotos (uno es de qt6-webengine, ajeno a esto)
  #   U  >=6 unidades de usuario instaladas: sin ellas first-run falla en bucle
  #   V  la version del arbol empieza por 4
  # El umbral anterior miraba /usr/local/bin, donde ya no van los comandos: era
  # un falso positivo garantizado en cuanto se movieron a /usr/bin.
  local vlog="$W/logs/verify.log"
  # El heredoc va ENTRECOMILLADO. Sin comillas, el bash del anfitrion expande
  # los $(...) antes de que expect los vea, y las comprobaciones se ejecutan en
  # el Mac en vez de dentro de la VM (pgrep con sintaxis de BSD, systemctl
  # inexistente). Los tres valores que hacen falta entran por el entorno y se
  # leen con $env(...), que es cosa de Tcl y no de bash.
  PTY="$pty" GUSER="$VM_USER" GPASS="$VM_PASSWORD" \
  expect > "$vlog" 2>&1 <<'EXPEOF'
set timeout 180
log_user 1
set fd [open $env(PTY) w+]
fconfigure $fd -mode 115200,n,8,1 -translation binary -buffering none
spawn -open $fd
send "\r"
sleep 2
expect {
  -re {login:} { send "$env(GUSER)\r"; expect -re {[Pp]assword:}; send "$env(GPASS)\r"; sleep 5 }
  -re {\$ $} {}
  -re {❯} {}
  timeout {}
}
send "H=\$(pgrep -c Hyprland); Q=\$(pgrep -c quickshell); B=\$(ls /usr/bin | grep -c '^omarchy-'); R=\$(find /usr/bin -xtype l | wc -l); U=\$(ls /usr/lib/systemd/user/*.service 2>/dev/null | wc -l); V=\$(cat /usr/share/omarchy/version 2>/dev/null | cut -d. -f1); echo \"### H=\$H Q=\$Q BINS=\$B ROTOS=\$R UNITS=\$U VER=\$V\"; if \[ \$H -ge 1 ] && \[ \$Q -ge 1 ] && \[ \$B -ge 400 ] && \[ \$R -le 5 ] && \[ \$U -ge 6 ] && \[ \"\$V\" = 4 ]; then echo VEREDICTO_OK; else echo VEREDICTO_KO; fi\r"
expect { -re {VEREDICTO_(OK|KO)} {} timeout {} }
EXPEOF
  sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | grep -aE "^###" | tail -1
  if grep -qa VEREDICTO_OK "$vlog"; then
    ok "$(omarchy_msg verify_ok "$VM_NAME")"
  elif grep -qa VEREDICTO_KO "$vlog"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "$(omarchy_msg verify_incomplete "$vlog")"
  else
    warn "$(omarchy_msg verify_no_response)"
  fi
}

# ────────────────────────────── fase: sanitize ─────────────────────────────
ph_sanitize() {
  phase "$(omarchy_msg phase_sanitize)"
  write_payloads
  "$UTMCTL" stop "$VM_NAME" >/dev/null 2>&1 || true
  while [[ $("$UTMCTL" status "$VM_NAME" 2>/dev/null) == started ]]; do sleep 3; done

  local src; src=$(find "$DOCS/$VM_NAME.utm/Data" -name '*.qcow2' | head -1)
  [[ -s $src ]] || src="$W/vm/omarchy-arm.qcow2"
  rm -f "$W/dist/dist.qcow2"
  cp -c "$src" "$W/dist/dist.qcow2" 2>/dev/null || cp "$src" "$W/dist/dist.qcow2"
  ok "$(omarchy_msg sanitize_copy_done)"

  make_iso "$W/provision/repair.iso" "$W/provision/repair.sh" "$W/provision/sanitize.sh" \
           "$W/provision/config.env" "$W/provision/catalog.sh" "$W/provision/extras.sh" "$W/provision/armsync.sh"
  info "$(omarchy_msg sanitize_start)"
  PROV_ISO="$W/provision/repair.iso" DISK_IMG="$W/dist/dist.qcow2" \
  DIST_OLD_USER="$VM_USER" DIST_NEW_USER="$DIST_NEW_USER" \
    expect -f "$W/scripts/repair.exp" sanitize.sh > "$W/logs/sanitize.log" 2>&1
  grep -qa "TOK_REPAIR_0" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "$(omarchy_msg sanitize_failed "$W/logs/sanitize.log")"
  }
  ok "$(omarchy_msg sanitize_done)"
}

# ────────────────────────────── fase: package ──────────────────────────────
ph_package() {
  phase "$(omarchy_msg phase_package)"
  [[ -s $W/dist/dist.qcow2 ]] || die "$(omarchy_msg package_missing)"
  info "$(omarchy_msg package_compacting)"
  rm -f "$W/dist/slim.qcow2"
  # -c comprime dentro del propio qcow2: la imagen ocupa la mitad tambien ya
  # descomprimida en el disco de quien la recibe. Se descomprime al leer.
  qemu-img convert -c -O qcow2 "$W/dist/dist.qcow2" "$W/dist/slim.qcow2" || die "$(omarchy_msg package_convert_failed)"
  qemu-img check "$W/dist/slim.qcow2" >/dev/null || die "$(omarchy_msg package_check_failed)"
  ok "$(omarchy_msg package_sizes "$(du -h "$W/dist/dist.qcow2" | cut -f1)" "$(du -h "$W/dist/slim.qcow2" | cut -f1)")"

  rm -rf "$W/dist/$VM_NAME.utm"
  SRC_QCOW="$W/dist/slim.qcow2" DEST_DIR="$W/dist" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM OMARCHY_LANG="$OMARCHY_LANG" OMARCHY_CATALOG="$W/provision/catalog.sh" \
    NOTES_USER="$DIST_NEW_USER" NOTES_PASS="$DIST_NEW_USER" \
    bash "$W/scripts/make-utm.sh" "$VM_NAME" >/dev/null \
    || die "$(omarchy_msg package_bundle_failed)"
  # Ultima red: el bundle no debe llevar rastro del usuario de construccion
  if grep -q "\b$VM_USER\b" "$W/dist/$VM_NAME.utm/config.plist" 2>/dev/null; then
    die "$(omarchy_msg package_config_user "$VM_USER")"
  fi
  if [ "$OMARCHY_LANG" = es ]; then
    write_readme "$W/dist/LEEME.md"
  else
    write_readme_en "$W/dist/LEEME.md"
  fi

  info "$(omarchy_msg package_compressing)"
  ( cd "$W/dist" && rm -f omarchy-arm-utm.zip \
      && zip -r -q -1 omarchy-arm-utm.zip "$VM_NAME.utm" LEEME.md \
      && shasum -a 256 omarchy-arm-utm.zip > omarchy-arm-utm.zip.sha256 )
  rm -f "$W/dist/dist.qcow2" "$W/dist/slim.qcow2"
  ok "$(omarchy_msg package_done "$W/dist/omarchy-arm-utm.zip" "$(du -h "$W/dist/omarchy-arm-utm.zip" | cut -f1)")"
  cat "$W/dist/omarchy-arm-utm.zip.sha256"
}

write_readme() {
  # El texto vive en provision/src/LEEME.md y se embebe tal cual: mantener dos
  # versiones a mano hacia que la del script se quedara desfasada y llegara a
  # afirmar cosas falsas sobre lo que la imagen lleva dentro.
  cat > "$1" <<'__PAYLOAD_LEEME_MD__'
# Omarchy sobre Arch Linux ARM — imagen para UTM en Apple Silicon

**v2 · 2026-08-24**

<!-- NOTA DE VERSIÓN: esta es la copia mantenida. La que viaja dentro del .zip
     publicado en archive.org es de una revisión anterior y difiere en dos
     frases (el recuento de comandos y la nota sobre herdr/Zig). No se ha
     rehecho el zip para no invalidar el sha256 ya publicado por un cambio
     cosmético; la versión al día está suelta en el propio item. -->

Máquina virtual **aarch64 nativa** (acelerada con HVF, sin emulación) con
Arch Linux ARM + Hyprland y la configuración, temas y herramientas de
[Omarchy 4](https://omarchy.org).

## Requisitos

- Mac con Apple Silicon (M1 o superior)
- [UTM](https://mac.getutm.app) 4.7 o posterior
- ~15 GB de disco libre: el `.zip` ocupa 7 GB y la imagen descomprimida otros
  7 GB, más lo que crezca al usarla

## Instalación

1. Descomprime el `.zip`.
2. Doble clic en `Omarchy ARM.utm` (o **Archivo → Importar** en UTM).
3. Arranca la VM.

Entra solo, sin pedir contraseña.

## Credenciales

| | |
|---|---|
| Usuario | `omarchy` |
| Contraseña | `omarchy` (también para root) |

**Cambia la contraseña nada más entrar:** abre un terminal y ejecuta `passwd`.

## Teclado

macOS se queda con la tecla Cmd antes de que UTM la reciba (Cmd+Space abre
Spotlight), así que la VM está configurada con Alt y Super intercambiados:

| Tecla del Mac | En la VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

Atajos principales: **⌥+Space** abre el menú de Omarchy, **⌥+Return** un
terminal, **⌥+K** el listado completo de atajos.

Si prefieres el comportamiento original, quita `altwin:swap_lalt_lwin` de
`~/.config/hypr/input.lua` y activa la captura de entrada de UTM (requiere dar
permisos de Accesibilidad y Monitorización de entrada a UTM en Ajustes del
Sistema → Privacidad y seguridad).

## Qué esperar

Funciona: el escritorio Hyprland completo con la barra de Omarchy, temas,
menú, terminal, navegador, y los 432 comandos `omarchy-*`.

Incluye además las herramientas propias de Omarchy **compiladas para aarch64**,
que no se publican para ARM: `tensaku` (anotación de capturas), `omacalc`,
`omacut`, `omawrite`, `aether` (temas), `cliamp` (reproductor), `ttfx` (efectos
del salvapantallas), `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`,
`ttf-ia-writer`, `hyprland-preview-share-picker`, `xdg-terminal-exec`,
`tobi-try`, `ufw-docker` y `yay`.

Y dos aplicaciones de software libre ya compiladas para ARM: **OBS Studio
32.2.2** (sin el plugin de navegador, cuyo CEF es x86-only) y **Pinta 3.1.2**
(sobre el .NET arm64 oficial de Microsoft).

Limitaciones propias de correr Omarchy en ARM:

- **Sin aceleración GL dentro de la VM.** Las ventanas se dibujan por software
  (llvmpipe). Bajo virtio-gpu los clientes GPU se mapean pero no se pintan; el
  blur y las sombras vienen desactivados para compensar. Es fluido para uso
  normal, no para vídeo ni 3D.
- **Falta `herdr`**: quiere la semántica de Zig 0.15, y ni ARM ni x86_64
  empaquetan ya esa versión (los dos van por la 0.16).
- **El disco viene comprimido** dentro del `.qcow2`. Ocupa la mitad y se
  descomprime al vuelo; si prefieres velocidad de lectura sobre espacio,
  `qemu-img convert -O qcow2 disco.qcow2 sin-comprimir.qcow2`.

## Las apps que no vienen dentro

1Password, Obsidian, Typora, LocalSend y Google Chrome **no están en la
imagen**, pero no porque no funcionen: todas tienen build ARM64 oficial. No van
dentro porque son propietarias y empaquetarlas en una imagen que se distribuye
sería redistribuir binarios de terceros.

La imagen trae un instalador que las descarga de su fuente oficial:

```bash
omarchy-arm-extras --list     # ver qué puede instalar
omarchy-arm-extras            # menú interactivo
omarchy-arm-extras obsidian   # una concreta
omarchy-arm-extras --all      # todas las que falten
```

El listado marca `[ya instalada]` lo que la imagen ya trae, y `--all` lo omite.

También está en el menú de aplicaciones como **«Instalar apps que faltan (ARM)»**.

| Clave | Qué hace |
|---|---|
| `1password` | Tarball arm64 oficial, con verificación de firma GPG |
| `1password-cli` | El comando `op`, binario estático arm64 |
| `obsidian` | Tarball arm64 oficial |
| `typora` | Paquete arm64 oficial vía AUR |
| `localsend` | Build arm64 oficial |
| `chrome` | Trae Widevine para arm64: habilita Spotify y Netflix web |
| `spotify-web` | Lanzador de la web + reasigna `⌥+Shift+M` |
| `pinta` | Ya viene instalada; la clave sirve para reinstalarla |
| `obs` | Ya viene instalado; la clave sirve para reinstalarlo |

**Sobre Spotify**: no hay cliente nativo para ARM, pero la web sí funciona —
necesita Widevine, que viene dentro de Google Chrome arm64. Instala `chrome` y
luego `spotify-web`. En terminal ya tienes `spotify-player` instalado.
- **`omarchy-update` funciona**, pero cuando Omarchy introduzca un paquete
  propio nuevo, lo omitirá con un aviso en vez de instalarlo.

## Resolución

Fija en 1920x1200. Para cambiarla, edita `~/.config/hypr/monitors.lua` y
**reinicia la VM** — cambiar el modo en caliente deja la pantalla en blanco bajo
virtio-gpu.

## Nota

Imagen no oficial, sin relación con Basecamp ni con el proyecto Omarchy.
Omarchy solo soporta x86_64; esto es una reconstrucción equivalente sobre
Arch Linux ARM.
__PAYLOAD_LEEME_MD__
}

# English is the default generated artifact; the Spanish artifact above is
# retained for --lang es.
write_readme_en() {
  cat > "$1" <<'__PAYLOAD_LEEME_EN_MD__'
# Omarchy on Arch Linux ARM — UTM image for Apple Silicon

**v2 · 2026-08-24**

Native **aarch64** virtual machine (HVF accelerated, no emulation) with Arch
Linux ARM, Hyprland, and the configuration, themes, and tools of
[Omarchy 4](https://omarchy.org).

## Requirements

- Apple Silicon Mac (M1 or later)
- [UTM](https://mac.getutm.app) 4.7 or later
- About 15 GB free disk space

## Install

1. Unzip the archive.
2. Double-click `Omarchy ARM.utm` (or use **File → Import** in UTM).
3. Start the VM. It logs in automatically.

## Credentials

| | |
|---|---|
| User | `omarchy` |
| Password | `omarchy` (also root) |

Change the password immediately after login with `passwd`.

## Keyboard

The Mac keeps Cmd before UTM receives it, so Option (⌥) is configured as
SUPER. Main shortcuts: **⌥+Space** opens the Omarchy menu, **⌥+Return** opens
a terminal, and **⌥+K** shows all shortcuts.

## Optional apps

Proprietary applications are not redistributed in the image. Install official
ARM64 builds on your own machine with:

```bash
omarchy-arm-extras --list
omarchy-arm-extras
omarchy-arm-extras obsidian
omarchy-arm-extras --all
```

The image includes Hyprland, the Omarchy shell, themes, terminal, browser,
Omarchy tools compiled for aarch64, OBS Studio, and Pinta. VM rendering uses
software llvmpipe; blur and shadows are disabled for compatibility.

## Resolution and updates

The default resolution is 1920x1200. Edit `~/.config/hypr/monitors.lua` and
restart the VM to change it. `omarchy-update` keeps the checkout and system
packages up to date; ARM-unavailable Omarchy packages are skipped with a
warning.

This is an unofficial reconstruction over Arch Linux ARM. Omarchy itself
supports x86_64.
__PAYLOAD_LEEME_EN_MD__
}

# ──────────────────────────────────── preguntas ────────────────────────────
# Solo se pregunta lo que es de verdad una decision y sale caro equivocar.
# Todo lo demas (version de Alpine, URL del rootfs, rama de Omarchy, tamano del
# disco, locales) se queda como variable de entorno: son detalles de
# implementacion, no decisiones.
HACER_TOOLS=si
HACER_LIBRES=si
HACER_DIST=si

display_choice() {
  if [ "$1" = si ]; then omarchy_msg display_yes; else omarchy_msg display_no; fi
}

cuestionario() {
  detectar_del_anfitrion
  if (( ! INTERACTIVO )); then
    # Sin terminal: el comportamiento historico, todo automatico.
    return
  fi
  phase "$(omarchy_msg config)"
  info "$(omarchy_msg config_hint)"
  echo

  ask VM_TIMEZONE "$(omarchy_msg timezone)"          "$VM_TIMEZONE"
  ask VM_KEYMAP   "$(omarchy_msg keyboard_console)"   "$VM_KEYMAP"
  ask VM_XKB      "$(omarchy_msg keyboard_wayland)"   "$VM_XKB"
  echo
  ask UTM_CPUS    "$(omarchy_msg vm_cpus)"           "$UTM_CPUS"
  ask UTM_MEM     "$(omarchy_msg vm_memory)"         "$UTM_MEM"
  ask DISK_SIZE   "$(omarchy_msg disk_size)"         "$DISK_SIZE"
  echo

  # ~40 min de compilaciones. Sin ellas el escritorio funciona, pero faltan el
  # salvapantallas, el anotador de capturas y la calculadora, entre otros.
  if confirm "$(omarchy_msg confirm_tools)" si; then
    HACER_TOOLS=si
  else
    HACER_TOOLS=no
    warn "$(omarchy_msg no_tools)"
  fi
  echo

  # OBS y Pinta son lo mas caro del build. Van dentro porque son software libre
  # y la imagen que se distribuye los lleva, pero para una VM de pruebas sobran.
  if confirm "$(omarchy_msg confirm_free)" si; then
    HACER_LIBRES=si
  else
    HACER_LIBRES=no
    info "$(omarchy_msg free_after)"
  fi
  echo

  # La distincion que mas cambia el resultado: imagen para repartir frente a
  # VM para uso propio.
  info "$(omarchy_msg use_choices)"
  info "  · $(omarchy_msg dist_desc "$DIST_NEW_USER")"
  info "  · $(omarchy_msg personal_desc "$VM_USER")"
  if confirm "$(omarchy_msg confirm_dist)" no; then
    HACER_DIST=si
    ask DIST_NEW_USER "$(omarchy_msg dist_user)" "$DIST_NEW_USER"
  else
    HACER_DIST=no
    ask VM_USER     "$(omarchy_msg vm_user)"  "$VM_USER"
    ask VM_PASSWORD "$(omarchy_msg password)" "$VM_PASSWORD"
    ask VM_FULLNAME "$(omarchy_msg fullname)" "$VM_FULLNAME"
    PHASES=(deps fetch prepare build utm verify)
  fi
  echo
  info "$(omarchy_msg summary "$VM_KEYMAP" "$VM_XKB" "$VM_TIMEZONE" "$UTM_CPUS" "$UTM_MEM" "$DISK_SIZE")"
  info "$(omarchy_msg summary_tools "$(display_choice "$HACER_TOOLS")" "$(display_choice "$HACER_LIBRES")" "$(display_choice "$HACER_DIST")")"
  confirm "$(omarchy_msg confirm_start)" si || die "$(omarchy_msg cancelled)"
}

# ──────────────────────────────────── main ─────────────────────────────────
usage() { omarchy_msg usage; }

# English is the default. An explicit --lang is processed below and therefore
# overrides OMARCHY_LANG, including when repeated (the last value wins).
LANG_FROM_ENV="${OMARCHY_LANG:-en}"
LANG_ENV_INVALID=""
case "$LANG_FROM_ENV" in
  en|es) OMARCHY_LANG="$LANG_FROM_ENV" ;;
  *) LANG_ENV_INVALID="$LANG_FROM_ENV"; OMARCHY_LANG=en ;;
esac
LANG_CLI_SET=0
reject_invalid_env_language() {
  if [ -n "$LANG_ENV_INVALID" ] && [ "$LANG_CLI_SET" -eq 0 ]; then
    printf '%s\n' "Invalid language: $LANG_ENV_INVALID (expected en or es)" >&2
    usage >&2
    exit 2
  fi
}

run_from=""; run_only=""
while (($#)); do
  case "$1" in
    --lang)
      [[ $# -ge 2 ]] || { printf '%s\n' "$(omarchy_msg missing_lang)" >&2; usage >&2; exit 2; }
      case "$2" in
        en|es) OMARCHY_LANG="$2"; LANG_CLI_SET=1 ;;
        *) printf '%s\n' "$(omarchy_msg invalid_lang "$2")" >&2; usage >&2; exit 2 ;;
      esac
      shift 2 ;;
    --from) run_from="$2"; shift 2 ;;
    --only) run_only="$2"; shift 2 ;;
    --list) reject_invalid_env_language; printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    --yes|-y|--sin-preguntas) ASSUME_YES=1; INTERACTIVO=0; shift ;;
    -h|--help) reject_invalid_env_language; usage; exit 0 ;;
    *) die "$(omarchy_msg unknown_option "$1")" ;;
  esac
done

# A valid CLI selection wins even when the inherited environment is stale or
# invalid. Without a CLI selection, reject an invalid environment value.
if [ -n "$LANG_ENV_INVALID" ] && [ "$LANG_CLI_SET" -eq 0 ]; then
  printf '%s\n' "Invalid language: $LANG_ENV_INVALID (expected en or es)" >&2
  usage >&2
  exit 2
fi

# Un nombre de fase mal escrito no debe salir con exito sin hacer nada.
for sel in "$run_from" "$run_only"; do
  [[ -z $sel ]] && continue
  printf '%s\n' "${PHASES[@]}" | grep -qx "$sel" \
    || die "$(omarchy_msg unknown_phase "$sel")"
done

# Reanudar o ejecutar una sola fase no debe reabrir el cuestionario.
[[ -z $run_from && -z $run_only ]] && cuestionario

started=0
[[ -z $run_from ]] && started=1
t0=$SECONDS
for p in "${PHASES[@]}"; do
  [[ -n $run_only && $p != "$run_only" ]] && continue
  [[ -n $run_from && $p == "$run_from" ]] && started=1
  (( started )) || continue
  ensure_dirs
  "ph_$p" || die "$(omarchy_msg phase_failed "$p")"
done
echo
echo "${c_ok}$(omarchy_msg complete "$(( (SECONDS-t0)/60 ))")${c_off}"
