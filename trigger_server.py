#!/usr/bin/env python3
import hmac
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

CONFIG_PATH = Path(__file__).resolve().parent / "config.json"
DEFAULT_PARAM_REGEX = r"^[\w@.,:/= +-]{1,200}$"
COMMAND_TIMEOUT_SECONDS = 30
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 65432


def load_config():
    with CONFIG_PATH.open("r", encoding="utf-8") as config_file:
        return json.load(config_file)


def expected_token():
    return os.environ.get("TRIGGER_TOKEN", "")


def token_is_valid(provided_token):
    expected = expected_token()
    if not expected or not provided_token:
        return False
    return hmac.compare_digest(expected, provided_token)


def extract_provided_token(headers, query_params):
    auth_header = headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        return auth_header[len("Bearer "):].strip()
    query_token_values = query_params.get("token")
    if query_token_values:
        return query_token_values[0]
    return ""


def build_argv(command_definition, query_params):
    base_argv = list(command_definition.get("argv", []))
    declared_params = command_definition.get("params", {}) or {}

    incoming_keys = set(query_params.keys()) - {"token"}
    declared_keys = set(declared_params.keys())
    unknown_keys = incoming_keys - declared_keys
    if unknown_keys:
        raise ValueError(f"unknown parameter(s): {sorted(unknown_keys)}")

    final_argv = list(base_argv)
    for param_name, param_spec in declared_params.items():
        regex_pattern = param_spec.get("regex", DEFAULT_PARAM_REGEX)
        is_required = bool(param_spec.get("required", False))
        flag = param_spec.get("flag")

        provided_values = query_params.get(param_name)
        if not provided_values:
            if is_required:
                raise ValueError(f"missing required parameter: {param_name}")
            continue

        param_value = provided_values[0]
        if not re.fullmatch(regex_pattern, param_value):
            raise ValueError(f"invalid value for {param_name}")

        if flag:
            final_argv.append(flag)
        final_argv.append(param_value)

    return final_argv


class TriggerHandler(BaseHTTPRequestHandler):
    server_version = "TriggerServer/1.0"

    def log_message(self, format, *args):
        sys.stderr.write(f"[{self.address_string()}] {format % args}\n")

    def _write_json(self, status_code, payload):
        body_bytes = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def _handle(self):
        parsed_url = urlsplit(self.path)
        query_params = parse_qs(parsed_url.query, keep_blank_values=True)
        path = parsed_url.path

        try:
            config = load_config()
        except Exception as load_error:
            self._write_json(500, {"ok": False, "error": f"config load failed: {load_error}"})
            return

        commands = config.get("commands", {}) or {}

        if path == "/" or path == "":
            discovery_payload = {
                name: {
                    "params": list((definition.get("params") or {}).keys()),
                    "required": [
                        param_name
                        for param_name, param_spec in (definition.get("params") or {}).items()
                        if param_spec.get("required")
                    ],
                }
                for name, definition in commands.items()
            }
            self._write_json(200, {"commands": discovery_payload})
            return

        if not path.startswith("/run/"):
            self._write_json(404, {"ok": False, "error": "not found"})
            return

        command_name = path[len("/run/"):].strip("/")
        if not command_name:
            self._write_json(404, {"ok": False, "error": "no command name"})
            return

        provided_token = extract_provided_token(self.headers, query_params)
        if not token_is_valid(provided_token):
            self._write_json(401, {"ok": False, "error": "unauthorized"})
            return

        if command_name not in commands:
            self._write_json(404, {"ok": False, "error": f"unknown command: {command_name}"})
            return

        try:
            argv_to_run = build_argv(commands[command_name], query_params)
        except ValueError as validation_error:
            self._write_json(400, {"ok": False, "error": str(validation_error)})
            return

        try:
            completed_process = subprocess.run(
                argv_to_run,
                shell=False,
                timeout=COMMAND_TIMEOUT_SECONDS,
                capture_output=True,
                text=True,
            )
        except subprocess.TimeoutExpired:
            self._write_json(500, {"ok": False, "error": "command timed out"})
            return
        except FileNotFoundError as missing_program_error:
            self._write_json(500, {"ok": False, "error": f"program not found: {missing_program_error}"})
            return
        except Exception as run_error:
            self._write_json(500, {"ok": False, "error": f"run failed: {run_error}"})
            return

        self._write_json(200, {
            "ok": completed_process.returncode == 0,
            "returncode": completed_process.returncode,
            "stdout": completed_process.stdout,
            "stderr": completed_process.stderr,
        })

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()


def main():
    if not expected_token():
        sys.stderr.write("WARNING: TRIGGER_TOKEN env var is empty — all requests will be rejected.\n")
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), TriggerHandler)
    sys.stderr.write(f"trigger_server listening on {LISTEN_HOST}:{LISTEN_PORT}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.server_close()


if __name__ == "__main__":
    main()
