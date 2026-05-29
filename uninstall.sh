#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/triggerserver"
ENV_DIR="/etc/triggerserver"
SERVICE_NAME="triggerserver"
SERVICE_USER="triggerserver"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

REMOVE_USER=0
REMOVE_ENV=0
for arg in "$@"; do
    case "${arg}" in
        --remove-user)  REMOVE_USER=1 ;;
        --remove-env)   REMOVE_ENV=1 ;;
        --purge)        REMOVE_USER=1; REMOVE_ENV=1 ;;
        -h|--help)
            cat <<EOF
Usage: uninstall.sh [--remove-env] [--remove-user] [--purge]

  (default)         Stop service, remove unit + ${INSTALL_DIR}.
                    Preserves ${ENV_DIR} (your token) and the system user.
  --remove-env      Also delete ${ENV_DIR} (deletes the token).
  --remove-user     Also delete the '${SERVICE_USER}' system user.
  --purge           Both --remove-env and --remove-user.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: uninstall.sh must be run as root (try: sudo ./uninstall.sh)" >&2
    exit 1
fi

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    echo "==> Stopping and disabling ${SERVICE_NAME}"
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
fi

if [[ -f "${SERVICE_FILE}" ]]; then
    echo "==> Removing ${SERVICE_FILE}"
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
fi

if [[ -d "${INSTALL_DIR}" ]]; then
    echo "==> Removing ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
fi

if [[ "${REMOVE_ENV}" -eq 1 ]]; then
    if [[ -d "${ENV_DIR}" ]]; then
        echo "==> Removing ${ENV_DIR} (token will be lost)"
        rm -rf "${ENV_DIR}"
    fi
else
    if [[ -d "${ENV_DIR}" ]]; then
        echo "    Keeping ${ENV_DIR} (re-used on reinstall). Pass --remove-env to delete."
    fi
fi

if [[ "${REMOVE_USER}" -eq 1 ]]; then
    if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
        echo "==> Removing user '${SERVICE_USER}'"
        userdel "${SERVICE_USER}" 2>/dev/null || true
    fi
else
    if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
        echo "    Keeping user '${SERVICE_USER}'. Pass --remove-user to delete."
    fi
fi

echo
echo "Uninstall complete."
