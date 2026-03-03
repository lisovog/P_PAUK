#!/bin/bash
# MISHKA OTA Update Watcher
# Watches for trigger file and executes updates on the host
# This runs as a systemd service outside of Docker containers

set -euo pipefail

TRIGGER_FILE="${TRIGGER_FILE:-/tmp/mishka_ota_trigger.json}"
LOCK_FILE="${LOCK_FILE:-/tmp/mishka_ota_update.lock}"
PROJECT_ROOT="${PROJECT_ROOT:-/home/timeline/mishka}"
PROGRESS_FILE="/tmp/mishka_update_progress.json"
LOG_FILE="/tmp/mishka_ota_update.log"

# Color codes for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}" | tee -a "$LOG_FILE"
}

log_info() {
    log "${BLUE}INFO${NC}" "$@"
}

log_success() {
    log "${GREEN}SUCCESS${NC}" "$@"
}

log_warn() {
    log "${YELLOW}WARN${NC}" "$@"
}

log_error() {
    log "${RED}ERROR${NC}" "$@"
}

update_progress() {
    local status="$1"
    local progress="$2"
    local step="$3"
    
    cat > "$PROGRESS_FILE" <<EOF
{
  "status": "$status",
  "progress": $progress,
  "current_step": "$step",
  "timestamp": "$(date -Iseconds)"
}
EOF
}

execute_update() {
    local target_version="$1"
    local github_token="$2"
    
    log_info "========================================="
    log_info "Starting OTA update to version: $target_version"
    log_info "========================================="
    
    update_progress "starting" 0 "Preparing update..."
    
    # Check if update script exists
    local update_script="$PROJECT_ROOT/services/ota/ota_update.sh"
    if [[ ! -f "$update_script" ]]; then
        log_error "Update script not found: $update_script"
        update_progress "failed" 0 "Update script not found"
        return 1
    fi
    
    if [[ ! -x "$update_script" ]]; then
        log_info "Making update script executable..."
        chmod +x "$update_script"
    fi
    
    # Export environment variables for the update script
    export PROJECT_ROOT="$PROJECT_ROOT"
    export VERSION="$target_version"
    export GITHUB_TOKEN="$github_token"
    
    log_info "Executing update script..."
    update_progress "running" 20 "Executing update script..."
    
    # Run the update script and capture output
    if "$update_script" "$target_version" >> "$LOG_FILE" 2>&1; then
        log_success "Update completed successfully!"
        update_progress "completed" 100 "Update completed successfully"
        return 0
    else
        local exit_code=$?
        log_error "Update failed with exit code: $exit_code"
        update_progress "failed" 0 "Update script failed (exit code: $exit_code)"
        return 1
    fi
}

# Main watch loop
log_info "MISHKA OTA Update Watcher started"
log_info "Watching for trigger file: $TRIGGER_FILE"
log_info "Project root: $PROJECT_ROOT"

while true; do
    if [[ -f "$TRIGGER_FILE" ]]; then
        log_info "Trigger file detected!"
        
        # Check for existing update in progress
        if [[ -f "$LOCK_FILE" ]]; then
            lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
            if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                log_warn "Update already in progress (PID: $lock_pid)"
                sleep 5
                continue
            else
                log_warn "Stale lock file found, removing..."
                rm -f "$LOCK_FILE"
            fi
        fi
        
        # Read trigger file
        if ! trigger_data=$(cat "$TRIGGER_FILE" 2>/dev/null); then
            log_error "Failed to read trigger file"
            rm -f "$TRIGGER_FILE"
            sleep 5
            continue
        fi
        
        # Parse JSON (simple extraction)
        target_version=$(echo "$trigger_data" | grep -oP '"target_version"\s*:\s*"\K[^"]+' || echo "")
        github_token=$(echo "$trigger_data" | grep -oP '"github_token"\s*:\s*"\K[^"]+' || echo "")
        
        if [[ -z "$target_version" ]]; then
            log_error "No target version specified in trigger file"
            rm -f "$TRIGGER_FILE"
            sleep 5
            continue
        fi
        
        # Remove trigger file before starting (prevents re-triggering)
        rm -f "$TRIGGER_FILE"
        
        # Create lock file
        echo $$ > "$LOCK_FILE"
        
        # Execute update
        if execute_update "$target_version" "$github_token"; then
            log_success "========================================="
            log_success "Update process completed successfully"
            log_success "========================================="
        else
            log_error "========================================="
            log_error "Update process failed"
            log_error "Check logs at: $LOG_FILE"
            log_error "========================================="
        fi
        
        # Clean up lock file
        rm -f "$LOCK_FILE"
    fi
    
    # Sleep for 2 seconds before checking again
    sleep 2
done
