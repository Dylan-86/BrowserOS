#!/usr/bin/env bash
#
# build-neo-linux.sh — compila BrowserOS neo (browserclaw) come .deb per Linux x64.
#
# Va eseguito dalla radice del clone di BrowserOS, su una macchina che puoi
# permetterti di tenere occupata per 5-11 ore. NON sul server di produzione.
#
#   ./build-neo-linux.sh                 # tutto, dall'inizio alla fine
#   ./build-neo-linux.sh --from build    # riprende dalla compilazione
#   ./build-neo-linux.sh --only resources  # esegue un solo stage
#   ./build-neo-linux.sh --recompile     # solo compile + package, senza reset dell'albero
#   ./build-neo-linux.sh --dry-run       # stampa cosa farebbe, non esegue nulla
#   ./build-neo-linux.sh --help
#
# Vedi BUILD-NEO-LINUX.md per il contesto e per il perché di ogni passaggio.

set -euo pipefail

# ---------------------------------------------------------------- parametri --

PRODUCT="browserclaw"
ARCH="x64"
CHROMIUM_ROOT="${CHROMIUM_ROOT:-$HOME/chromium}"

# Risorse pubbliche che sostituiscono lo step download_resources (richiede R2).
# Aggiornabili con --latest-resources, o a mano guardando le GitHub Release.
CLAW_SERVER_TAG="${CLAW_SERVER_TAG:-claw-server/v0.0.46}"
CLAW_ONBOARD_TAG="${CLAW_ONBOARD_TAG:-claw-onboard/v0.0.15}"

RELEASE_BASE="https://github.com/browseros-ai/BrowserOS/releases/download"
GITHUB_API="https://api.github.com/repos/browseros-ai/BrowserOS/releases?per_page=100"

STAGES=(deps toolchain checkout builddeps resources build)
FROM_STAGE="deps"
ONLY_STAGE=""
DRY_RUN=0
RECOMPILE=0
LATEST_RESOURCES=0
JOBS="${BROWSEROS_NINJA_JOBS:-}"

# ------------------------------------------------------------------ output --

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_ACC=$'\033[36m'; C_0=$'\033[0m'
else
  C_DIM=""; C_B=""; C_OK=""; C_WARN=""; C_ERR=""; C_ACC=""; C_0=""
fi

log()   { printf '%s\n' "${C_DIM}   $*${C_0}"; }
step()  { printf '\n%s\n' "${C_ACC}${C_B}▸ $*${C_0}"; }
ok()    { printf '%s\n' "${C_OK}   ✓ $*${C_0}"; }
warn()  { printf '%s\n' "${C_WARN}   ! $*${C_0}" >&2; }
die()   { printf '\n%s\n' "${C_ERR}✗ $*${C_0}" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}   \$ $*${C_0}"
  else
    printf '%s\n' "${C_DIM}   \$ $*${C_0}"
    "$@"
  fi
}

usage() {
  awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
  printf '\nStage disponibili per --from: %s\n' "${STAGES[*]}"
  printf '\nVariabili d'\''ambiente:\n'
  printf '  CHROMIUM_ROOT         dove vive il checkout (default: ~/chromium)\n'
  printf '  BROWSEROS_NINJA_JOBS  parallelismo ninja (default: calcolato da CPU e RAM)\n'
  printf '  CLAW_SERVER_TAG       tag della release del server (default: %s)\n' "$CLAW_SERVER_TAG"
  printf '  CLAW_ONBOARD_TAG      tag della release onboarding (default: %s)\n' "$CLAW_ONBOARD_TAG"
}

# ------------------------------------------------------------------- parsing --

while [ $# -gt 0 ]; do
  case "$1" in
    --from)             FROM_STAGE="${2:?--from richiede uno stage}"; shift 2 ;;
    --from=*)           FROM_STAGE="${1#*=}"; shift ;;
    --only)             ONLY_STAGE="${2:?--only richiede uno stage}"; shift 2 ;;
    --only=*)           ONLY_STAGE="${1#*=}"; shift ;;
    --jobs|-j)          JOBS="${2:?--jobs richiede un numero}"; shift 2 ;;
    --jobs=*)           JOBS="${1#*=}"; shift ;;
    --chromium-root)    CHROMIUM_ROOT="${2:?--chromium-root richiede un path}"; shift 2 ;;
    --chromium-root=*)  CHROMIUM_ROOT="${1#*=}"; shift ;;
    --latest-resources) LATEST_RESOURCES=1; shift ;;
    --recompile)        RECOMPILE=1; shift ;;
    --dry-run|-n)       DRY_RUN=1; shift ;;
    --help|-h)          usage; exit 0 ;;
    *)                  die "Opzione sconosciuta: $1  (--help per l'elenco)" ;;
  esac
done

stage_index() {
  local want="$1" i=0
  for s in "${STAGES[@]}"; do
    [ "$s" = "$want" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

FROM_INDEX="$(stage_index "$FROM_STAGE")" \
  || die "Stage '$FROM_STAGE' sconosciuto. Validi: ${STAGES[*]}"

if [ -n "$ONLY_STAGE" ]; then
  stage_index "$ONLY_STAGE" >/dev/null \
    || die "Stage '$ONLY_STAGE' sconosciuto. Validi: ${STAGES[*]}"
fi

should_run() {
  if [ -n "$ONLY_STAGE" ]; then
    [ "$1" = "$ONLY_STAGE" ]
    return
  fi
  local idx
  idx="$(stage_index "$1")"
  [ "$idx" -ge "$FROM_INDEX" ]
}

# ------------------------------------------------------------- orientamento --

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
BOS_DIR="$REPO_ROOT/packages/browseros"

[ -f "$BOS_DIR/CHROMIUM_VERSION" ] \
  || die "Non trovo packages/browseros/CHROMIUM_VERSION.
   Lo script va tenuto nella radice del clone di BrowserOS."

# shellcheck disable=SC1091
. "$BOS_DIR/CHROMIUM_VERSION"
CHROMIUM_VERSION="$MAJOR.$MINOR.$BUILD.$PATCH"

BROWSEROS_MAJOR=0; BROWSEROS_MINOR=0; BROWSEROS_BUILD=0; BROWSEROS_PATCH=0
# shellcheck disable=SC1091
. "$BOS_DIR/resources/BROWSEROS_VERSION"
if   [ "$BROWSEROS_PATCH" != "0" ]; then
  SEMVER="$BROWSEROS_MAJOR.$BROWSEROS_MINOR.$BROWSEROS_BUILD.$BROWSEROS_PATCH"
elif [ "$BROWSEROS_BUILD" != "0" ]; then
  SEMVER="$BROWSEROS_MAJOR.$BROWSEROS_MINOR.$BROWSEROS_BUILD"
else
  SEMVER="$BROWSEROS_MAJOR.$BROWSEROS_MINOR.0"
fi

CHROMIUM_SRC="$CHROMIUM_ROOT/src"
DEB_PATH="$BOS_DIR/releases/$SEMVER/BrowserOS_neo_v${SEMVER}_amd64.deb"
APPIMAGE_PATH="$BOS_DIR/releases/$SEMVER/BrowserOS_neo_v${SEMVER}_${ARCH}.AppImage"

# ------------------------------------------------ parallelismo e preflight --

pick_jobs() {
  local cpus ram_gb cap
  cpus="$(nproc 2>/dev/null || printf '4')"
  ram_gb="$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || printf '8')"
  # ~2 GB per job di compilazione: sotto questa soglia il link ThinLTO
  # finisce in mano all'OOM killer dopo ore di lavoro già fatto.
  cap=$(( ram_gb / 2 ))
  [ "$cap" -lt 1 ] && cap=1
  if [ "$cap" -lt "$cpus" ]; then
    printf '%s' "$cap"
  else
    printf '%s' "$cpus"
  fi
}

preflight() {
  step "Preflight"
  log "repo            $REPO_ROOT"
  log "prodotto        $PRODUCT ($ARCH)  ·  BrowserOS neo $SEMVER"
  log "chromium        $CHROMIUM_VERSION → $CHROMIUM_SRC"

  if [ -z "$JOBS" ]; then
    JOBS="$(pick_jobs)"
    log "ninja jobs      $JOBS (da $(nproc) CPU e $(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo) GB di RAM)"
  else
    log "ninja jobs      $JOBS (imposto a mano)"
  fi

  local avail
  avail="$(df -BG --output=avail "$(dirname "$CHROMIUM_ROOT")" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ -n "$avail" ]; then
    log "spazio libero   ${avail} GB su $(dirname "$CHROMIUM_ROOT")"
    if [ "$avail" -lt 90 ]; then
      warn "Servono ~80 GB e ne restano ${avail}. Continuo lo stesso, ma occhio."
    fi
  fi

  if [ -n "$ONLY_STAGE" ]; then
    log "stage           solo '${ONLY_STAGE}'"
  elif [ "$FROM_INDEX" -gt 0 ] || [ "$RECOMPILE" -eq 1 ]; then
    log "ripartenza      da '${FROM_STAGE}'$([ "$RECOMPILE" -eq 1 ] && printf ' (--recompile)')"
  fi
  [ "$DRY_RUN" -eq 1 ] && warn "DRY RUN — nessun comando verrà eseguito davvero"
  return 0
}

need_sudo() {
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  command -v sudo >/dev/null 2>&1 || die "Serve sudo per '$1' e non è installato."
  log "'$1' richiede sudo — potrebbe chiederti la password"
}

# ------------------------------------------------------------------ stages --

stage_deps() {
  step "1/6  Pacchetti di sistema"
  local pkgs=(git curl unzip file python3)
  # appimagetool è a sua volta una AppImage e vuole FUSE 2.
  # Il pacchetto ha cambiato nome con la transizione t64 di Ubuntu 24.04.
  if apt-cache show libfuse2t64 >/dev/null 2>&1; then
    pkgs+=(libfuse2t64)
  elif apt-cache show libfuse2 >/dev/null 2>&1; then
    pkgs+=(libfuse2)
  else
    warn "Né libfuse2t64 né libfuse2 disponibili: l'AppImage fallirà, il .deb no."
  fi
  need_sudo "apt install"
  run sudo apt-get update
  run sudo apt-get install -y "${pkgs[@]}"
  ok "Pacchetti a posto"
}

stage_toolchain() {
  step "2/6  Build system (uv)"
  if ! command -v uv >/dev/null 2>&1; then
    log "uv non presente, lo installo in ~/.local/bin (userspace, non tocca il sistema)"
    if [ "$DRY_RUN" -eq 0 ]; then
      curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
  fi
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ] \
    || die "uv installato ma non in PATH. Apri una shell nuova e rilancia."

  run uv sync --project "$BOS_DIR"

  log "Verifico che il piano si componga (non serve il checkout Chromium)"
  if [ "$DRY_RUN" -eq 0 ]; then
    ( cd "$BOS_DIR" && uv run browseros build \
        --preset release --product "$PRODUCT" --arch "$ARCH" \
        --no-sign --no-upload --provision shallow \
        --skip download_resources --show-plan )
  fi
  ok "Build system pronto"
}

stage_checkout() {
  step "3/6  Checkout di Chromium $CHROMIUM_VERSION"
  log "30-60 minuti, ~30 GB. Scarica depot_tools da solo. È idempotente."
  export PATH="$HOME/.local/bin:$PATH"
  run uv run --project "$BOS_DIR" browseros source ensure \
    --root "$CHROMIUM_ROOT" --strategy shallow --step checkout
  ok "Checkout pronto in $CHROMIUM_SRC"
}

stage_builddeps() {
  step "4/6  Dipendenze di build di Chromium"
  local script="$CHROMIUM_SRC/build/install-build-deps.sh"
  if [ "$DRY_RUN" -eq 0 ] && [ ! -x "$script" ]; then
    die "Non trovo $script — lo stage 'checkout' è andato a buon fine?"
  fi
  need_sudo "install-build-deps.sh"
  # Chromium 151 riconosce focal, jammy, noble e resolute (Ubuntu 26.04).
  # Su una distro fuori elenco lo script si ferma senza --unsupported.
  local codename=""
  command -v lsb_release >/dev/null 2>&1 && codename="$(lsb_release -cs 2>/dev/null || true)"
  case "$codename" in
    focal|jammy|noble|resolute|"")
      run sudo "$script" --no-prompt ;;
    *)
      warn "Distro '$codename' non nell'elenco supportato: uso --unsupported"
      run sudo "$script" --no-prompt --unsupported ;;
  esac
  ok "Dipendenze di sistema installate"
}

resolve_latest_tag() {
  # Primo tag della famiglia richiesta, senza dipendere da jq.
  local family="$1"
  curl -fsSL "$GITHUB_API" 2>/dev/null \
    | grep -o "\"tag_name\": *\"${family}/v[^\"]*\"" \
    | head -1 \
    | sed "s/.*\"\(${family}\/v[^\"]*\)\"/\1/"
}

fetch_resource() {
  local tag="$1" asset="$2" dest="$3" tmp
  tmp="$(mktemp -d)"
  log "$tag → $asset"
  run curl -fL --retry 3 --progress-bar -o "$tmp/$asset" "$RELEASE_BASE/$tag/$asset"
  run mkdir -p "$dest"
  run unzip -oq "$tmp/$asset" -d "$dest"
  rm -rf "$tmp"
}

stage_resources() {
  step "5/6  Risorse dalle GitHub Release"
  log "Sostituisce lo step download_resources, che vuole credenziali R2 che non abbiamo."

  if [ "$LATEST_RESOURCES" -eq 1 ]; then
    local t
    t="$(resolve_latest_tag claw-server  || true)"; [ -n "$t" ] && CLAW_SERVER_TAG="$t"
    t="$(resolve_latest_tag claw-onboard || true)"; [ -n "$t" ] && CLAW_ONBOARD_TAG="$t"
    log "Tag più recenti: $CLAW_SERVER_TAG · $CLAW_ONBOARD_TAG"
  fi

  fetch_resource "$CLAW_SERVER_TAG" \
    "browseros-claw-server-rust-resources-linux-${ARCH}.zip" \
    "$BOS_DIR/resources/binaries/browseros_claw_server_rust/linux-${ARCH}"

  fetch_resource "$CLAW_ONBOARD_TAG" \
    "browseros-claw-onboard-resources.zip" \
    "$BOS_DIR/resources/binaries/browseros_claw_onboard"

  local server_bin="$BOS_DIR/resources/binaries/browseros_claw_server_rust/linux-${ARCH}/resources/bin/browseros-claw-server"
  if [ "$DRY_RUN" -eq 0 ]; then
    [ -f "$server_bin" ] || die "Il server non è al suo posto: $server_bin"
    file "$server_bin" | grep -q 'ELF 64-bit' \
      || die "Il server non è un ELF a 64 bit — hai scaricato l'asset sbagliato?"
    [ -x "$server_bin" ] || run chmod +x "$server_bin"
    ok "Server $(basename "$CLAW_SERVER_TAG") verificato (ELF 64-bit)"
  fi
  ok "Risorse in posizione"
}

stage_build() {
  step "6/6  Build"
  # gn vive in depot_tools/. In CI questo lo mette in PATH GITHUB_PATH
  # (vedi provision.py:196), qui bisogna farlo a mano prima di 'configure'.
  local depot_tools="$CHROMIUM_ROOT/depot_tools"
  [ "$DRY_RUN" -eq 0 ] && [ ! -d "$depot_tools" ] \
    && die "Non trovo $depot_tools — lo stage 'checkout' è andato a buon fine?"
  export PATH="$HOME/.local/bin:$depot_tools:$PATH"
  export BROWSEROS_NINJA_JOBS="$JOBS"

  local args=(
    --preset release
    --product "$PRODUCT"
    --arch "$ARCH"
    --no-sign --no-upload
    --skip download_resources
    --chromium-src "$CHROMIUM_SRC"
  )

  if [ "$RECOMPILE" -eq 1 ]; then
    # L'albero è già sincronizzato: 'clean' farebbe git clean -fdx third_party/
    # e porterebbe via le toolchain che solo gclient sync sa rimettere.
    log "Modalità --recompile: nessun reset dell'albero, riparto da 'compile'"
    args+=(--provision none --no-clean --from compile)
  else
    # shallow ordina da solo checkout → clean → sync, che è l'unico ordine giusto.
    args+=(--provision shallow)
  fi

  log "ninja -j $JOBS · da qui sono 4-10 ore, puoi staccarti"
  ( cd "$BOS_DIR" && run uv run browseros build "${args[@]}" )
}

# -------------------------------------------------------------------- main --

trap 'printf "\n%s\n" "${C_ERR}✗ Interrotto. Riparti con: $0 --from <stage>${C_0}" >&2' INT TERM

preflight

BUILD_RAN=0

if [ "$RECOMPILE" -eq 1 ]; then
  stage_build; BUILD_RAN=1
else
  should_run deps      && stage_deps
  should_run toolchain && stage_toolchain
  should_run checkout  && stage_checkout
  should_run builddeps && stage_builddeps
  should_run resources && stage_resources
  should_run build     && { stage_build; BUILD_RAN=1; }
fi

# ------------------------------------------------------------------ esito --

printf '\n'
if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry run completo — nessuna modifica fatta"
  exit 0
fi

if [ "$BUILD_RAN" -eq 0 ]; then
  ok "Stage completati. Il .deb esce solo dopo lo stage 'build'."
  exit 0
fi

if [ -f "$DEB_PATH" ]; then
  printf '%s\n' "${C_OK}${C_B}✓ Fatto.${C_0}"
  printf '\n  %s\n' "${C_B}$DEB_PATH${C_0}"
  printf '  %s\n' "${C_DIM}$(du -h "$DEB_PATH" | cut -f1)${C_0}"
  [ -f "$APPIMAGE_PATH" ] && printf '  %s\n' "${C_DIM}$APPIMAGE_PATH${C_0}"
  printf '\n  Installa con:\n'
  printf '    %s\n\n' "${C_ACC}sudo apt install \"$DEB_PATH\"${C_0}"
  printf '  %s\n\n' "${C_DIM}Usa apt, non dpkg -i: è l'unico dei due che scarica le dipendenze mancanti.${C_0}"
else
  die "Build finita ma il .deb non c'è: $DEB_PATH
   Guarda l'output qui sopra; per riprovare solo compile+package:
   $0 --recompile"
fi
