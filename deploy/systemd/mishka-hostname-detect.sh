#!/bin/bash
# PAUK Hostname Auto-Detect Service
# Runs on every boot to ensure hostname and config metadata match the hardware identifiers.

set -euo pipefail

LOG_FILE="/var/log/mishka-hostname.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== PAUK Hostname Auto-Detect Started ==="

BLUETOOTH_MAC=""
if command -v bluetoothctl >/dev/null 2>&1; then
  BLUETOOTH_MAC="$(bluetoothctl show 2>/dev/null | awk '/Controller/ {print $2; exit}' || true)"
  log "Tried bluetoothctl: ${BLUETOOTH_MAC}"
fi
if [ -z "$BLUETOOTH_MAC" ] && [ -f /sys/class/bluetooth/hci0/address ]; then
  BLUETOOTH_MAC="$(cat /sys/class/bluetooth/hci0/address)"
  log "Tried sysfs hci0: ${BLUETOOTH_MAC}"
fi
if [ -z "$BLUETOOTH_MAC" ] && [ -f /sys/class/net/wlan0/address ]; then
  BLUETOOTH_MAC="$(cat /sys/class/net/wlan0/address)"
  log "Fallback to wlan0: ${BLUETOOTH_MAC}"
fi

if [ -z "$BLUETOOTH_MAC" ]; then
  log "ERROR: Could not detect MAC address"
  exit 1
fi

BLUETOOTH_MAC="${BLUETOOTH_MAC^^}"

WIFI_MAC=""
for iface_path in /sys/class/net/*; do
  iface_name="$(basename "$iface_path")"
  if [[ "$iface_name" == wl* ]] && [ -f "$iface_path/address" ]; then
    WIFI_MAC="$(tr '[:lower:]' '[:upper:]' <"$iface_path/address")"
    log "Detected WiFi interface ${iface_name} MAC: ${WIFI_MAC}"
    break
  fi
done
if [ -z "$WIFI_MAC" ] && [ -f /sys/class/net/eth0/address ]; then
  WIFI_MAC="$(tr '[:lower:]' '[:upper:]' </sys/class/net/eth0/address)"
  log "Fallback to eth0 MAC: ${WIFI_MAC}"
fi
if [ -z "$WIFI_MAC" ]; then
  WIFI_MAC="UNKNOWN"
  log "WiFi MAC address not detected"
fi

DEVICE_SERIAL="$(awk -F ': ' '/^Serial/ {print $2}' /proc/cpuinfo | tail -n1 | tr -d '[:space:]')"
if [ -z "$DEVICE_SERIAL" ] && [ -f /sys/firmware/devicetree/base/serial-number ]; then
  DEVICE_SERIAL="$(python3 <<'PY'
from pathlib import Path
try:
    print(Path('/sys/firmware/devicetree/base/serial-number').read_text(errors='ignore').strip())
except Exception:
    pass
PY
  )"
fi
if [ -n "$DEVICE_SERIAL" ]; then
  DEVICE_SERIAL="${DEVICE_SERIAL^^}"
  log "Detected device serial: ${DEVICE_SERIAL}"
else
  DEVICE_SERIAL="UNKNOWN"
  log "WARNING: Could not detect device serial"
fi

CLEAN_MAC="${WIFI_MAC//:/}"
HOST_SUFFIX="${CLEAN_MAC: -6}"
HOSTNAME_VALUE="PAUK-${HOST_SUFFIX^^}"
CURRENT_HOSTNAME="$(hostname)"

if [ "$CURRENT_HOSTNAME" != "$HOSTNAME_VALUE" ]; then
  log "Updating hostname from ${CURRENT_HOSTNAME} to ${HOSTNAME_VALUE}"
  echo "$HOSTNAME_VALUE" | sudo tee /etc/hostname >/dev/null
  sudo sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME_VALUE}/g" /etc/hosts || true
  sudo hostname "$HOSTNAME_VALUE"
else
  log "Hostname already set to ${HOSTNAME_VALUE}"
fi

CONFIG_FILE="/opt/mishka/config.json"
if [ -f "$CONFIG_FILE" ]; then
  log "Updating config.json identifiers"
  CONFIG_UPDATE_OUTPUT="$(sudo BLE_MAC_VALUE="$BLUETOOTH_MAC" WIFI_MAC_VALUE="$WIFI_MAC" HOST_VALUE="$HOSTNAME_VALUE" DEVICE_SERIAL_VALUE="$DEVICE_SERIAL" python3 <<'PY'
import json
import os
config_path = '/opt/mishka/config.json'
with open(config_path, 'r', encoding='utf-8') as fh:
    config = json.load(fh)
expected = {
    'device_mac': os.environ.get('BLE_MAC_VALUE', '').strip(),
    'wifi_mac': os.environ.get('WIFI_MAC_VALUE', '').strip(),
    'device_name': os.environ.get('HOST_VALUE', '').strip(),
    'device_serial': os.environ.get('DEVICE_SERIAL_VALUE', '').strip()
}
updated = False
for key, value in expected.items():
    if value and config.get(key) != value:
        config[key] = value
        updated = True
if updated:
    with open(config_path, 'w', encoding='utf-8') as fh:
        json.dump(config, fh, indent=2)
        fh.write('\n')
    print('config updated')
else:
    print('config already current')
PY
  )"
  if [ -n "$CONFIG_UPDATE_OUTPUT" ]; then
    log "$CONFIG_UPDATE_OUTPUT"
  fi
else
  log "WARNING: Config file not found at ${CONFIG_FILE}"
fi

log "Hostname routine complete: ${HOSTNAME_VALUE}"
log "=== PAUK Hostname Auto-Detect Complete ==="
