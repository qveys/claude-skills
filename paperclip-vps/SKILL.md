---
name: paperclip-vps
description: Debug/administer the Paperclip AI-company server on vps-openclaw — paths, CLI board auth, agent/adapter config, logs, DB, patch infra. Use whenever the user mentions Paperclip, its companies (quentinveys.be, SoloSpark), its agents/adapters, or the paperclip container.
---

# Paperclip on vps-openclaw — direct routes (validated 2026-07-04)

## Topology
- Host: `vps-openclaw` (tailnet `100.100.10.60`, hostname srv1453980). SSH: `ssh vps-openclaw` (add `-o StrictHostKeyChecking=accept-new` on first contact).
- Container: `paperclip-paperclip-1` (custom committed image), API on `100.100.10.60:3100`, UI served same port. Sidecar: `paperclip-hindsight-1`.
- Bind mount: host `/docker/paperclip/data` ⇄ container `/paperclip`.
- **The code that actually RUNS is the global install `/usr/local/lib/node_modules/paperclipai/` inside the container** (`node /usr/local/bin/paperclipai run` is PID 1). The npx caches under `/paperclip/.npm/_npx/<hash>/node_modules/@paperclipai/*` are **secondary copies** (11 hashes exist) — reading code there is fine, but runtime patches MUST hit the global install. Don't repeat the mistake of patching only the npx copy.

## CLI `paperclipai` (inside container)
- Board auth: `docker exec -it paperclip-paperclip-1 paperclipai connect --persona board --token-name <label>` — **interactive** (user completes login; run it in the user's visible pane). Prints a `pcp_board_…` token (30-day expiry). The CLI context profile does NOT persist it for later `docker exec`s — pass it via env instead:
  `PCP='-e PAPERCLIP_API_URL=http://localhost:3100 -e PAPERCLIP_API_KEY=pcp_board_…'; docker exec $PCP paperclip-paperclip-1 paperclipai …`
- Useful: `company list`, `agent list -C <companyId>` (flag is `-C`, not `--company`), `agent get <agentId> --json`, `agent update <agentId> --payload-json '<json>'` (partial payload OK, e.g. just `{adapterConfig}`), `agent resume <agentId>` (clears error status), `heartbeat run -a <agentId> --timeout-ms 90000` (triggers a REAL adapter run with live logs — the best end-to-end validation).
- HTTP API mirror: `/api/*`, `Authorization: Bearer <key>`; `PATCH /api/agents/:id`, `GET /api/companies/:id/agents`, `POST /api/companies/:id/adapters/:type/test-environment`.

## Known IDs (2026-07)
- Company `quentinveys.be` = `92b95c2f-df76-47f8-acb8-17e7a6d0cb69` (13 agents; engineer Amelia d5b9099c… claude_local is the healthy reference config). Company `SoloSpark` = `217aab1b-90e2-48e1-bc29-1e531d3c7a3d` (CEO + Engineer 006975a9…; Engineer has adapterType `process` with EMPTY adapterConfig → `Process adapter missing command` — user deferred fixing; SoloSparkApp project also lacks git init → WorkspaceValidationFailure on issues SOL-2..9).
- Orchestrator (quentinveys.be) = `9f7ee7bb-02b1-4217-a3b0-793ceb014705`, adapter `openclaw_gateway` → gateway on the Mac via `wss://macbook-openclaw.end-inconnu.ts.net` (portail Caddy routes WS upgrades → 127.0.0.1:18789).
- Keys on the Mac in `~/.hermes/.env`: `PAPERCLIP_MCP_API_KEY` (agent-scoped to quentinveys.be CEO — CANNOT list companies, "Board access required"), `PAPERCLIP_CEO_KEY`.

## Logs / DB / secrets
- Server log: `/docker/paperclip/data/instances/default/logs/server.log` (HUGE, ~800MB — always `tail -c 5000000 | grep`, never read whole). Container boot: `docker logs`. Instance config: `instances/default/config.json`.
- DB: embedded postgres, port 54329 **inside container only**, creds `paperclip`/`paperclip` (hardcoded in server dist `index.js` ~line 306). NO psql binary anywhere (embedded pkg ships only initdb/pg_ctl/postgres). Query via `docker exec node` + the `postgres` npm package from the global install. NOTE: the permission classifier tends to flag direct DB access as credential exploration — prefer the CLI/API route with a board token; it covers almost everything.
- Company secrets: `POST /api/companies/:id/secrets {name, value}` → `local_encrypted`. In adapterConfig, `{type:"secret_ref", secretId, version:"latest"}` is resolved at runtime ONLY for (a) keys under `env`, and (b) fields the adapter's schema marks `meta.secret:true` (fallback table covers ONLY `hermes_gateway: ["apiKey"]`). **openclaw_gateway has no schema → its `password`/`authToken` fields must be PLAINTEXT** (get explicit user consent; do the PATCH from the Mac with the value in a shell var so it's never displayed).
- **`openclaw config get gateway.auth.password | tail -1` returns a TRUNCATED value** (21 chars vs the real 28) — always read secrets from the canonical file: `jq -r '.gateway.auth.password' ~/.openclaw/openclaw.json`. Compare by `shasum` when debugging "password mismatch", never by printing.

## openclaw_gateway adapter — traps (all hit 2026-07-04)
- `url` must be `ws://`/`wss://` — a `https://` URL → agent error `Unsupported gateway URL protocol: https:`. Correct value: `wss://macbook-openclaw.end-inconnu.ts.net`. Field `apiBaseUrl` is NOT read by the adapter (dead config).
- `test-environment` probe is a FALSE NEGATIVE generator: the route doesn't pass adapterType (so secret_refs unresolved → "auth missing" warn) and the probe sends only `authToken` (never `password`, no device identity) → "challenge received, connect probe rejected" is EXPECTED with password auth. Judge with `heartbeat run`, not the probe.
- Protocol: adapter 2026.626.0 hardcodes `PROTOCOL_VERSION = 3`; OpenClaw gateway ≥2026.6.x only accepts range including **4** → `Error: protocol mismatch`. Fixed by patch `/paperclip/patches/openclaw-protocol-v4/apply.sh` (bumps execute.js + test.js in global install AND npx caches) + boot step `/opt/paperclip/entrypoint.d/42-openclaw-protocol-v4.sh`. Becomes a no-op when upstream ships v4; remove then.
- Device identity: deviceId = sha256(raw ed25519 pubkey from `devicePrivateKeyPem`) = `30a7cf4f…` for the Orchestrator. Check pairing on the Mac: `openclaw devices list`. Adapter auto-pairs on first connect (`autoPairOnFirstConnect` default true) but never persists a deviceToken. First authenticated run may fail once with "pairing required" while auto-pairing lands — just retry.
- **FIXED end-to-end 2026-07-04** (validated: agent processed issue QUE-267 to done): url wss + plaintext password (28 chars) + protocol-v4 patch + auto-paired device + `timeoutSec: 300` (9router `auto` brain can exceed the 120s default).
- The wake message tells the Mac agent to load `PAPERCLIP_API_KEY` from `~/.openclaw/workspace/paperclip-claimed-api-key.json` (adapter config `claimedApiKeyPath`). File wired 2026-07-04 (mode 600): JSON `{apiKey, key, agentId, agentName, companyId, apiUrl}` where the key comes from `paperclipai token agent create -C <companyId> --agent <agentId> --name <label> --json` (board auth; `token agent list/revoke` need BOTH `-C` and `--agent`). Active key label `openclaw-orchestrator` id `11f36cfa…`. Secrets are write-only in Paperclip (no API/UI read-back; only usage/access-events).
- Gateway-side debugging on the Mac: `~/Library/Logs/openclaw/gateway.log` is launchd **stdout only — stderr goes to /dev/null**, so `protocol mismatch` warns are INVISIBLE there. Portail access log `~/Library/Logs/portail/access.log` (JSON) shows whether the VPS WS upgrade arrived (status 101, X-Forwarded-For). To see the gateway's real answer, replay the handshake from the Mac with python websockets → `ws://127.0.0.1:18789`, wait `connect.challenge`, send `connect` req.

## Patch infrastructure (established pattern — follow it)
- Boot steps: `/opt/paperclip/entrypoint.d/NN-name.sh` **inside the image** (write with `docker exec -u root`; /opt is root-owned). Read its `README.md` before adding. Conventions: `set -uo pipefail`, marker-gated idempotent, fail-SOFT (`exit 0` always), `.bg.sh` suffix = background (races with server module load — never use for server-code patches).
- Patch payloads live on the volume: `/paperclip/patches/<name>/apply.sh` (survive image updates); the boot step just execs them.
- `/docker/paperclip/data/entrypoint.d/` (volume) is **DEAD** — the entrypoint only reads `/opt/paperclip/entrypoint.d`.
- Ship scripts to the VPS by `base64 | tr -d '\n'` locally, then `echo <b64> | base64 -d > file` remotely (avoids quoting hell in typed panes).
