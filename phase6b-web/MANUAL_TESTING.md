# Phase 6b — Manual Testing Walkthrough

A copy-pasteable, step-by-step verification of `lab-web` covering the
loopback default, the `--auth` Basic-Auth path, the `--host` non-loopback
refusal, the `/static/*` exemption, and the CSRF guard on mutating routes.

This runbook reproduces the same end-to-end verification matrix the test
suite at `tests/test_routes.py` exercises at the ASGI layer — useful when
something goes wrong on a real machine (TLS proxy in front, firewall in
between, browser caching issues, etc.) and you need to bisect the HTTP wire
behaviour.

> **Set up:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2/phase6b-web
> uv sync                                # one-time: builds .venv/
> ```
>
> Every `lab-web` command below assumes you've activated the venv
> (`source .venv/bin/activate`) or are using `uv run lab-web`. See
> [`README.md`](README.md) for the three equivalent run methods.

A non-default port (`18765`) is used throughout so you don't collide with
anything bound on `8080`. Pick any unused port you like — just replace
consistently.

## 0. Preflight

```bash
.venv/bin/lab-web --version              # → "lab-web 0.1.0"
.venv/bin/lab-web --help                 # → full usage
```

The help text should list: `--host`, `--port`, `--reload`, `--allow-network`,
`--auth`. If `--allow-network` or `--auth` are missing you're running an
older build — `git pull` and re-`uv sync`.

## 1. CLI refusals (no server started)

These never reach `uvicorn`; they exit with code 2 and a stderr message
explaining what's missing. Useful for confirming the spec-mandated refusal
behaviour without spinning up a server.

```bash
.venv/bin/lab-web --host 0.0.0.0                          # missing --allow-network
echo "exit=$?"
```
**Expect:** `exit=2`, stderr mentions `--allow-network`.

```bash
.venv/bin/lab-web --host 0.0.0.0 --allow-network          # missing --auth
echo "exit=$?"
```
**Expect:** `exit=2`, stderr mentions `--auth USER:PASS`.

```bash
.venv/bin/lab-web --auth no-colon-here                    # malformed credential
echo "exit=$?"
```
**Expect:** `exit=2`, stderr says `--auth value must be USER:PASS`.

```bash
.venv/bin/lab-web --auth ":onlypass"                      # empty user side
echo "exit=$?"
```
**Expect:** `exit=2`, stderr says `both username and password must be non-empty`.

Mechanise:

```bash
.venv/bin/python -m pytest tests/ -k "test_cli_refuses" -v
```

## 2. Loopback default — no auth required

Start the server in one terminal:

```bash
.venv/bin/lab-web --port 18765
```

In another terminal:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18765/
```
**Expect:** `200`.

```bash
curl -sS http://127.0.0.1:18765/ | head -c 200; echo
```
**Expect:** the `<!DOCTYPE html>` start of the resource browser page.

```bash
curl -sS http://127.0.0.1:18765/api/v1/resources | head -c 200; echo
```
**Expect:** JSON starting `{"schema_version":1,"resources":...}`.

Stop the server with `Ctrl-C` before moving on.

## 3. Auth enabled — happy + sad paths

```bash
.venv/bin/lab-web --port 18765 --auth alice:s3cr3t
```

The server should print `lab-web: Basic Auth enabled (user='alice').` to
stderr at startup.

### 3a. No credentials → 401 + `WWW-Authenticate`

```bash
curl -sS -o /dev/null -D - http://127.0.0.1:18765/ | grep -iE 'HTTP/|WWW-Authenticate'
```
**Expect:**
```
HTTP/1.1 401 Unauthorized
www-authenticate: Basic realm="lab-create"
```
The `WWW-Authenticate` header is what makes browsers show the native login
dialog on first visit instead of a blank page.

### 3b. Correct credentials → 200

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -u alice:s3cr3t http://127.0.0.1:18765/
```
**Expect:** `200`.

### 3c. Wrong password → 401

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -u alice:wrong http://127.0.0.1:18765/
```
**Expect:** `401`.

### 3d. Wrong user → 401

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -u bob:s3cr3t http://127.0.0.1:18765/
```
**Expect:** `401`.

### 3e. Malformed `Authorization` header → 401 (no crash)

```bash
curl -sS -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Basic !!!not-base64!!!" \
    http://127.0.0.1:18765/
```
**Expect:** `401`. The middleware catches the `base64.b64decode` failure
and returns 401 rather than raising 500.

### 3f. Non-Basic scheme → 401

```bash
curl -sS -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer some-token" \
    http://127.0.0.1:18765/
```
**Expect:** `401`. We accept only `Basic` — any other scheme is treated as
unauthenticated.

Keep this server running for sections 4 and 5.

## 4. `/static/*` exemption

The login dialog itself needs CSS + JS to render properly, so `/static/*` is
exempt from auth. Nothing under there is user-supplied (vendored htmx,
sse.js, style.css).

```bash
curl -sS -o /dev/null -D - http://127.0.0.1:18765/static/style.css \
    | grep -iE 'HTTP/|content-type'
```
**Expect:**
```
HTTP/1.1 200 OK
content-type: text/css; charset=utf-8
```

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18765/static/htmx.min.js
```
**Expect:** `200`.

Verify by contrast that a non-static path under the same prefix-namespace
is *not* exempt:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18765/api/v1/resources
```
**Expect:** `401`.

## 5. Mutating endpoint — auth + CSRF stack

The destroy endpoint must clear **two** middlewares to fire:

1. HTTP Basic Auth (returns 401 with `WWW-Authenticate` if missing)
2. CSRF guard requiring `HX-Request: true` (returns 403 if missing)

### 5a. No auth → 401

```bash
curl -sS -o /dev/null -D - -X POST \
    -H "HX-Request: true" \
    http://127.0.0.1:18765/actions/destroy/vm/some-vm \
    | grep -iE 'HTTP/|WWW-Authenticate'
```
**Expect:**
```
HTTP/1.1 401 Unauthorized
www-authenticate: Basic realm="lab-create"
```

### 5b. Auth without `HX-Request` → 403

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -X POST \
    -u alice:s3cr3t \
    http://127.0.0.1:18765/actions/destroy/vm/some-vm
```
**Expect:** `403`. The auth middleware passes, then the CSRF guard rejects
the non-HTMX request. This is what blocks `<form action=...>` from any
third-party page being able to trigger destroy via the browser.

### 5c. Both auth + `HX-Request` → 200 (or 404 if the resource doesn't exist)

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -X POST \
    -u alice:s3cr3t \
    -H "HX-Request: true" \
    http://127.0.0.1:18765/actions/destroy/vm/nonexistent-vm
```
**Expect:** `200` (the route renders an HTML fragment saying the resource
wasn't found; status code is intentionally 200 because HTMX swap targets
that into `#detail-panel`).

Stop the server (`Ctrl-C`) when done.

## 6. Non-loopback bind with auth — `--allow-network` path

This is the spec-mandated network-exposure path. Run from a machine on a
trusted LAN, **not** a public host. Basic Auth travels in clear text over
plain HTTP — put nginx/Caddy with TLS in front for anything internet-facing.

Start:

```bash
.venv/bin/lab-web --host 0.0.0.0 --port 18765 \
    --allow-network --auth alice:s3cr3t
```

The server should print **both** the Basic-Auth notice **and** the network-
exposure warning to stderr:
```
lab-web: Basic Auth enabled (user='alice').
lab-web: WARNING: binding to 0.0.0.0:18765 — network exposed.
  Basic Auth is active, but the connection is plain HTTP (no TLS).
  Credentials travel in clear text unless a TLS reverse proxy is in front.
  ...
```

From another machine on the LAN (or from `<your-LAN-IP>` on the same host):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://<LAN-IP>:18765/
# → 401
curl -sS -o /dev/null -w "%{http_code}\n" -u alice:s3cr3t http://<LAN-IP>:18765/
# → 200
```

Stop the server with `Ctrl-C`.

## 7. Credential via `LAB_WEB_AUTH` env var

For systemd unit files where you don't want passwords in `ExecStart=`:

```bash
LAB_WEB_AUTH=alice:s3cr3t .venv/bin/lab-web --port 18765
```

The startup log should still say `Basic Auth enabled (user='alice').` even
without `--auth` on the command line. Verify with the same curl as 3b:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -u alice:s3cr3t http://127.0.0.1:18765/
# → 200
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18765/
# → 401
```

## 8. Run the automated test suite

Everything above is mechanised:

```bash
.venv/bin/python -m pytest tests/ -v
```

**Expect:** `32 passed`. The auth and CLI tests are the 13 named:

- `test_auth_disabled_no_header_required`
- `test_auth_enabled_no_header_returns_401`
- `test_auth_enabled_correct_credentials_pass`
- `test_auth_enabled_wrong_password_returns_401`
- `test_auth_enabled_wrong_user_returns_401`
- `test_auth_enabled_malformed_header_returns_401`
- `test_auth_enabled_non_basic_scheme_returns_401`
- `test_auth_enabled_static_files_exempt`
- `test_auth_destroy_endpoint_requires_credentials`
- `test_cli_refuses_nonloopback_without_allow_network`
- `test_cli_refuses_allow_network_without_auth`
- `test_cli_refuses_malformed_auth`
- `test_cli_refuses_empty_user_or_password`

## Troubleshooting

**`lab-web: error: --host '0.0.0.0' exposes the UI to the network.`**  
You forgot `--allow-network --auth USER:PASS`. This is intentional — the
PLAN spec for Phase 6b refuses to start non-loopback without both flags.

**The browser keeps prompting for credentials in a loop.**  
You're typing the right password but the browser caches the wrong one
between attempts. Clear the site's saved credentials, or test with `curl
-u` first to confirm the credential is right before involving the browser.

**`curl: (7) Failed to connect to 127.0.0.1 port 18765`**  
The server hasn't finished starting yet — uvicorn needs ~200 ms.  Wait or
poll:
```bash
until curl -fsS -o /dev/null --max-time 1 http://127.0.0.1:18765/static/style.css; do
    sleep 0.2
done
echo "ready"
```
(The `/static/style.css` path works whether auth is enabled or not, so
it's the safest readiness probe.)

**401 even with what looks like the right credentials.**  
Check whether your shell stripped quotes from a password containing `:`,
`!`, or `$`. Use `--auth "user:p@ss\$word"` or set `LAB_WEB_AUTH` in the
environment instead (the env-var path avoids most shell-quoting traps).
