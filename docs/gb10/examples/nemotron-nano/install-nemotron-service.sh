#!/usr/bin/env bash
# Renders nemotron-nano.service.in for this box (current user, script's own
# real location) and installs/starts it as a systemd unit. No fixed paths or
# usernames baked in - everything is substituted at install time, so this
# works unmodified from any checkout/clone location for any user.
# Needs an interactive sudo password:
#   ./install-nemotron-service.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_TEMPLATE="$SCRIPT_DIR/nemotron-nano.service.in"
UNIT_DST="/etc/systemd/system/nemotron-nano.service"

SERVICE_USER="${SERVICE_USER:-$(id -un)}"
SERVICE_GROUP="${SERVICE_GROUP:-$(id -gn)}"
RUN_SCRIPT="$SCRIPT_DIR/run-nemotron-nano.sh"

TMP_UNIT="$(mktemp)"
trap 'rm -f "$TMP_UNIT"' EXIT

sed \
  -e "s#__SERVICE_USER__#${SERVICE_USER}#" \
  -e "s#__SERVICE_GROUP__#${SERVICE_GROUP}#" \
  -e "s#__RUN_SCRIPT__#${RUN_SCRIPT}#" \
  "$UNIT_TEMPLATE" > "$TMP_UNIT"

sudo cp "$TMP_UNIT" "$UNIT_DST"
sudo systemctl daemon-reload
sudo systemctl enable --now nemotron-nano.service
sudo systemctl status nemotron-nano.service --no-pager
