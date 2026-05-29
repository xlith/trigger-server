# trigger-server

A tiny HTTP server that runs pre-configured shell commands on the host when triggered from another device on the same network. Built for one specific job — adding IPs to a CrowdSec allowlist remotely — but the command map is configurable.

```
┌─────────────┐   curl ?ip=…&token=…   ┌──────────────────────┐
│ phone /     │ ──────────────────────▶│ trigger-server       │
│ laptop /    │                        │ (systemd, port 65432) │
│ shortcut    │ ◀──────────────────────│  → docker compose    │
└─────────────┘     JSON stdout/err    │    exec crowdsec …   │
                                       └──────────────────────┘
```

## Security model

The whole point of this design is to allow remote command execution **without** allowing arbitrary shell access:

- Commands and their `argv` arrays are defined server-side in `config.json`. The network can never supply program names or fixed flags.
- The network can only supply **named parameters**, each gated by a per-parameter regex. Values that don't fully match are rejected with HTTP 400.
- All commands run with `shell=False` — no shell metacharacter interpretation, ever.
- Requests must include a shared secret (`Authorization: Bearer <token>` or `?token=<token>`). Token comparison is constant-time.
- Service runs as a dedicated unprivileged user with systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`, etc.). It needs the `docker` group to talk to the Docker socket — that group is effectively root on the host, so don't reuse the user for anything else.

This is intended for a trusted LAN. Don't expose port 65432 to the internet without a TLS reverse proxy and stricter access control.

## Install (Debian/Ubuntu, systemd)

Requirements: Docker (with the `docker` group), Python 3, openssl, systemd.

```bash
git clone <repo-url> trigger-server && cd trigger-server
sudo ./install.sh
```

`install.sh` creates a `triggerserver` system user (in the `docker` group), copies the app to `/opt/triggerserver/`, generates a random token at `/etc/triggerserver/triggerserver.env`, installs the systemd unit, and starts the service.

Read the generated token:
```bash
sudo cat /etc/triggerserver/triggerserver.env
```

Open the LAN port (ufw example):
```bash
sudo ufw allow from 192.168.0.0/16 to any port 65432 proto tcp
```

## Use

From any device on the LAN:

```bash
# Discovery (no auth)
curl http://<host>:65432/

# Trigger (token via query string — easy from a browser or shortcut)
curl "http://<host>:65432/run/add-allowlist?ip=1.2.3.4&token=$TOKEN"

# Or via header
curl -H "Authorization: Bearer $TOKEN" \
     "http://<host>:65432/run/add-allowlist?ip=1.2.3.4"
```

Response is JSON: `{ok, returncode, stdout, stderr}`.

## Configure new commands

Edit `/opt/triggerserver/config.json`. Changes apply on the next request — no restart needed.

```jsonc
{
  "commands": {
    "<name>": {
      "argv": ["program", "fixed", "args"],
      "params": {
        "<param>": {
          "regex":    "^…$",        // fullmatch; reject anything that doesn't fit
          "required": true,
          "flag":     "--ip"        // optional: prepended before the value
        }
      }
    }
  }
}
```

Each param appends one (or two, if `flag` is set) element to `argv` in declared order. Unknown query-string keys are rejected.

## Operate

| Action     | Command                                     |
|------------|---------------------------------------------|
| Status     | `systemctl status triggerserver`            |
| Logs       | `journalctl -u triggerserver -f`            |
| Restart    | `sudo systemctl restart triggerserver`      |
| Rotate token | edit `/etc/triggerserver/triggerserver.env` then restart |

## Uninstall

```bash
sudo ./uninstall.sh           # default: keep token + user (clean reinstall later)
sudo ./uninstall.sh --purge   # full removal: deletes token and system user too
```

## Project layout

```
trigger_server.py        # stdlib HTTP server (no deps)
config.json              # commands + param regexes
triggerserver.service    # systemd unit
install.sh / uninstall.sh
```
