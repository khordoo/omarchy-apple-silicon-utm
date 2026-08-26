#!/usr/bin/env bash
# Verify that the maintained catalog is represented in the self-contained copy.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
catalog="$ROOT/localization/catalog.sh"
builder="$ROOT/build-omarchy-arm.sh"

keys_catalog=$(sed -E -n 's/.*(en|es):([a-z0-9_]+)\).*/\2/p' "$catalog" | sort -u)
keys_embedded=$(sed -n '/OMARCHY_LOCALIZATION_CATALOG/,/OMARCHY_LOCALIZATION_CATALOG_END/p' "$builder" \
  | sed -E -n 's/.*(en|es):([a-z0-9_]+)\).*/\2/p' | sort -u)
test -n "$keys_embedded" || { echo 'embedded localization catalog not found' >&2; exit 1; }
test "$keys_catalog" = "$keys_embedded" || {
  echo 'localization catalog keys differ from embedded builder copy' >&2
  diff -u <(printf '%s\n' "$keys_catalog") <(printf '%s\n' "$keys_embedded") || true
  exit 1
}

# Compare the first canonical translation for every language/key, not just
# the key set. The normalized stream makes duplicate compatibility entries
# harmless while still catching translation drift between the two copies.
normalize_entries() {
  sed -E -n "s#^[[:space:]]*(en|es):([a-z0-9_]+)[)] text='([^']*)'.*#\1\t\2\t\3#p" "$1" \
    | awk -F '\t' '!seen[$1 FS $2]++' | sort
}
canonical_entries=$(normalize_entries "$catalog")
embedded_entries=$(sed -n '/OMARCHY_LOCALIZATION_CATALOG/,/OMARCHY_LOCALIZATION_CATALOG_END/p' "$builder" | normalize_entries /dev/stdin)
test "$canonical_entries" = "$embedded_entries" || {
  echo 'localization catalog translations differ from embedded builder copy' >&2
  diff -u <(printf '%s\n' "$canonical_entries") <(printf '%s\n' "$embedded_entries") | head -80 >&2 || true
  exit 1
}

# The self-contained builder carries source bodies for every generated helper.
# Compare those heredocs with their maintained counterparts so a payload cannot
# silently regress to an older untranslated copy.
payload_body() {
  local marker="$1" start end
  start=$(rg -n -m1 "^cat > .*<<'${marker}'" "$builder" | cut -d: -f1)
  end=$(rg -n -m1 "^${marker}$" "$builder" | cut -d: -f1)
  test -n "$start" && test -n "$end" || return 1
  sed -n "$((start + 1)),$((end - 1))p" "$builder"
}
while IFS=: read -r marker source; do
  [ -n "$marker" ] || continue
  test -f "$ROOT/$source" || { echo "payload source missing: $source" >&2; exit 1; }
  if ! diff -q <(payload_body "$marker") "$ROOT/$source" >/dev/null; then
    echo "embedded payload differs from $source" >&2
    exit 1
  fi
done <<'PAYLOADS'
__PAYLOAD_PROVISION_STAGE1_SH__:provision/src/stage1.sh
__PAYLOAD_PROVISION_STAGE2_SH__:provision/src/stage2.sh
__PAYLOAD_PROVISION_STAGE3_SH__:provision/src/stage3.sh
__PAYLOAD_PROVISION_REPAIR_SH__:provision/src/repair.sh
__PAYLOAD_PROVISION_SANITIZE_SH__:provision/src/sanitize.sh
__PAYLOAD_PROVISION_EXTRAS_SH__:provision/src/omarchy-arm-extras
__PAYLOAD_PROVISION_ARMSYNC_SH__:provision/src/hooks/10-arm-sync
__PAYLOAD_PROVISION_CLIPBRD_SH__:provision/src/omarchy-arm-clipboard
__PAYLOAD_PROVISION_VDAGENT_PY__:provision/src/omarchy-arm-vdagent
__PAYLOAD_SCRIPTS_BUILD_EXP__:scripts/build.exp
__PAYLOAD_SCRIPTS_REPAIR_EXP__:scripts/repair.exp
__PAYLOAD_SCRIPTS_QEMU_SH__:scripts/qemu-build.sh
__PAYLOAD_SCRIPTS_MAKE-UTM_SH__:scripts/make-utm.sh
PAYLOADS

# Every literal message key used by the builder or its embedded/standalone
# payloads must have both translations. This prevents silent fallback to the
# untranslated argument when a payload grows a new log message.
reference_files=("$builder")
for file in "$ROOT"/scripts/*.sh "$ROOT"/scripts/omssh \
  "$ROOT"/provision/src/*.sh "$ROOT"/provision/src/omarchy-arm-* \
  "$ROOT"/provision/src/hooks/* "$ROOT"/provision/repair-iso/*.sh; do
  [ -f "$file" ] && reference_files+=("$file")
done
referenced_keys=$(rg -o --no-filename '(omarchy_msg|msg)[[:space:]]+[a-z][a-z0-9_]*' \
  "${reference_files[@]}" 2>/dev/null \
  | sed -E 's/^(omarchy_msg|msg)[[:space:]]+//' \
  | grep -vE '^(eof|iso|login|prompt|shell|success|verify)$' | sort -u)
missing_references=$(comm -23 <(printf '%s\n' "$referenced_keys") <(printf '%s\n' "$keys_catalog"))
test -z "$missing_references" || {
  echo 'catalog keys missing for referenced messages:' >&2
  printf '%s\n' "$missing_references" >&2
  exit 1
}

# Every translated entry must preserve its printf interface. This catches a
# catalog edit that silently drops a path, package name, or phase value.
placeholders() {
  local file="$1" lang="$2" key="$3" text
  text=$(sed -E -n "s/^[[:space:]]*${lang}:${key}\) text='([^']*)'.*/\1/p" "$file" | head -1)
  printf '%s' "$text" | grep -oE '%[0-9]*[a-zA-Z]' 2>/dev/null | sort | tr '\n' ' ' || true
}
while read -r key; do
  [ -n "$key" ] || continue
  c_en=$(placeholders "$catalog" en "$key")
  c_es=$(placeholders "$catalog" es "$key")
  test "$c_en" = "$c_es" || {
    echo "placeholder mismatch between languages: $key" >&2
    exit 1
  }
  for lang in en es; do
    c=$(placeholders "$catalog" "$lang" "$key")
    e=$(placeholders "$builder" "$lang" "$key")
    test "$c" = "$e" || {
      echo "placeholder mismatch: $lang:$key" >&2
      exit 1
    }
  done
done <<EOF
$keys_catalog
EOF
echo 'localization catalog: synchronized'
