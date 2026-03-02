#!/bin/bash
# Update script for applying the latest (or specified) MISHKA container release.

set -euo pipefail

TARGET_SELECTOR="${1:-stable}"

export REPO_OWNER="lisovog"
export REPO_NAME="P_PAUK"
# NOTE: Deployments must download compose + DB assets from the SAME ref as the
# running images. Historically, pulling these from 'main' caused schema drift
# (e.g. missing new migrations) when production runs from the RPI/stable tag.
#
# We start with a tag-like ref when possible; after resolving the release tag we
# pin downloads to that tag.
export REPO_REF="stable"
export RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"
export API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
export CONFIG_DIR="/opt/mishka"
export WORK_DIR="${HOME}/mishka"
export FIRMWARE_ROOT="${CONFIG_DIR}/firmware/esp32"

if [ ! -f "${CONFIG_DIR}/config.json" ]; then
  echo "Config not found at ${CONFIG_DIR}/config.json. Run install-new.sh first." >&2
  exit 1
fi

export GITHUB_TOKEN="$(python3 <<'PY'
import json
from pathlib import Path

cfg_path = Path('/opt/mishka/config.json')
try:
  config = json.loads(cfg_path.read_text())
except Exception:
  config = {}

token = ''
stack = [config]
while stack:
  item = stack.pop()
  if isinstance(item, dict):
    if 'token' in item and isinstance(item['token'], str) and item['token'].strip():
      token = item['token'].strip()
      break
    stack.extend(item.values())
  elif isinstance(item, list):
    stack.extend(item)

print(token)
PY
)"

if [ -z "$GITHUB_TOKEN" ]; then
  echo "GitHub token not present in config. Re-run install-new.sh with a token." >&2
  exit 1
fi

load_common_helpers() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${script_dir}/lib/common.sh" ]; then
    # shellcheck disable=SC1090
    source "${script_dir}/lib/common.sh"
  else
    local tmp
    tmp="$(mktemp)"
    curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" \
      "${RAW_BASE}/deploy/lib/common.sh" -o "$tmp"
    # shellcheck disable=SC1090
    source "$tmp"
    rm -f "$tmp"
  fi
}

load_common_helpers
refresh_auth_header

log_info "Starting update (selector='${TARGET_SELECTOR}')"

ensure_packages curl jq python3 python3-pip avahi-daemon avahi-utils libnss-mdns ca-certificates
install_docker_if_needed
prepare_directories

# Resolve release early so we can pin raw downloads to the correct ref/tag.
# For 'stable', allow container-only updates even if a GitHub Release is missing.
if [ "$TARGET_SELECTOR" = "stable" ]; then
  release_payload="$(resolve_release_payload "$TARGET_SELECTOR" 2>/dev/null || echo '{}')"
  release_tag="$(echo "$release_payload" | jq -r '.tag_name // empty')"
  if [ -z "$release_tag" ] || [ "$release_tag" = "null" ]; then
    log_warn "No GitHub Release found for 'stable' - continuing with container updates only"
    release_tag="stable"
    release_payload='{}'
  fi
else
  release_payload="$(resolve_release_payload "$TARGET_SELECTOR")"
  release_tag="$(echo "$release_payload" | jq -r '.tag_name')"
  if [ -z "$release_tag" ] || [ "$release_tag" = "null" ]; then
    log_error "Failed to resolve release tag for '${TARGET_SELECTOR}'"
    exit 1
  fi
fi

# Pin raw downloads to the resolved tag (or channel tag when explicitly requested).
case "$TARGET_SELECTOR" in
  stable|beta|alpha|dev)
    REPO_REF="$TARGET_SELECTOR"
    ;;
  *)
    REPO_REF="$release_tag"
    ;;
esac
export REPO_REF
export RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"

download_compose_assets
download_service_assets
ensure_config_file

channel="$TARGET_SELECTOR"
case "$TARGET_SELECTOR" in
  stable)
    image_tag="stable"
    ;;
  latest)
    image_tag="${release_tag#v}"
    ;;
  *)
    image_tag="${TARGET_SELECTOR#v}"
    ;;
esac

log_info "Preparing deployment for container tag '${image_tag}' (firmware ${release_tag})"
update_config_metadata "$GITHUB_TOKEN" "$release_tag" "$channel"
generate_env_file

fetch_systemd_assets
install_systemd_units

# --- Ensure runtime compose contains DB migrations and host reboot permissions ---
if [ -f "${WORK_DIR}/docker-compose.yml" ]; then
  # Add schema directory mount to the TimescaleDB service (idempotent)
  if ! grep -q "/docker-entrypoint-initdb.d" "${WORK_DIR}/docker-compose.yml"; then
    sed -i '/timescale_database_data:\/var\/lib\/postgresql\/data/a\      - .\/services\/shared\/database:\/docker-entrypoint-initdb.d:ro' "${WORK_DIR}/docker-compose.yml" || true
  fi
  # Grant web-app host access for hardware reboot (idempotent)
  if ! grep -q "privileged: true" "${WORK_DIR}/docker-compose.yml"; then
    sed -i '/container_name: Web-Application-UI/a\    privileged: true\n    pid: "host"\n    volumes:\n      - /run/systemd:/run/systemd:ro\n      - /var/run/dbus:/var/run/dbus' "${WORK_DIR}/docker-compose.yml" || true
  fi
fi
# ------------------------------------------------------------------------------

download_firmware_assets "$release_payload" "$release_tag"
ensure_docker_login

# Pull all images first (not starting services yet)
pull_service_images "$image_tag"
log_success "All GHCR images pulled successfully"

# Set up docker command with sudo if needed
docker_cli=(docker)
if [ ${#DOCKER_CMD_PREFIX[@]} -gt 0 ]; then
  docker_cli=("${DOCKER_CMD_PREFIX[@]}" docker)
fi

# Start ONLY the database service (without application services)
log_info "Starting database service..."
select_compose_bin
compose_args=(-f "$WORK_DIR/docker-compose.yml" -f "$WORK_DIR/docker-compose.ghcr.yml" -f "$WORK_DIR/docker-compose.production.yml")
if [ "$(uname -s)" = "Linux" ]; then
  compose_args+=(-f "$WORK_DIR/docker-compose.linux-hw.yml")
fi

# Retry logic for database startup (handles TLS errors during TimescaleDB image pull)
max_attempts=3
attempt=0
db_started=false
while [ $attempt -lt $max_attempts ]; do
  attempt=$((attempt + 1))
  
  if [ $attempt -gt 1 ]; then
    log_warn "Database startup failed (attempt $((attempt - 1))/${max_attempts}), retrying..."
    clear_manifest_cache
    "${docker_cli[@]}" system prune -f >/dev/null 2>&1 || true
    sleep 5
  fi
  
  log_info "Starting database service (attempt ${attempt}/${max_attempts})..."
  if cd "$WORK_DIR" && "${COMPOSE_BIN[@]}" "${compose_args[@]}" up -d timescale-database --no-build --remove-orphans 2>&1 | tee /tmp/db_start.log; then
    db_started=true
    break
  fi
  
  log_warn "Database startup attempt ${attempt} failed"
done

if [ "$db_started" = false ]; then
  log_error "Failed to start database service after ${max_attempts} attempts"
  cat /tmp/db_start.log 2>/dev/null || true
  exit 1
fi

log_success "Database service started"

# Run database migrations BEFORE starting application services
log_info "Running database migrations..."

log_info "Waiting for database to be ready..."
db_wait_attempts=0
max_db_wait=60  # 2 minutes max
until "${docker_cli[@]}" exec Database-Timescale pg_isready -U bleuser -d bledb > /dev/null 2>&1; do
  db_wait_attempts=$((db_wait_attempts + 1))
  if [ $db_wait_attempts -ge $max_db_wait ]; then
    log_error "Database failed to become ready after 2 minutes"
    "${docker_cli[@]}" logs Database-Timescale --tail=50
    exit 1
  fi
  sleep 2
done
log_success "Database is ready"

# Verify TimescaleDB extension is loaded
log_info "Verifying TimescaleDB extension..."
if ! "${docker_cli[@]}" exec Database-Timescale psql -U bleuser -d bledb -tAc "SELECT extname FROM pg_extension WHERE extname='timescaledb';" | grep -q "timescaledb"; then
  log_warn "TimescaleDB extension not loaded, attempting to load..."
  if ! "${docker_cli[@]}" exec Database-Timescale psql -U bleuser -d bledb -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" 2>&1; then
    log_error "Failed to load TimescaleDB extension. Check that postgresql.conf has: shared_preload_libraries = 'timescaledb'"
    "${docker_cli[@]}" logs Database-Timescale --tail=50
    exit 1
  fi
fi
log_success "TimescaleDB extension loaded"

# Verify database is listening on all interfaces (required for host network mode)
log_info "Verifying database network configuration..."
listen_addr=$("${docker_cli[@]}" exec Database-Timescale psql -U bleuser -d bledb -tAc "SHOW listen_addresses;")
if [ "$listen_addr" != "0.0.0.0" ] && [ "$listen_addr" != "*" ]; then
  log_warn "Database listening on '$listen_addr' (should be '0.0.0.0' for host network compatibility)"
  log_info "Updating listen_addresses to 0.0.0.0..."
  "${docker_cli[@]}" exec Database-Timescale psql -U bleuser -d bledb -c "ALTER SYSTEM SET listen_addresses = '0.0.0.0';"
  log_info "Restarting database to apply network configuration..."
  "${docker_cli[@]}" restart Database-Timescale
  sleep 10
  # Wait for database again after restart
  until "${docker_cli[@]}" exec Database-Timescale pg_isready -U bleuser -d bledb > /dev/null 2>&1; do
    sleep 2
  done
fi
log_success "Database network configuration verified"

# Run initial schema (for new tables added in updates)
if "${docker_cli[@]}" exec Database-Timescale test -f /docker-entrypoint-initdb.d/initial_schema.sql; then
  log_info "Running initial schema (for any new tables)..."
  if ! "${docker_cli[@]}" exec Database-Timescale psql -v ON_ERROR_STOP=1 -U bleuser -d bledb -f /docker-entrypoint-initdb.d/initial_schema.sql 2>&1 | grep -v "already exists" | grep -v "ERROR.*relation.*already exists"; then
    log_info "Initial schema already applied (this is normal on updates)"
  fi
fi

# Run migrations
if ! "${docker_cli[@]}" exec Database-Timescale test -f /docker-entrypoint-initdb.d/schema_migrations.sql; then
  log_error "schema_migrations.sql not found in Database-Timescale container"
  exit 1
fi
log_info "Running schema migrations..."
if ! "${docker_cli[@]}" exec Database-Timescale psql -v ON_ERROR_STOP=1 -U bleuser -d bledb -f /docker-entrypoint-initdb.d/schema_migrations.sql; then
  log_error "Migrations failed"
  "${docker_cli[@]}" logs Database-Timescale --tail=50
  exit 1
fi
log_success "Migrations complete"

# Verify critical tables exist
log_info "Verifying database schema..."
required_tables=("mqtt_devices" "received_packets" "system_events")
for table in "${required_tables[@]}"; do
  if ! "${docker_cli[@]}" exec Database-Timescale psql -U bleuser -d bledb -tAc "SELECT to_regclass('public.$table');" | grep -q "$table"; then
    log_error "Required table '$table' not found in database"
    exit 1
  fi
done
log_success "Database schema validated"

# Now start all application services (database already running, migrations complete)
log_info "Starting all services..."
cd "$WORK_DIR" && "${COMPOSE_BIN[@]}" "${compose_args[@]}" up -d --no-build --remove-orphans
if [ "$(uname -s)" = "Linux" ]; then
  cd "$WORK_DIR" && "${COMPOSE_BIN[@]}" "${compose_args[@]}" --profile linux-hw up -d --no-build --remove-orphans
fi
log_success "All services started successfully"

# Final service health validation
log_info "Validating service health..."
unhealthy_services=()
restarting_services=()

# Wait a few seconds for services to stabilize
sleep 5

# Check for unhealthy or restarting containers
while IFS= read -r line; do
  container_name=$(echo "$line" | awk '{print $1}')
  status=$(echo "$line" | awk '{print $2" "$3" "$4" "$5}')
  
  if [[ "$status" == *"Restarting"* ]]; then
    restarting_services+=("$container_name")
  elif [[ "$status" == *"unhealthy"* ]]; then
    unhealthy_services+=("$container_name")
  fi
done < <("${docker_cli[@]}" ps --format "{{.Names}} {{.Status}}" 2>/dev/null || true)

if [ ${#restarting_services[@]} -gt 0 ]; then
  log_error "The following services are crash-looping:"
  for service in "${restarting_services[@]}"; do
    log_error "  - $service"
    "${docker_cli[@]}" logs "$service" --tail=20 2>&1 | sed 's/^/    /'
  done
  log_error ""
  log_error "Update completed but some services have issues."
  log_error "Check logs with: docker logs <service-name>"
  exit 1
fi

if [ ${#unhealthy_services[@]} -gt 0 ]; then
  log_warn "The following services are unhealthy (may recover):"
  for service in "${unhealthy_services[@]}"; do
    log_warn "  - $service"
  done
fi

log_success "All services are running"

log_success "Update complete"
log_info "Running version: ${release_tag} (channel ${channel})"
