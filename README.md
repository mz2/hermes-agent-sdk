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

### Prerequisites, project layout

1. No prerequisite SDKs are required, but the SDK is most useful paired
   with an LLM provider — either an `ollama` workshop wired via the
   `llm-backend` plug, or a remote endpoint (OpenAI / Anthropic /
   OpenRouter / NovitaAI) configured in `~/.hermes/config.yaml`.
2. No specific project layout is needed. The project directory at
   `/project` is available to the agent for file tools, code execution,
   and `hermes skill` development.
3. On launch the SDK installs uv, clones `NousResearch/hermes-agent` at
   the SDK's pinned VERSION, builds a Python 3.11 virtualenv, fetches
   Node 22 (required by the WhatsApp bridge — Ubuntu 24.04's apt Node is
   too old), installs Playwright Chromium, writes a default `config.yaml`
   if absent, and starts the gateway as a systemd user unit.
4. Supported on `amd64` and `arm64`. The setup hook auto-selects the
   right Node 22 tarball via `dpkg --print-architecture`; Playwright
   Chromium and Python wheels are also available for both arches.

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

**Manage from a host directory** (agenix, sops, plain host file). The
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

```bash
workshop shell
hermes chat
```

Pass model overrides on the command line:

```bash
hermes chat --model openrouter/anthropic/claude-3.5-sonnet
```

### Verify from the command line

```bash
workshop shell
hermes --version
systemctl --user status hermes-gateway
```

---

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
  a host-side secret manager (agenix, sops, plain file) without taking
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

#### Host-reachable Ollama (same machine, or LAN)

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

A remote HTTPS provider is reached over the workshop's normal outbound
internet connection, so there is **no tunnel to wire** — the `llm-backend`
plug and the `system:` slot are only needed for a host-local Ollama. Three
steps:

1. **Use a plain workshop.yaml** — no `system` slot, no `connections:`:

   ```yaml
   name: hermes
   base: ubuntu@24.04
   sdks:
     - name: hermes-agent
       channel: latest/stable
   ```

2. **Point the model config at the provider.** Edit `~/.hermes/config.yaml`
   (inside the workshop: `workshop shell` then your editor) so the `model:`
   block names the provider's OpenAI-compatible endpoint and model. For
   OpenRouter:

   ```yaml
   model:
     provider: custom
     default: anthropic/claude-3.5-sonnet     # a model the provider offers
     base_url: https://openrouter.ai/api/v1   # the provider's /v1 endpoint
     api_key: ${OPENROUTER_API_KEY}           # read from the .env below
   ```

   (For OpenAI use `https://api.openai.com/v1`; for Anthropic's
   OpenAI-compatible endpoint use `https://api.anthropic.com/v1`.)

3. **Put the API key in secrets.** Add it to `~/.hermes/secrets/.env`, then
   restart the gateway:

   ```bash
   echo 'OPENROUTER_API_KEY=sk-or-...' >> ~/.hermes/secrets/.env
   systemctl --user restart hermes-gateway
   ```

See `examples/workshop.remote-openai.yaml` for a complete runnable variant
with `set-token` / `set-endpoint` actions that do steps 2–3 for you.

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
