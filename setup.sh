#!/usr/bin/env bash
# Prepare a fresh Ubuntu server to run local models.
# Usage: sudo ./setup.sh [--yes] [--detect-only]
set -euo pipefail

AI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${AI_DATA_DIR:-}" ]]; then
  AI_DATA_DIR="/var/lib/ai-ready"
fi
AI_DATA_DIR="${AI_DATA_DIR%/}"
export AI_DATA_DIR

# shellcheck source=lib/common.sh
source "$AI_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$AI_ROOT/lib/detect.sh"
# shellcheck source=lib/select-models.sh
source "$AI_ROOT/lib/select-models.sh"
# shellcheck source=lib/install-docker.sh
source "$AI_ROOT/lib/install-docker.sh"
# shellcheck source=lib/install-nvidia.sh
source "$AI_ROOT/lib/install-nvidia.sh"
# shellcheck source=lib/install-tailscale.sh
source "$AI_ROOT/lib/install-tailscale.sh"
# shellcheck source=lib/render-compose.sh
source "$AI_ROOT/lib/render-compose.sh"

ASSUME_YES=0
DETECT_ONLY=0

needs_root=1
for arg in "$@"; do
  case "$arg" in
    --detect-only|-h|--help) needs_root=0 ;;
  esac
done
if [[ "$needs_root" -eq 1 && "${EUID}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    die "Run this installer as root."
  fi
  exec sudo --preserve-env=TAILSCALE_AUTHKEY,HF_TOKEN,AI_DATA_DIR "$0" "$@"
fi

usage() {
  cat <<'EOF'
Usage: sudo ./setup.sh [--yes] [--detect-only]

  --detect-only   Print the hardware fit and model plan, then exit.
  --yes           Download the selected models without asking.

Environment:
  AI_DATA_DIR         Model and Compose data. Default: /var/lib/ai-ready
  TAILSCALE_AUTHKEY   Optional unattended Tailscale login key.
  HF_TOKEN            Optional Hugging Face token for gated image models.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --detect-only) DETECT_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

if [[ "$AI_DATA_DIR" == *" "* || "$AI_DATA_DIR" == *:* ]]; then
  die "AI_DATA_DIR cannot contain spaces or colons."
fi

refresh_plan() {
  mkdir -p "$AI_DATA_DIR"
  detect_hardware "$AI_DATA_DIR/hardware.json" "$AI_DATA_DIR"
  select_models "$AI_DATA_DIR/hardware.json" "$AI_ROOT/catalog/models.json" "$AI_DATA_DIR/selection.json"
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "This installer supports Ubuntu 22.04 and 24.04."
  fi
  local id version pretty
  # shellcheck disable=SC1091
  source /etc/os-release
  id="${ID:-}"
  version="${VERSION_ID:-}"
  pretty="${PRETTY_NAME:-unknown}"
  if [[ "$id" != "ubuntu" || ( "$version" != "22.04" && "$version" != "24.04" ) ]]; then
    die "This installer supports Ubuntu 22.04 and 24.04 (found ${pretty})."
  fi
}

write_secret_env() {
  mkdir -p /etc/ai-ready
  chmod 700 /etc/ai-ready
  if [[ ! -f "$AI_ENV_FILE" ]]; then
    umask 077
    printf 'WEBUI_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" >"$AI_ENV_FILE"
  fi
  if [[ -n "${HF_TOKEN:-}" ]] && ! grep -q '^HF_TOKEN=' "$AI_ENV_FILE"; then
    printf 'HF_TOKEN=%s\n' "$HF_TOKEN" >>"$AI_ENV_FILE"
  fi
  chmod 600 "$AI_ENV_FILE"
}

selection_fingerprint() {
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); image=(data["chosen"].get("image") or {}).get("id",""); print(",".join(data["pull"]+[image]))' "$1"
}

confirm_downloads() {
  local selection_json="$1"
  local fingerprint count
  fingerprint="$(selection_fingerprint "$selection_json")"
  count="$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(len(data["pull"]) + (1 if "image" in data["chosen"] else 0))' "$selection_json")"
  if [[ "$count" -eq 0 ]]; then
    return 1
  fi
  if state_has "models:${fingerprint}"; then
    return 0
  fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    die "No terminal to confirm model downloads. Re-run with --yes."
  fi
  local answer
  read -r -p "Download these models? [y/N] " answer </dev/tty
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    return 0
  fi
  log "Skipped model downloads. Re-run setup.sh when you want them."
  return 1
}

download_file() {
  local url="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" ]]; then
    return 0
  fi
  local -a auth=()
  local -a resume=()
  if [[ -n "${HF_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${HF_TOKEN}")
  fi
  if [[ -s "${dest}.partial" ]]; then
    resume=(-C -)
  fi
  if ! curl -fL --retry 5 --retry-delay 2 "${resume[@]}" "${auth[@]}" -o "${dest}.partial" "$url"; then
    return 1
  fi
  mv "${dest}.partial" "$dest"
}

download_models() {
  local selection_json="$1"
  local errors="$AI_DATA_DIR/download-errors.txt"
  : >"$errors"
  local tag
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    log "Pulling ${tag}"
    if ! docker compose -p ai-ready --env-file "$AI_ENV_FILE" -f "$AI_DATA_DIR/docker-compose.yml" exec -T ollama ollama pull "$tag"; then
      printf 'ollama pull failed: %s\n' "$tag" >>"$errors"
    fi
  done < <(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print("\n".join(data["pull"]))' "$selection_json")

  while read -r url dest; do
    [[ -z "${url:-}" ]] && continue
    local target="$AI_DATA_DIR/comfyui/models/${dest}"
    log "Downloading ${dest}"
    if ! download_file "$url" "$target"; then
      printf 'checkpoint download failed: %s\n' "$dest" >>"$errors"
      continue
    fi
    if [[ "$dest" == diffusion_models/* ]]; then
      mkdir -p "$AI_DATA_DIR/comfyui/models/unet"
      ln -sfn "../${dest}" "$AI_DATA_DIR/comfyui/models/unet/$(basename "$dest")"
    fi
  done < <(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); image=data["chosen"].get("image"); print("" if not image else "\n".join(item["url"]+" "+item["dest"] for item in image["files"]))' "$selection_json")

  if [[ -s "$errors" ]]; then
    return 1
  fi
  local fingerprint
  fingerprint="$(selection_fingerprint "$selection_json")"
  state_add "models:${fingerprint}"
}

wait_for_ollama() {
  for _ in $(seq 1 30); do
    if docker compose -p ai-ready --env-file "$AI_ENV_FILE" -f "$AI_DATA_DIR/docker-compose.yml" exec -T ollama ollama list >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "Ollama did not become ready. Check: docker compose -p ai-ready -f ${AI_DATA_DIR}/docker-compose.yml logs ollama"
}

write_report_file() {
  local extras
  extras="$(mktemp)"
  python3 - "$extras" <<'PY'
import json, os, pathlib, sys
extras_path = sys.argv[1]
errors = []
error_file = pathlib.Path(os.environ["AI_DATA_DIR"]) / "download-errors.txt"
if error_file.exists():
    errors = [line for line in error_file.read_text(encoding="utf-8").splitlines() if line]
url = os.environ.get("AI_TAILSCALE_URL", "")
pending = os.environ.get("AI_TAILSCALE_PENDING", "") == "1"
json.dump({"download_errors": errors, "url": url, "tailscale_pending": pending}, open(extras_path, "w", encoding="utf-8"))
PY
  format_report "$AI_DATA_DIR/hardware.json" "$AI_DATA_DIR/selection.json" "$extras" | tee "$AI_DATA_DIR/report.txt"
  rm -f "$extras"
  log "Report written to ${AI_DATA_DIR}/report.txt"
}

run_detect_only() {
  local tmp
  tmp="$(mktemp -d)"
  detect_hardware "$tmp/hardware.json" "$AI_DATA_DIR"
  select_models "$tmp/hardware.json" "$AI_ROOT/catalog/models.json" "$tmp/selection.json"
  format_report "$tmp/hardware.json" "$tmp/selection.json"
  rm -rf "$tmp"
}

if [[ "$DETECT_ONLY" -eq 1 ]]; then
  run_detect_only
  exit 0
fi

require_ubuntu
mkdir -p "$AI_DATA_DIR"
touch "$AI_LOG_FILE"
exec > >(tee -a "$AI_LOG_FILE") 2>&1
log "Logging to ${AI_LOG_FILE}"

install_base_packages
install_docker
refresh_plan
install_nvidia "$AI_DATA_DIR/hardware.json"
refresh_plan
write_secret_env
render_stack "$AI_DATA_DIR/hardware.json" "$AI_DATA_DIR/selection.json"
docker compose -p ai-ready --env-file "$AI_ENV_FILE" -f "$AI_DATA_DIR/docker-compose.yml" up -d
wait_for_ollama

if confirm_downloads "$AI_DATA_DIR/selection.json"; then
  download_models "$AI_DATA_DIR/selection.json" || log "Some model downloads failed. Details are in the report."
fi

install_tailscale
configure_firewall
if tailscale_logged_in; then
  AI_TAILSCALE_URL="$(tailscale_url)"
  AI_TAILSCALE_PENDING=0
else
  AI_TAILSCALE_URL=""
  AI_TAILSCALE_PENDING=1
fi
export AI_TAILSCALE_URL AI_TAILSCALE_PENDING
write_report_file
