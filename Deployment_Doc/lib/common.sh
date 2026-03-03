#!/bin/bash
# Shared helper functions for MISHKA deployment scripts.

COLOR_RESET="\033[0m"
COLOR_BLUE="\033[0;34m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[0;31m"

LOG_TS() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
  echo -e "${COLOR_BLUE}[INFO $(LOG_TS)]${COLOR_RESET} $1"
}

log_success() {
  echo -e "${COLOR_GREEN}[OK   $(LOG_TS)]${COLOR_RESET} $1"
}

log_warn() {
  echo -e "${COLOR_YELLOW}[WARN $(LOG_TS)]${COLOR_RESET} $1"
}

log_error() {
  echo -e "${COLOR_RED}[ERR  $(LOG_TS)]${COLOR_RESET} $1" 1>&2
}

refresh_auth_header() {
  AUTH_HEADER=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_HEADER=(-H "Authorization: token ${GITHUB_TOKEN}")
  fi
}

CURRENT_USER="$(id -un 2>/dev/null || printf '%s' "${USER:-root}")"

refresh_auth_header

DOCKER_CMD_PREFIX=()

SERVICE_IMAGES=(
  "mishka-web-app"
  "mishka-http-data-uploader"
  "mishka-mqtt-processor"
  "mishka-device-config-manager"
  "mishka-device-status-monitor"
  "mishka-status-event-sender"
  "mishka-ota-services"
  "mishka-wifi-manager"
  "mishka-health-monitor"
  "mishka-github-firmware-sync"
  "mishka-usb-device-monitor"
  "mishka-update-coordinator"
  "mishka-rpi-system-ota-sync"
  "mishka-rpi-update-coordinator"
  "mishka-local-ble-scanner"
)

set_docker_cmd_prefix() {
  DOCKER_CMD_PREFIX=()
  if docker info >/dev/null 2>&1; then
    return
  fi

  if sudo docker info >/dev/null 2>&1; then
    DOCKER_CMD_PREFIX=(sudo)
    log_warn "Docker daemon not accessible to user '$CURRENT_USER'; routing docker commands through sudo"
    return
  fi

  log_error "Unable to communicate with the Docker daemon even via sudo"
  exit 1
}

ensure_packages() {
  local missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_info "Installing packages: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}"
  fi
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    log_info "Docker already installed"
    if ! id -nG "$CURRENT_USER" 2>/dev/null | tr ' ' '\n' | grep -q '^docker$'; then
      log_warn "User '$CURRENT_USER' is not in the docker group; attempting to add now"
      if sudo usermod -aG docker "$CURRENT_USER"; then
        log_info "Added '$CURRENT_USER' to docker group"
      else
        log_warn "Failed to add '$CURRENT_USER' to docker group"
      fi
    fi
    if [ -S /var/run/docker.sock ] && [ ! -w /var/run/docker.sock ]; then
      log_warn "Docker socket not writable; adjusting permissions"
      sudo chgrp docker /var/run/docker.sock || true
      sudo chmod 660 /var/run/docker.sock || true
    fi
    set_docker_cmd_prefix
    return
  fi
  log_info "Installing Docker Engine"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$CURRENT_USER" || true
  sudo systemctl enable --now docker
  log_warn "Docker installed. Log out/in if current session cannot access docker group."
  set_docker_cmd_prefix

  # Enable memory cgroups for Docker stats
  local cmdline_file="/boot/firmware/cmdline.txt"
  [ ! -f "$cmdline_file" ] && cmdline_file="/boot/cmdline.txt"

  if [ -f "$cmdline_file" ]; then
    if ! grep -q "cgroup_memory=1" "$cmdline_file"; then
      log_info "Enabling memory cgroups in $cmdline_file"
      sudo sed -i 's/$/ cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1/' "$cmdline_file"
      log_warn "Memory cgroups enabled. A REBOOT is required for Docker stats to work!"
    fi
  fi
}

prepare_directories() {
  sudo mkdir -p "$WORK_DIR"
  sudo chown -R "$CURRENT_USER":"$CURRENT_USER" "$WORK_DIR"
  sudo mkdir -p "$CONFIG_DIR"
  sudo mkdir -p "${FIRMWARE_ROOT}"
  sudo chown root:"$USER" "$CONFIG_DIR"
  sudo chmod 755 "$CONFIG_DIR"
  sudo mkdir -p "${CONFIG_DIR}/firmware"
  sudo chown "$USER":"$USER" "${CONFIG_DIR}/firmware"
  sudo chmod 775 "${CONFIG_DIR}/firmware"
  sudo chown "$USER":"$USER" "$FIRMWARE_ROOT"
  sudo chmod 775 "$FIRMWARE_ROOT"
  mkdir -p "$WORK_DIR/systemd"
}

clear_manifest_cache() {
  log_info "Clearing Docker manifest cache"
  local manifest_dirs=("$HOME/.docker/manifests" "/root/.docker/manifests")
  for dir in "${manifest_dirs[@]}"; do
    if [ -d "$dir" ]; then
      if [[ "$dir" == /root/* ]]; then
        sudo rm -rf "$dir" >/dev/null 2>&1 || true
      else
        rm -rf "$dir" >/dev/null 2>&1 || true
      fi
    fi
  done
}

pull_service_images() {
  local tag="$1"
  local docker_cli=(docker)
  if [ ${#DOCKER_CMD_PREFIX[@]} -gt 0 ]; then
    docker_cli=("${DOCKER_CMD_PREFIX[@]}" docker)
  fi
  
  # Base images are build-time dependencies for our service images, but they are
  # NOT required to be present locally to run/pull the service images.
  #
  # In the field we've seen cases where base tags (e.g. :stable) are missing or
  # have broken manifests, which previously bricked updates. Make this step
  # best-effort and proceed to pulling the real service images.
  log_info "Attempting to pull base images (best-effort)..."

  local base_images=("mishka-python-base" "mishka-service-base")
  for base_image in "${base_images[@]}"; do
    local full_base="ghcr.io/${REPO_OWNER}/${base_image}:${tag}"
    log_info "Pulling ${full_base} (optional)..."

    local attempt=0
    local max_attempts=2
    local base_success=false
    while [ $attempt -lt $max_attempts ]; do
      attempt=$((attempt + 1))
      local pull_output
      if pull_output=$("${docker_cli[@]}" pull --platform linux/arm64 "${full_base}" 2>&1); then
        log_success "Pulled ${full_base}"
        base_success=true
        break
      fi

      log_warn "Failed to pull ${full_base} (attempt ${attempt}/${max_attempts}): ${pull_output}"
      if [[ "$pull_output" == *"manifest"*"unknown"* ]] || [[ "$pull_output" == *"not found"* ]] || [[ "$pull_output" == *"denied"* ]] || [[ "$pull_output" == *"unauthorized"* ]]; then
        clear_manifest_cache
        ensure_docker_login
      fi
      sleep $((attempt * 2))
    done

    if [ "$base_success" = false ]; then
      log_warn "Continuing without base image ${full_base}; service image pulls will decide success"
    fi
  done

  local failed_images=()
  for image in "${SERVICE_IMAGES[@]}"; do
    local full_image="ghcr.io/${REPO_OWNER}/${image}:${tag}"
    local attempt=0
    local max_attempts=3
    local pull_success=false
    
    while [ $attempt -lt $max_attempts ]; do
      attempt=$((attempt + 1))
      log_info "Pulling ${full_image} (attempt ${attempt}/${max_attempts})"
      
      local pull_output
      if pull_output=$("${docker_cli[@]}" pull --platform linux/arm64 "${full_image}" 2>&1); then
        log_success "Pulled ${full_image}"
        pull_success=true
        break
      fi
      
      log_warn "Failed to pull ${full_image}: ${pull_output}"
      
      # Check for authentication-related errors
      if [[ "$pull_output" == *"manifest"*"unknown"* ]] || [[ "$pull_output" == *"not found"* ]] || [[ "$pull_output" == *"denied"* ]] || [[ "$pull_output" == *"unauthorized"* ]]; then
        log_warn "Authentication or manifest error detected"
        
        # Clear any stale manifest cache
        clear_manifest_cache
        "${docker_cli[@]}" rmi -f "${full_image}" >/dev/null 2>&1 || true
        
        # Re-authenticate
        log_info "Re-authenticating to GHCR..."
        ensure_docker_login
      fi
      
      if [ $attempt -lt $max_attempts ]; then
        local wait_time=$((attempt * 5))
        log_info "Waiting ${wait_time}s before retry..."
        sleep $wait_time
      fi
    done
    
    if [ "$pull_success" = false ]; then
      failed_images+=("$image")
    fi
  done
  
  if [ ${#failed_images[@]} -gt 0 ]; then
    log_error "Failed to pull the following images after all retries:"
    for img in "${failed_images[@]}"; do
      log_error "  - ${img}"
    done
    log_error ""
    log_error "This typically happens when:"
    log_error "  1. Your GitHub token lacks 'read:packages' scope"
    log_error "  2. The images haven't been built yet (run the build workflow)"
    log_error "  3. Network connectivity issues to ghcr.io"
    exit 1
  fi
}

download_raw_file() {
  local dest="$1"
  local repo_path="$2"
  local attempt=0
  local max_attempts=3
  local delay=5
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    if curl -fsSL "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github.v3.raw" \
        "${RAW_BASE}/${repo_path}" -o "$dest"; then
      return 0
    fi
    if [ $attempt -lt $max_attempts ]; then
      log_warn "Download failed for ${repo_path} (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
  done
  return 1
}

api_get() {
  local path="$1"
  curl -fsSL "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github+json" \
    "${API_BASE}${path}"
}

normalize_release_tag() {
  local input="$1"
  if [[ "$input" == v* ]]; then
    echo "$input"
  else
    echo "v${input}"
  fi
}

resolve_release_payload() {
  local selector="$1"
  local response
  if [[ "$selector" == "stable" || "$selector" == "latest" ]]; then
    if ! response=$(api_get "/releases/latest"); then
      log_error "Unable to fetch latest release metadata"
      return 1
    fi
  else
    local candidate="$selector"
    if ! response=$(api_get "/releases/tags/${candidate}"); then
      local normalized
      normalized=$(normalize_release_tag "$selector")
      if ! response=$(api_get "/releases/tags/${normalized}"); then
        log_error "Release '${selector}' not found"
        return 1
      fi
    fi
  fi
  echo "$response"
}

download_compose_assets() {
  download_raw_file "$WORK_DIR/docker-compose.yml" "RPI/docker-compose.yml"
  download_raw_file "$WORK_DIR/docker-compose.ghcr.yml" "RPI/docker-compose.ghcr.yml"
  download_raw_file "$WORK_DIR/docker-compose.production.yml" "RPI/docker-compose.production.yml"
  download_raw_file "$WORK_DIR/docker-compose.linux-hw.yml" "RPI/docker-compose.linux-hw.yml"
  download_raw_file "$WORK_DIR/config_to_env.py" "RPI/config_to_env.py"
  download_raw_file "$WORK_DIR/config.json.template" "RPI/config.json.template"
}

download_service_assets() {
  log_info "Downloading service configuration files"

  local shared_root="$WORK_DIR/services/shared"
  sudo mkdir -p "$shared_root"
  sudo chown -R "$CURRENT_USER":"$CURRENT_USER" "$shared_root"

  # Database configuration and migration assets
  local database_dir="$WORK_DIR/services/shared/database"
  sudo rm -rf "$database_dir"
  mkdir -p "$database_dir"
  sudo chown -R "$CURRENT_USER":"$CURRENT_USER" "$database_dir"

  # Download postgresql.conf to database root (mounted by docker-compose.yml)
  # CRITICAL: Ensure this is downloaded as a FILE, not a directory
  if [ -d "$database_dir/postgresql.conf" ]; then
    log_warn "Removing directory at postgresql.conf path"
    rm -rf "$database_dir/postgresql.conf"
  fi
  
  if ! download_raw_file "$database_dir/postgresql.conf" "RPI/services/shared/database/postgresql.conf"; then
    log_warn "Failed to download postgresql.conf after retries - creating empty fallback (PostgreSQL will use container defaults)"
    touch "$database_dir/postgresql.conf"
  fi

  # Verify it's a regular file (not a directory)
  if [ ! -f "$database_dir/postgresql.conf" ]; then
    log_warn "postgresql.conf is not a regular file - creating empty fallback"
    touch "$database_dir/postgresql.conf"
  fi

  if [ -s "$database_dir/postgresql.conf" ]; then
    log_success "Downloaded postgresql.conf ($(wc -l < "$database_dir/postgresql.conf") lines)"
  else
    log_warn "postgresql.conf is empty - PostgreSQL will use container defaults (SD-card optimizations may be missing)"
  fi

  # Download additional config files to config/ subdirectory (not used by default)
  mkdir -p "$database_dir/config"
  if ! download_raw_file "$database_dir/config/pg_hba.conf" "RPI/services/shared/database/config/pg_hba.conf"; then
    log_warn "Failed to download pg_hba.conf (optional)"
  fi

  if ! download_raw_file "$database_dir/initial_schema.sql" "RPI/services/shared/database/initial_schema.sql"; then
    log_error "Failed to download initial_schema.sql"
    exit 1
  fi

  if ! download_raw_file "$database_dir/schema_migrations.sql" "RPI/services/shared/database/schema_migrations.sql"; then
    log_error "Failed to download schema_migrations.sql"
    exit 1
  fi

  # Download OTA update scripts
  local ota_dir="$WORK_DIR/services/ota"
  sudo mkdir -p "$ota_dir"
  sudo chown -R "$CURRENT_USER":"$CURRENT_USER" "$ota_dir"
  if ! download_raw_file "$ota_dir/ota_update.sh" "RPI/services/ota/ota_update.sh"; then
    log_warn "Failed to download ota_update.sh"
  else
    chmod +x "$ota_dir/ota_update.sh"
  fi

  # Download systemd service files for OTA watcher
  local systemd_dir="$WORK_DIR/Deployment_Doc/systemd"
  sudo mkdir -p "$systemd_dir"
  sudo chown -R "$CURRENT_USER":"$CURRENT_USER" "$systemd_dir"
  if ! download_raw_file "$systemd_dir/ota-update-watcher.sh" "Deployment_Doc/systemd/ota-update-watcher.sh"; then
    log_warn "Failed to download ota-update-watcher.sh"
  else
    chmod +x "$systemd_dir/ota-update-watcher.sh"
  fi
  
  if ! download_raw_file "$systemd_dir/mishka-ota-updater.service" "Deployment_Doc/systemd/mishka-ota-updater.service"; then
    log_warn "Failed to download mishka-ota-updater.service"
  fi

  # Mosquitto config
  local mosquitto_dir="$WORK_DIR/services/shared/mosquitto"
  sudo rm -rf "$mosquitto_dir"
  mkdir -p "$mosquitto_dir/config" "$mosquitto_dir/data" "$mosquitto_dir/log"
  sudo chown -R "$CURRENT_USER":"$CURRENT_USER" "$mosquitto_dir"
  
  if ! download_raw_file "$mosquitto_dir/config/mosquitto.conf" "RPI/services/shared/mosquitto/config/mosquitto.conf"; then
    log_warn "Failed to download mosquitto.conf, creating inline"
    create_mosquitto_conf
  fi
}

create_mosquitto_conf() {
  cat > "$WORK_DIR/services/shared/mosquitto/config/mosquitto.conf" << 'CONFEOF'
listener 1883
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
log_dest stdout
log_type all
connection_messages true
CONFEOF
}

ensure_config_file() {
  if [ ! -f "$CONFIG_DIR/config.json" ]; then
    log_info "Initializing config.json from template"
    sudo cp "$WORK_DIR/config.json.template" "$CONFIG_DIR/config.json"
    sudo chown root:"$USER" "$CONFIG_DIR/config.json"
    sudo chmod 660 "$CONFIG_DIR/config.json"
  fi
  ln -sf "$CONFIG_DIR/config.json" "$WORK_DIR/config.json"
}

update_config_metadata() {
  local token="$1"
  local release_tag="$2"
  local channel="$3"
  sudo python3 - "$CONFIG_DIR" "$token" "$release_tag" "$channel" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

config_dir = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].strip() else '/opt/mishka'
token = sys.argv[2].strip() if len(sys.argv) > 2 else ''
release_tag = sys.argv[3].strip() if len(sys.argv) > 3 else ''
channel = sys.argv[4].strip() if len(sys.argv) > 4 else ''

config_path = os.path.join(config_dir, 'config.json')

with open(config_path, 'r', encoding='utf-8') as fh:
  config = json.load(fh)

github = config.setdefault('github', {})
if token:
  github['token'] = token

ota = config.setdefault('system_ota', {})
if release_tag:
  previous = ota.get('current_version')
  if previous and previous != release_tag:
    ota['previous_version'] = previous
  ota['current_version'] = release_tag
  ota['last_update'] = datetime.now(timezone.utc).isoformat()
if channel:
  ota['channel'] = channel

with open(config_path, 'w', encoding='utf-8') as fh:
  json.dump(config, fh, indent=2)
  fh.write('\n')
PY
}

generate_env_file() {
  python3 "$WORK_DIR/config_to_env.py" "$CONFIG_DIR/config.json" --output "$WORK_DIR/.env"
}

fetch_systemd_assets() {
  download_raw_file "$WORK_DIR/systemd/mishka-hostname-detect.sh" "Deployment_Doc/systemd/mishka-hostname-detect.sh"
  download_raw_file "$WORK_DIR/systemd/mishka-hostname.service" "Deployment_Doc/systemd/mishka-hostname.service"
  download_raw_file "$WORK_DIR/systemd/mqtt-timeline-alias.sh" "Deployment_Doc/systemd/mqtt-timeline-alias.sh"
  download_raw_file "$WORK_DIR/systemd/mqtt-timeline-alias.service" "Deployment_Doc/systemd/mqtt-timeline-alias.service"
  download_raw_file "$WORK_DIR/systemd/ota-update-watcher.sh" "Deployment_Doc/systemd/ota-update-watcher.sh"
  download_raw_file "$WORK_DIR/systemd/mishka-ota-updater.service" "Deployment_Doc/systemd/mishka-ota-updater.service"
}

install_systemd_units() {
  sudo mkdir -p /usr/local/lib/mishka
  sudo cp "$WORK_DIR/systemd/mishka-hostname-detect.sh" /usr/local/lib/mishka/
  sudo cp "$WORK_DIR/systemd/mqtt-timeline-alias.sh" /usr/local/lib/mishka/
  sudo chmod 755 /usr/local/lib/mishka/mishka-hostname-detect.sh
  sudo chmod 755 /usr/local/lib/mishka/mqtt-timeline-alias.sh
  sudo cp "$WORK_DIR/systemd/mishka-hostname.service" /etc/systemd/system/
  sudo cp "$WORK_DIR/systemd/mqtt-timeline-alias.service" /etc/systemd/system/
  sudo chmod 644 /etc/systemd/system/mishka-hostname.service
  sudo chmod 644 /etc/systemd/system/mqtt-timeline-alias.service
  
  # Install OTA update watcher service
  if [ -f "$WORK_DIR/systemd/ota-update-watcher.sh" ]; then
    sudo mkdir -p /opt/mishka/bin
    sudo cp "$WORK_DIR/systemd/ota-update-watcher.sh" /opt/mishka/bin/
    sudo chmod +x /opt/mishka/bin/ota-update-watcher.sh
    log_success "OTA watcher script installed"
  fi
  if [ -f "$WORK_DIR/systemd/mishka-ota-updater.service" ]; then
    sudo cp "$WORK_DIR/systemd/mishka-ota-updater.service" /etc/systemd/system/
    sudo chmod 644 /etc/systemd/system/mishka-ota-updater.service
    log_success "OTA watcher service installed"
  fi
  
  sudo systemctl daemon-reload
  sudo systemctl enable --now mishka-hostname.service
  sudo systemctl enable --now mqtt-timeline-alias.service
  
  # Enable OTA watcher if installed
  if [ -f /etc/systemd/system/mishka-ota-updater.service ]; then
    sudo systemctl enable --now mishka-ota-updater.service
    log_success "OTA watcher service enabled and started"
  fi
  
  sudo /usr/local/lib/mishka/mishka-hostname-detect.sh || true
  sudo systemctl restart mqtt-timeline-alias.service || true
}

download_firmware_assets() {
  local release_json="$1"
  local release_tag="$2"
  if [ -z "$release_tag" ]; then
    log_warn "No release tag provided; skipping firmware download"
    return
  fi
  local target_dir="$FIRMWARE_ROOT/$release_tag"
  mkdir -p "$target_dir"
  rm -f "$target_dir"/*
  local assets
  assets=$(echo "$release_json" | jq -c '.assets[]?')
  if [ -z "$assets" ]; then
    log_warn "Release ${release_tag} has no downloadable assets"
  else
    while IFS= read -r asset; do
      local name url
      name=$(echo "$asset" | jq -r '.name')
      url=$(echo "$asset" | jq -r '.url')
      if [ -z "$name" ] || [ "$name" = "null" ]; then
        continue
      fi
      log_info "Downloading firmware asset: ${name}"
      curl -fsSL "${AUTH_HEADER[@]}" -H "Accept: application/octet-stream" \
        "$url" -o "$target_dir/$name"
    done <<< "$assets"
  fi
  if [ -n "$release_json" ]; then
    echo "$release_json" | jq '.' >"$target_dir/release.json"
  fi
}

ensure_docker_login() {
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    log_error "No GitHub token available for GHCR login - private packages require authentication"
    log_error "Pass a valid token with read:packages scope as the first argument"
    exit 1
  fi
  
  # Validate token has minimum required length (sanity check)
  if [ ${#GITHUB_TOKEN} -lt 20 ]; then
    log_error "GitHub token appears invalid (too short)"
    exit 1
  fi
  
  local docker_cmd=(docker)
  if [ ${#DOCKER_CMD_PREFIX[@]} -gt 0 ]; then
    docker_cmd=("${DOCKER_CMD_PREFIX[@]}" docker)
  fi
  
  log_info "Authenticating to ghcr.io as '${REPO_OWNER}'..."
  local login_output
  if login_output=$(echo "$GITHUB_TOKEN" | "${docker_cmd[@]}" login ghcr.io -u "$REPO_OWNER" --password-stdin 2>&1); then
    log_success "Authenticated against ghcr.io"
    return 0
  fi
  
  log_warn "GHCR login failed: ${login_output}"
  
  # Try with sudo if not already using it
  if [ ${#DOCKER_CMD_PREFIX[@]} -eq 0 ]; then
    log_info "Retrying GHCR login with sudo..."
    DOCKER_CMD_PREFIX=(sudo)
    if login_output=$(echo "$GITHUB_TOKEN" | sudo docker login ghcr.io -u "$REPO_OWNER" --password-stdin 2>&1); then
      log_success "Authenticated against ghcr.io (via sudo)"
      return 0
    fi
    log_warn "GHCR login with sudo also failed: ${login_output}"
  fi
  
  # Check if we have cached credentials that might work
  local config_file="$HOME/.docker/config.json"
  if [ -f "$config_file" ] && grep -q 'ghcr.io' "$config_file" 2>/dev/null; then
    log_warn "GHCR fresh login failed but cached credentials exist - will attempt pulls"
    log_warn "If pulls fail with 'manifest unknown', your token likely lacks read:packages scope"
    return 0
  fi
  
  log_error "GHCR authentication failed and no cached credentials available"
  log_error "Ensure your token has 'read:packages' scope for private package access"
  exit 1
}

select_compose_bin() {
  if "${DOCKER_CMD_PREFIX[@]}" docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN=("${DOCKER_CMD_PREFIX[@]}" docker compose)
    return
  fi
  if "${DOCKER_CMD_PREFIX[@]}" docker-compose version >/dev/null 2>&1; then
    COMPOSE_BIN=("${DOCKER_CMD_PREFIX[@]}" docker-compose)
    return
  fi
  log_error "Docker Compose is not available"
  exit 1
}

compose_pull_and_up() {
  local image_tag="$1"
  export VERSION="$image_tag"
  select_compose_bin
  local compose_args=(-f "$WORK_DIR/docker-compose.yml" -f "$WORK_DIR/docker-compose.ghcr.yml" -f "$WORK_DIR/docker-compose.production.yml")
  if [ "$(uname -s)" = "Linux" ]; then
    compose_args+=(-f "$WORK_DIR/docker-compose.linux-hw.yml" --profile linux-hw)
  fi
  
  local docker_cli=(docker)
  if [ ${#DOCKER_CMD_PREFIX[@]} -gt 0 ]; then
    docker_cli=("${DOCKER_CMD_PREFIX[@]}" docker)
  fi

  # IMPORTANT: Do not take the system down before we have images.
  # Updates should be resilient; if registry pulls fail, the current running
  # containers should keep running.
  clear_manifest_cache
  
  pull_service_images "$image_tag"
  log_success "All GHCR images pulled successfully"
  
  # Validate postgresql.conf before starting - prevent directory mount issues
  local pg_conf="$WORK_DIR/services/shared/database/postgresql.conf"
  if [ -e "$pg_conf" ]; then
    if [ -d "$pg_conf" ]; then
      log_warn "postgresql.conf is a directory (should be a file)! Removing..."
      rm -rf "$pg_conf"
      touch "$pg_conf"  # Create empty file so mount doesn't fail
      log_warn "Created empty postgresql.conf - PostgreSQL will use defaults"
    elif [ ! -s "$pg_conf" ]; then
      log_warn "postgresql.conf is empty - PostgreSQL will use defaults"
    elif ! grep -q "^[^#]" "$pg_conf" 2>/dev/null; then
      log_warn "postgresql.conf contains no uncommented lines - PostgreSQL will use defaults"
    else
      log_success "postgresql.conf validated ($(grep -c "^[^#]" "$pg_conf") active settings)"
    fi
  else
    log_warn "postgresql.conf not found - creating empty file (PostgreSQL will use defaults)"
    mkdir -p "$(dirname "$pg_conf")"
    touch "$pg_conf"
  fi
  
  # Retry logic for docker compose up (handles transient network/TLS errors)
  local max_attempts=5
  local attempt=0
  local success=false
  
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    
    if [ $attempt -gt 1 ]; then
      log_warn "Compose up failed (attempt $((attempt - 1))/$max_attempts), retrying after cleanup..."
      # Clear Docker's layer and manifest cache to recover from TLS corruption
      clear_manifest_cache
      "${docker_cli[@]}" system prune -f >/dev/null 2>&1 || true
      sleep $((attempt * 3))
    else
      log_info "Starting/updating services (attempt ${attempt}/${max_attempts})"
    fi
    
    local compose_output
    if compose_output=$(cd "$WORK_DIR" && "${COMPOSE_BIN[@]}" "${compose_args[@]}" up -d --no-build --remove-orphans 2>&1); then
      success=true
      break
    fi
    
    # Check if this is a permission issue
    if [[ "$compose_output" == *"permission denied"* ]] || [[ "$compose_output" == *"Cannot connect to the Docker daemon"* ]]; then
      if [ ${#DOCKER_CMD_PREFIX[@]} -eq 0 ]; then
        log_warn "Permission issue detected; switching to sudo"
        DOCKER_CMD_PREFIX=(sudo)
        docker_cli=("${DOCKER_CMD_PREFIX[@]}" docker)
        select_compose_bin
        attempt=$((attempt - 1))  # Don't count this as a real attempt
        continue
      fi
    fi
    
    log_warn "Attempt ${attempt}/${max_attempts} failed: ${compose_output}"
  done
  
  if [ "$success" = false ]; then
    log_error "Docker compose up failed after ${max_attempts} attempts"
    exit 1
  fi
  
  log_success "Services started successfully"
}

update_service_versions() {
  local release_tag="$1"
  log_info "Recording deployed version ${release_tag}"
  sudo python3 - "$CONFIG_DIR" "$release_tag" <<'PY'
import json
import os
import sys
from datetime import datetime

config_dir = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].strip() else '/opt/mishka'
release_tag = sys.argv[2].strip() if len(sys.argv) > 2 else ''
if not release_tag:
  raise SystemExit(0)

config_path = os.path.join(config_dir, 'config.json')

with open(config_path, 'r', encoding='utf-8') as fh:
  config = json.load(fh)

ota = config.setdefault('system_ota', {})
previous = ota.get('current_version')
if previous and previous != release_tag:
  ota['previous_version'] = previous
ota['current_version'] = release_tag
ota['last_update'] = datetime.utcnow().isoformat() + 'Z'

with open(config_path, 'w', encoding='utf-8') as fh:
  json.dump(config, fh, indent=2)
  fh.write('\n')
PY
}

install_system_services() {
  # Install systemd units
  install_systemd_units

  sudo systemctl daemon-reload
  sudo systemctl enable hostname-detect.service
  sudo systemctl restart hostname-detect.service
  log_success "Hostname auto-detect service installed"

  # Install OTA update watcher service
  log_info "Installing OTA update watcher service..."
  sudo mkdir -p /opt/mishka/bin
  if [ -f "$WORK_DIR/Deployment_Doc/systemd/ota-update-watcher.sh" ]; then
      sudo cp "$WORK_DIR/Deployment_Doc/systemd/ota-update-watcher.sh" /opt/mishka/bin/
      sudo chmod +x /opt/mishka/bin/ota-update-watcher.sh
      log_success "OTA watcher script installed"
  fi
  if [ -f "$WORK_DIR/Deployment_Doc/systemd/mishka-ota-updater.service" ]; then
      sudo cp "$WORK_DIR/Deployment_Doc/systemd/mishka-ota-updater.service" /etc/systemd/system/
      sudo systemctl daemon-reload
      sudo systemctl enable mishka-ota-updater.service
      sudo systemctl start mishka-ota-updater.service
      log_success "OTA update watcher service started"
  fi
  
  # Install OTA update script
  if [ -f "$WORK_DIR/services/ota/ota_update.sh" ]; then
      sudo cp "$WORK_DIR/services/ota/ota_update.sh" /opt/mishka/bin/
      sudo chmod +x /opt/mishka/bin/ota_update.sh
      log_success "OTA update script installed"
  fi
}

# EOF
