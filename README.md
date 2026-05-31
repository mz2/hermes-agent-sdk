# Hermes Agent SDK for Workshop

This SDK provides the [Hermes Agent](https://github.com/NousResearch/hermes-agent),
a self-improving AI agent from Nous Research that creates skills from
experience, maintains persistent memory, and bridges to messaging platforms
(Telegram, Discord, WhatsApp, Slack, Signal, Email) via its gateway daemon.
The rebuildable runtime — the `hermes-agent` clone, the Python virtualenv,
bundled Node 22, and the uv/npm/Playwright caches — lives inside the workshop
sandbox, so nothing of it is written to host storage. It persists across
`workshop refresh` and is rebuilt only on a full recreate. Only the agent's
config and state (`~/.hermes`) and its secrets (`.env`) are persisted via
mount plugs.

It is packaged for [Workshop](https://ubuntu.com/workshop), Canonical's tool
for reproducible, sandboxed development environments.

---

## Reference workshop

A minimal workshop:

```yaml
# workshop.yaml
name: hermes
base: ubuntu@24.04
sdks:
  - name: hermes-agent
    channel: latest/stable
  - name: ollama
    channel: latest/stable

connections:
  # Wire the Ollama workshop's HTTP server into the Hermes workshop's
  # llm-backend plug. The default config.yaml shipped with hermes-sdk
  # points at http://localhost:11434/v1, so this Just Works.
  - plug: hermes-agent:llm-backend
    slot: ollama:ollama-server

actions:
  chat: |
    hermes chat
  configure-credentials: |
    ${EDITOR:-vi} ~/.hermes/.env
  gateway-restart: |
    systemctl --user restart hermes-gateway
```

The reference pairs `hermes` with an `ollama` workshop so the agent has a
local LLM backend out of the box. Remove the `connections:` block to point
at OpenRouter / Anthropic / OpenAI instead — edit `~/.hermes/config.yaml`
and add the API key to `~/.hermes/.env`.

---

## Local development — run the example from a local build

This is the verified end-to-end runbook for trying a locally-built SDK
(no Store upload). It uses `examples/workshop.yaml`, which pairs the SDK
with a `system` tunnel slot pointing at an Ollama on the host.

### Prerequisites

- The Workshop snap (provides `workshop`, `sdk`, and `sdkcraft`).
- An OpenAI-compatible LLM endpoint reachable from the host — e.g. Ollama
  listening on `localhost:11434`. The default `config.yaml` requests model
  `qwen3.6:35b`; `ollama pull qwen3.6:35b` (or edit the model in
  `~/.hermes/config.yaml`) so the agent has something to talk to.

### Steps

1. **Build and register the SDK locally.** From the repo root, on the
   version branch:

   ```bash
   git checkout latest
   sdkcraft try        # packs amd64+arm64 and registers it as `try-hermes-agent`
   ```

   `sdkcraft try` re-packs whenever a part changed; otherwise it reuses the
   cached build.

2. **Launch the example workshop.** First launch takes ~5–10 minutes
   (Hermes clone, Python 3.11 venv, Node 22, Playwright Chromium); later
   refreshes are fast because the runtime persists in the workshop's own
   filesystem (a full `remove`/recreate redoes the install).

   ```bash
   cd examples
   workshop launch --verbose
   ```

3. **Connect the LLM tunnel.** Tunnels do **not** auto-connect, even though
   the connection is declared in `workshop.yaml` (mounts do auto-connect).
   Run this once after launch:

   ```bash
   workshop connect hermes/hermes-agent:llm-backend \
                    hermes/system:llm-backend
   ```

   > Note: in `connections:` the plug is referenced by the SDK's real name
   > `hermes-agent`, **not** `try-hermes-agent` — the `try-` prefix is
   > reserved in plug/slot references.

4. **Verify.**

   ```bash
   workshop info                                    # status: ready
   workshop run hermes status               # hermes version + gateway unit
   workshop connections | grep tunnel               # llm-backend shows a slot, "manual"
   workshop exec -- curl -s http://localhost:11434/v1/models   # HTTP 200 from host Ollama
   ```

5. **Use it.**

   ```bash
   workshop run hermes chat     # interactive chat (Ollama-backed)
   workshop run hermes logs     # follow gateway logs
   workshop shell hermes        # interactive session; project is at /project
   ```

To iterate on the SDK, edit `sdkcraft.yaml`/`hooks/`, re-run `sdkcraft try`,
then `workshop refresh` (not remove+launch).

---

## Using the SDK

### Prerequisites and project layout

No prerequisite SDKs are required, but the agent needs an LLM provider to be
useful — either an `ollama` workshop wired via the `llm-backend` plug, or a
remote endpoint (OpenAI / Anthropic / OpenRouter / NovitaAI) set in
`~/.hermes/config.yaml`. No particular project layout is needed; `/project` is
available to the agent for file tools, code execution, and `hermes skill` work.

On first launch (`amd64` or `arm64`) the SDK installs uv, clones
`NousResearch/hermes-agent` at the pinned VERSION, builds a Python 3.11 venv,
fetches Node 22 (for the WhatsApp bridge — Ubuntu 24.04's apt Node is too old),
installs Playwright Chromium, writes a default `config.yaml` if absent, and
starts the gateway as a systemd user unit.

### Configure messaging credentials

The gateway will sit in `activating`/`failed` until credentials are in
place. Credentials live in a dedicated `hermes-secrets` mount plug at
`~/.hermes/secrets/.env`; `setup-project` also creates a symlink
`~/.hermes/.env -> secrets/.env` so the hermes CLI sees the same file.

**Edit from inside the workshop** (simplest):

```bash
workshop shell
$EDITOR ~/.hermes/secrets/.env
# Add e.g. TELEGRAM_BOT_TOKEN=..., DISCORD_BOT_TOKEN=..., etc.
systemctl --user restart hermes-gateway
```

**Manage from a host directory** ([agenix](https://github.com/ryantm/agenix),
[sops](https://github.com/getsops/sops), plain host file). The
`hermes-secrets` plug is separate from `hermes-home` precisely so you can
remount only the secrets without taking over the whole ~/.hermes tree:

```bash
# On the host:
mkdir -p ~/secrets/hermes
$EDITOR ~/secrets/hermes/.env

# Then from the workshop project:
workshop remount <workshop>/hermes-agent:hermes-secrets ~/secrets/hermes
workshop shell -c "systemctl --user restart hermes-gateway"
```

Or declare the connection in `workshop.yaml` via `system:mount` with
`host-source: ~/secrets/hermes` so it survives `workshop remove` /
`workshop launch` cycles.

**Encrypted at rest (age).** The SDK has no dependency on any secret
manager — `hermes-secrets` is just a mount, so *what backs it* is your
choice. To keep credentials encrypted at rest, store an age-encrypted
`hermes-env.age` (committed to your config repo), decrypt it at login into
a tmpfs, and remount `hermes-secrets` there. Plaintext then lives only in
RAM and the age key never enters the workshop:

```bash
# decrypt the committed ciphertext into the per-user tmpfs ($XDG_RUNTIME_DIR):
install -d -m 700 "$XDG_RUNTIME_DIR/hermes-secrets"
age -d -i ~/.ssh/id_ed25519 -o "$XDG_RUNTIME_DIR/hermes-secrets/.env" hermes-env.age

# point the secrets mount at it (re-applied on future `workshop refresh`):
workshop remount <workshop>/hermes-agent:hermes-secrets "$XDG_RUNTIME_DIR/hermes-secrets"
workshop exec <workshop> -- systemctl --user restart hermes-gateway
```

Wrap the decrypt step in a `systemd --user` oneshot unit (with
`loginctl enable-linger`) to repopulate the tmpfs at every boot. `age`
supports SSH ed25519 keys directly as the identity/recipient, so an
existing key works — no separate keypair needed.

The `check-health` hook reports `waiting` with a remediation hint while
the gateway is not active, so `workshop status` surfaces guidance.

### Running the hermes CLI

The `hermes` CLI runs **inside the workshop** — the SDK installs a wrapper at
`~/.local/bin/hermes` that puts the bundled Node 22 on `PATH` and execs the
venv entrypoint. It is not installed on the host, so you invoke it through
`workshop`. Three equivalent ways (workshop name `hermes` here; omit
it if the project has only one workshop):

```bash
# 1. One-off command in the workshop:
workshop exec hermes -- hermes --version

# 2. Interactive login shell, then use hermes directly:
workshop shell hermes
#   then inside the shell:
hermes chat
hermes --version

# 3. Via a named action defined in workshop.yaml (forwards trailing args):
workshop run hermes chat -- --model openrouter/anthropic/claude-3.5-sonnet
```

The `chat` action above is just `hermes chat "$@"` from the workshop's
`actions:` block — see `examples/workshop.yaml`.

### Interactive chat

No need to open a shell first — `exec` forwards a TTY, so chat works as a
one-liner. Pass model overrides after the command:

```bash
workshop exec hermes -- hermes chat
workshop exec hermes -- hermes chat --model openrouter/anthropic/claude-3.5-sonnet
```

Or `workshop run hermes chat` if the workshop defines the `chat` action.

### Verify from the command line

```bash
workshop shell
hermes --version
systemctl --user status hermes-gateway
```

---

## MCP servers

Hermes can discover external tools from [MCP](https://modelcontextprotocol.io/)
servers. List them under `mcp_servers:` in `~/.hermes/config.yaml`; Hermes
loads them at startup, and `/reload-mcp` inside `hermes chat` re-reads the
block without a restart. `setup-project` writes a commented `mcp_servers:`
template into the default `config.yaml` to get you started.

Each server uses one of two transports:

- **HTTP** — `url:` (plus optional `headers:`). The server runs as its own
  process, in a sibling workshop or remotely. This is the recommended way to
  wire another Workshop SDK, and the only one that works cleanly for the
  long-running gateway daemon. Use the `mcp-server` tunnel plug.
- **stdio** — `command:` / `args:` / `env:`. Hermes spawns the server as a
  subprocess. The server's binary must be on `PATH` in the **same** workshop,
  so its SDK must be added to the same `workshop.yaml`. No tunnel needed.

In both cases, scope what Hermes sees with a `tools:` block — `include:` /
`exclude:` lists, and `resources: false` / `prompts: false` to drop the MCP
utility wrappers. Prefer an `include:` allowlist for servers that can write or
delete.

### Example: AFFiNE docs via the `affine-mcp-server` SDK (HTTP)

The `affine-mcp-server` SDK runs the HTTP server itself (a managed systemd
service) and generates the bearer token on first launch — Hermes is a pure
consumer. See
[`examples/workshop.with-mcp.yaml`](examples/workshop.with-mcp.yaml) for the
complete runnable file with `affine-login` / `enable-affine` actions.

1. **Put both SDKs in one `workshop.yaml` and wire the tunnel.** The AFFiNE
   server's HTTP slot feeds Hermes' `mcp-server` plug:

   ```yaml
   sdks:
     - name: hermes-agent
       channel: latest/stable
     - name: affine-mcp-server
       channel: latest/stable

   connections:
     - plug: hermes-agent:mcp-server
       slot: affine-mcp-server:affine-mcp-http
   ```

2. **Authenticate the AFFiNE server.** It already serves :3000; you only need to
   give it AFFiNE credentials, then restart it to pick them up:

   ```bash
   affine-mcp login                       # or set AFFINE_BASE_URL / AFFINE_API_TOKEN
   systemctl --user restart affine-mcp-http
   ```

3. **Point Hermes at it.** Reference the server's bearer token (in
   `~/.config/affine-mcp/.env`) rather than embedding it — copy it into
   `~/.hermes/secrets/.env` and use `${AFFINE_MCP_HTTP_TOKEN}` in the header so
   no secret is written into `config.yaml`:

   ```yaml
   # ~/.hermes/config.yaml
   mcp_servers:
     affine:
       url: http://localhost:3000/mcp
       headers:
         Authorization: "Bearer ${AFFINE_MCP_HTTP_TOKEN}"
       tools:
         resources: false
         prompts: false
   ```

   Then `systemctl --user restart hermes-gateway` (or `/reload-mcp` in chat).
   Ask Hermes "Which MCP tools are available?" to confirm the AFFiNE tools
   loaded. The `enable-affine` action in the example file does the token copy
   and config edit for you.

> **Cross-workshop variant.** The same wiring works with the AFFiNE server in
> a *separate* workshop: launch it there, then
> `workshop connect <hermes-ws>/hermes-agent:mcp-server
> <affine-ws>/affine-mcp-server:affine-mcp-http`. The `mcp-server` plug exists
> precisely so the HTTP transport can cross the sandbox boundary; tunnels do
> not auto-connect, so run the `connect` once after launch. The two sandboxes
> no longer share a home, so the bearer token must be provisioned into both
> secret stores — read it from the AFFiNE workshop's `~/.config/affine-mcp/.env`
> and add it to Hermes' `~/.hermes/secrets/.env`.

### Alternative: stdio (same workshop, no tunnel)

If you keep both SDKs in one workshop, Hermes can spawn `affine-mcp` directly
over stdio — no HTTP server, no tunnel:

```yaml
mcp_servers:
  affine:
    command: affine-mcp
    env:
      AFFINE_TOOL_PROFILE: read_only
    tools:
      resources: false
      prompts: false
```

Caveat: the gateway runs as a systemd **user** unit, which does not source
`/etc/profile.d`, so `affine-mcp` may not be on its `PATH`. stdio is most
reliable for interactive `hermes chat` (a login shell); for the gateway daemon
prefer the HTTP transport above, or give the `command:` an absolute path.

## Plugs (resources this SDK consumes)

> **Persistence model.** Only the agent's config/state and its secrets are
> mounted. The rebuildable runtime — the `hermes-agent` clone and Python
> venv (`~/hermes-agent`), bundled Node 22 (`~/.local/lib/hermes/node`), and
> the uv/npm/Playwright caches (`~/.cache/uv`, `~/.npm`,
> `~/.cache/ms-playwright`) — lives in the workshop sandbox, not on the host.
> It persists across `workshop refresh` (same container) and is rebuilt only
> on a full recreate.

### `hermes-home`

- Interface: `mount`
- Workshop target: `/home/workshop/.hermes`
- Mode: `0o700`
- Purpose: The agent's config and state — `config.yaml`, `.env` (symlink),
  `SOUL.md`, persistent memory, skills, and sessions. **Not** the runtime
  (clone/venv/Node/caches all live in the sandbox). Like claude-code's
  `claude-config`, this mount auto-connects to Workshop-allocated storage
  and survives `workshop refresh`. To manage it on a host path instead:
  `workshop stop <ws>` →
  `workshop remount <ws>/hermes-agent:hermes-home <host-path>` →
  `workshop start <ws>`.

### `hermes-secrets`

- Interface: `mount`
- Workshop target: `/home/workshop/.hermes/secrets`
- Mode: `0o700`
- Purpose: Dedicated mount for credentials (`.env`). Narrower than
  `hermes-home` so the host can manage just the secrets directory with
  a host-side secret manager ([agenix](https://github.com/ryantm/agenix),
  [sops](https://github.com/getsops/sops), plain file) without taking
  over the rest of `~/.hermes`. `setup-project` symlinks
  `~/.hermes/.env -> secrets/.env` so the hermes CLI and the gateway
  systemd unit see the same file.

### `llm-backend`

- Interface: `tunnel`
- Endpoint: `11434`
- Purpose: Outbound connection to an Ollama-compatible OpenAI endpoint.
  Two patterns work — wire to a sibling SDK's slot, or to a
  `system:` tunnel slot pointing at a host address. When connected,
  `http://localhost:11434/v1` (the default in the SDK-provisioned
  `config.yaml`) tunnels to whatever the slot points at.

#### Sibling workshop SDK (Ollama in another workshop on the same host)

```yaml
sdks:
  - name: hermes-agent
    channel: latest/stable
  - name: ollama
    channel: latest/stable

connections:
  - plug: hermes-agent:llm-backend
    slot: ollama:ollama-server
```

#### Host-reachable Ollama

The `system` SDK exposes a tunnel slot pointing at any host-reachable
endpoint. No config rewrite or post-launch step needed:

```yaml
sdks:
  - name: hermes-agent
    channel: latest/stable
  - name: system
    slots:
      llm-backend:
        interface: tunnel
        endpoint: ozymandias:11434   # or localhost:11434 for same-host

connections:
  - plug: hermes-agent:llm-backend
    slot: system:llm-backend
```

See `examples/workshop.yaml` in this repo for a complete runnable
variant.

#### Remote provider (OpenAI / Anthropic / OpenRouter)

For HTTPS providers reached over the public internet, skip the tunnel wiring
entirely — the workshop's outbound network reaches them directly, so the
`llm-backend` plug and `system:` slot aren't needed. Use a plain
`workshop.yaml` (just `- name: hermes-agent`), set the `model:` block in
`~/.hermes/config.yaml`, and add the API key to `~/.hermes/secrets/.env`:

```yaml
# ~/.hermes/config.yaml — OpenRouter example
model:
  provider: custom
  default: anthropic/claude-3.5-sonnet     # a model the provider offers
  base_url: https://openrouter.ai/api/v1   # the provider's /v1 endpoint
  api_key: ${OPENROUTER_API_KEY}           # read from secrets/.env
```

```bash
echo 'OPENROUTER_API_KEY=sk-or-...' >> ~/.hermes/secrets/.env
systemctl --user restart hermes-gateway
```

(For OpenAI use `https://api.openai.com/v1`; for Anthropic's OpenAI-compatible
endpoint `https://api.anthropic.com/v1`.) See
`examples/workshop.remote-openai.yaml` for a runnable variant with
`set-token` / `set-endpoint` actions that do this for you.

### `mcp-server`

- Interface: `tunnel`
- Endpoint: `3000`
- Purpose: Outbound connection to an MCP server's HTTP transport running in a
  sibling workshop, so Hermes can discover and use its tools. Connect this
  plug to the server's HTTP slot (e.g. the `affine-mcp-server` SDK's
  `affine-mcp-http` slot); the server is then reachable inside the workshop at
  `http://localhost:3000/mcp`, which is what an `mcp_servers:` entry in
  `~/.hermes/config.yaml` points at. The endpoint defaults to `3000` to match
  `affine-mcp-http`; change it to match another server's port. Not needed for
  MCP servers that run in the **same** workshop over stdio — see the
  [MCP servers](#mcp-servers) section.

## Slots (resources this SDK provides)

### `gateway`

- Interface: `tunnel`
- Endpoint: `8765`
- Purpose: Exposes the gateway process's loopback presence to host
  tooling. Useful for future host-side probes against `hermes gateway`
  status endpoints.

---

## Documentation and guidance

- [Hermes Agent documentation](https://hermes-agent.nousresearch.com/docs/)
- [Hermes Agent on GitHub](https://github.com/NousResearch/hermes-agent)
- [Workshop documentation](https://ubuntu.com/workshop/docs/)

---

## Community and support

- Nous Research community:
  [Discord](https://discord.gg/jqVphNsB4H) /
  [GitHub Discussions](https://github.com/NousResearch/hermes-agent/discussions)
- Workshop forum:
  [Discourse](https://discourse.ubuntu.com/)
- Please review our
  [Code of Conduct](https://ubuntu.com/community/ethos/code-of-conduct)
  before participating.

---

## Contributions

All contributions, including code, documentation updates, and issue
reports, are welcome!

- See `CONTRIBUTING.md` for guidelines (forthcoming).
- Open issues or pull requests on the official repository.

---

## License and copyright

Copyright 2026 Matias Piipari.

This SDK is licensed under the
[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).

The Hermes Agent itself is developed by Nous Research; consult its
repository for its upstream license terms.
