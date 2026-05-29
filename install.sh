#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/triggerserver"
ENV_DIR="/etc/triggerserver"
ENV_FILE="${ENV_DIR}/triggerserver.env"
SERVICE_NAME="triggerserver"
SERVICE_USER="triggerserver"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: install.sh must be run as root (try: sudo ./install.sh)" >&2
    exit 1
fi

for required_file in trigger_server.py config.json triggerserver.service; do
    if [[ ! -f "${SCRIPT_DIR}/${required_file}" ]]; then
        echo "Error: missing ${required_file} next to install.sh" >&2
        exit 1
    fi
done

if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemctl not found — this installer needs systemd" >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl not found — install it (apt-get install openssl)" >&2
    exit 1
fi

if ! getent group docker >/dev/null 2>&1; then
    echo "Error: 'docker' group not found — install Docker first" >&2
    exit 1
fi

echo "==> Creating system user '${SERVICE_USER}' (if missing)"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi
usermod -aG docker "${SERVICE_USER}"

echo "==> Installing files to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
install -m 0644 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
    "${SCRIPT_DIR}/trigger_server.py" "${INSTALL_DIR}/trigger_server.py"
install -m 0644 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
    "${SCRIPT_DIR}/config.json"       "${INSTALL_DIR}/config.json"

echo "==> Setting up environment file at ${ENV_FILE}"
mkdir -p "${ENV_DIR}"
chown root:"${SERVICE_USER}" "${ENV_DIR}"
chmod 0750 "${ENV_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
    generated_token="$(openssl rand -hex 4)"
    echo "TRIGGER_TOKEN=${generated_token}" > "${ENV_FILE}"
    chown root:"${SERVICE_USER}" "${ENV_FILE}"
    chmod 0640 "${ENV_FILE}"
    echo "    Generated new token (saved to ${ENV_FILE})"
    NEW_TOKEN_GENERATED=1
else
    echo "    ${ENV_FILE} already exists — keeping existing token"
    NEW_TOKEN_GENERATED=0
fi

echo "==> Installing systemd unit"
install -m 0644 "${SCRIPT_DIR}/triggerserver.service" "${SERVICE_FILE}"

echo "==> Reloading systemd and enabling service"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

sleep 1
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "==> Service is active"
else
    echo "Warning: service is not active. Check logs: journalctl -u ${SERVICE_NAME} -n 50" >&2
fi

echo
echo "Install complete."
echo "  Status:  systemctl status ${SERVICE_NAME}"
echo "  Logs:    journalctl -u ${SERVICE_NAME} -f"
echo "  Token:   sudo cat ${ENV_FILE}"
if [[ "${NEW_TOKEN_GENERATED}" -eq 1 ]]; then
    echo
    echo "Note: a fresh token was generated. Read it with the command above."
fi
echo
echo "Don't forget to allow port 65432 on your LAN, e.g.:"
echo "  ufw allow from 192.168.0.0/16 to any port 65432 proto tcp"
