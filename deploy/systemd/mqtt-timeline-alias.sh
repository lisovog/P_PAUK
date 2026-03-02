#!/bin/bash
# MQTT Timeline mDNS Alias Service
# Advertises mqtt-timeline.local for both HTTP and MQTT endpoints.

set -e

trap 'log "Service interrupted, cleaning up..."; exit 0' TERM INT

LOG_FILE="/var/log/mqtt-timeline-alias.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== MQTT Timeline Alias Service Started ==="

NEED_PKG=false
for pkg in libnss-mdns avahi-daemon avahi-utils; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    NEED_PKG=true
  fi
done

if [ "$NEED_PKG" = true ]; then
  log "Installing Avahi + mDNS dependencies"
  apt-get update -qq
  apt-get install -y libnss-mdns avahi-daemon avahi-utils
fi

if ! grep -q "mdns4_minimal" /etc/nsswitch.conf || ! grep -q "dns mdns4" /etc/nsswitch.conf; then
  log "Configuring /etc/nsswitch.conf for mDNS (adding mdns4)"
  cp /etc/nsswitch.conf /etc/nsswitch.conf.backup 2>/dev/null || true
  # Rebuild the hosts line to a consistent form; leave other lines untouched
  awk 'BEGIN{updated=0} /^hosts:/ {print "hosts:\t files mdns4_minimal [NOTFOUND=return] dns mdns4"; updated=1; next} {print} END{if(!updated) print "hosts:\t files mdns4_minimal [NOTFOUND=return] dns mdns4"}' /etc/nsswitch.conf > /etc/nsswitch.conf.tmp && mv /etc/nsswitch.conf.tmp /etc/nsswitch.conf
fi

PRIMARY_IFACE=""
if ip link show wlan0 &>/dev/null; then
  PRIMARY_IFACE="wlan0"
else
  PRIMARY_IFACE="$(ip route | awk '/default/ {print $5; exit}')"
fi
[ -z "$PRIMARY_IFACE" ] && PRIMARY_IFACE="wlan0"
PRIMARY_IP="$(ip -4 addr show "$PRIMARY_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)"
if [ -z "$PRIMARY_IP" ]; then
  log "WARNING: Could not determine IPv4 for ${PRIMARY_IFACE}; mDNS host aliases may not resolve"
fi

AVAHI_HOSTS_FILE="/etc/avahi/hosts"
# Clean up any stale entries we might have created previously (they cause avahi-daemon warnings
# and are not suitable for aliasing the *local* interface address).
if [ -f "$AVAHI_HOSTS_FILE" ]; then
  if grep -qE 'mqtt-timeline(\.local)?|mqtt-test\.local' "$AVAHI_HOSTS_FILE"; then
    cp "$AVAHI_HOSTS_FILE" "${AVAHI_HOSTS_FILE}.backup" 2>/dev/null || true
    grep -vE 'mqtt-timeline(\.local)?|mqtt-test\.local' "$AVAHI_HOSTS_FILE" >"${AVAHI_HOSTS_FILE}.tmp" || true
    mv "${AVAHI_HOSTS_FILE}.tmp" "$AVAHI_HOSTS_FILE"
    chmod 644 "$AVAHI_HOSTS_FILE"
    log "Cleaned stale entries from ${AVAHI_HOSTS_FILE}"
  fi
fi

AVAHI_CONF="/etc/avahi/avahi-daemon.conf"
if [ -f "$AVAHI_CONF" ]; then
  cp "$AVAHI_CONF" "${AVAHI_CONF}.backup" 2>/dev/null || true
  log "Configuring avahi-daemon for interface ${PRIMARY_IFACE}"

  # Ensure the system responds to mqtt://mqtt-timeline.local by publishing a stable mDNS host name.
  # This is the most reliable approach for this device (publishing an extra local-IP hostname via
  # /etc/avahi/hosts is rejected by avahi-daemon).
  if grep -q '^host-name=' "$AVAHI_CONF"; then
    sed -i 's/^host-name=.*/host-name=mqtt-timeline/' "$AVAHI_CONF"
  else
    sed -i '/^\[server\]/a host-name=mqtt-timeline' "$AVAHI_CONF"
  fi

  if grep -q '^allow-interfaces' "$AVAHI_CONF"; then
    sed -i "s/^allow-interfaces=.*/allow-interfaces=${PRIMARY_IFACE}/" "$AVAHI_CONF"
  else
    sed -i "/^\[server\]/a allow-interfaces=${PRIMARY_IFACE}" "$AVAHI_CONF"
  fi
  if grep -q '^deny-interfaces' "$AVAHI_CONF"; then
    sed -i 's/^deny-interfaces=.*/deny-interfaces=docker0,br-*,veth*,lo/' "$AVAHI_CONF"
  else
    sed -i "/^\[server\]/a deny-interfaces=docker0,br-*,veth*,lo" "$AVAHI_CONF"
  fi
fi

log "Checking avahi-daemon status"
AVAHI_AVAILABLE=false
if systemctl is-active --quiet avahi-daemon; then
  log "avahi-daemon already running"
  AVAHI_AVAILABLE=true
elif systemctl list-unit-files | grep -q avahi-daemon.service; then
  log "Starting avahi-daemon service"
  if systemctl start avahi-daemon 2>/dev/null; then
    sleep 2
    if systemctl is-active --quiet avahi-daemon; then
      AVAHI_AVAILABLE=true
      log "avahi-daemon started"
    else
      log "Warning: avahi-daemon failed to start"
    fi
  else
    log "Warning: avahi-daemon start failed"
  fi
else
  log "Warning: avahi-daemon service not found"
fi

if [ "$AVAHI_AVAILABLE" = true ]; then
  AVAHI_SERVICE_FILE="/etc/avahi/services/mqtt.service"
  log "Creating mDNS service definition at ${AVAHI_SERVICE_FILE}"
  cat >"$AVAHI_SERVICE_FILE" <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>MQTT Broker</name>
  <service>
    <type>_mqtt._tcp</type>
    <port>1883</port>
  </service>
</service-group>
EOF

  chmod 644 "$AVAHI_SERVICE_FILE"
  log "Reloading avahi-daemon configuration"
  if pgrep avahi-daemon >/dev/null; then
    # Prefer a full restart to flush any stale duplicate service instances
    systemctl restart avahi-daemon || pkill -HUP avahi-daemon || log "Warning: could not restart or signal avahi-daemon"
  fi
  sleep 4
else
  log "Skipping Avahi configuration because the daemon is unavailable"
fi

log "Primary interface: ${PRIMARY_IFACE} | IP: ${PRIMARY_IP:-unknown}"
if [ "$AVAHI_AVAILABLE" = true ]; then
  if command -v avahi-browse >/dev/null 2>&1 && timeout 5 avahi-browse -t _mqtt._tcp 2>/dev/null | grep -q "MQTT"; then
    log "SUCCESS: MQTT broker service is advertising on _mqtt._tcp"
  else
    log "WARNING: MQTT broker service may not be advertising correctly"
  fi
else
  log "mDNS not configured; use IP ${PRIMARY_IP:-unknown} instead"
fi

log "=== MQTT Timeline Alias Service Complete ==="
