# Hermes Agent SDK for Workshop

This SDK provides the [Hermes Agent](https://github.com/NousResearch/hermes-agent),
a self-improving AI agent from Nous Research that creates skills from
experience, maintains persistent memory, and bridges to messaging platforms
(Telegram, Discord, WhatsApp, Slack, Signal, Email) via its gateway daemon.
The agent's home directory, virtualenv, uv/npm caches, and Playwright
Chromium download are persisted on the host so workshop updates do not redo
the multi-minute install.

---

## Reference workshop

A minimal workshop:

```yaml
# workshop.yaml
name: hermes-dev
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

The `check-health` hook reports `waiting` with a remediation hint while
the gateway is not active, so `workshop status` surfaces guidance.

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

### `hermes-home`

- Interface: `mount`
- Workshop target: `/home/workshop/.hermes`
- Mode: `0o700`
- Purpose: The agent's home tree — `config.yaml`, `.env`, `SOUL.md`,
  persistent memory, skills, sessions, the editable `hermes-agent/` git
  clone, the Python venv, and the bundled Node 22. Persisting the whole
  tree means `workshop refresh` skips the multi-minute reinstall when
  the SDK's VERSION is unchanged.

### `uv-cache`

- Interface: `mount`
- Workshop target: `/home/workshop/.cache/uv`
- Purpose: uv resolver/install cache. Reused across version bumps to
  speed up dependency updates.

### `npm-cache`

- Interface: `mount`
- Workshop target: `/home/workshop/.npm`
- Purpose: npm download cache for the WhatsApp bridge (Baileys and
  transitive deps).

### `playwright-cache`

- Interface: `mount`
- Workshop target: `/home/workshop/.cache/ms-playwright`
- Purpose: Playwright's browser bundle (~300MB). Avoids re-downloading
  Chromium on every refresh.

### `hermes-secrets`

- Interface: `mount`
- Workshop target: `/home/workshop/.hermes/secrets`
- Mode: `0o700`
- Purpose: Dedicated mount for credentials (`.env`). Narrower than
  `hermes-home` so the host can manage just the secrets directory with
  a host-side secret manager (agenix, sops, plain file) without taking
  over `~/.hermes`'s caches and state. `setup-project` symlinks
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

For HTTPS providers reached over the public internet, skip the tunnel
wiring entirely — the workshop's outbound network reaches them
directly. Edit `~/.hermes/config.yaml` to set `model.provider` and
`model.base_url`, and add the matching API key to
`~/.hermes/secrets/.env`.

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
