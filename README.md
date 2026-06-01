# Hermes Agent SDK for Workshop

This SDK packages the [Hermes Agent](https://github.com/NousResearch/hermes-agent)
for [Workshop](https://ubuntu.com/workshop), Canonical's tool for reproducible,
sandboxed development environments. Hermes is a self-improving AI agent from
Nous Research that creates skills from experience, maintains persistent memory,
and bridges to messaging platforms (Telegram, Discord, WhatsApp, Slack, Signal,
Email) via its gateway daemon.

Your config, state, and secrets (under `~/.hermes`) persist across rebuilds via
mount plugs; the agent runtime is reinstalled into the workshop sandbox as
needed. See [Persistence model](#persistence-model).

---

## Quick start

A minimal `workshop.yaml` pairing the agent with a host-local, Ollama-compatible
LLM endpoint:

```yaml
name: hermes
base: ubuntu@24.04

sdks:
  - name: hermes-agent
    channel: latest/stable

  # The `system` SDK exposes a host endpoint as a tunnel slot.
  - name: system
    slots:
      llm-backend:
        interface: tunnel
        endpoint: localhost:11434   # Ollama / vLLM / LiteLLM on the host

connections:
  - plug: hermes-agent:llm-backend
    slot: system:llm-backend

actions:
  chat: hermes chat "$@"
```

```bash
workshop launch
# Tunnels do not auto-connect; wire the LLM backend once after launch:
workshop connect hermes/hermes-agent:llm-backend hermes/system:llm-backend
workshop run hermes chat
```

For a hosted provider instead of a local Ollama, see
[Choosing an LLM backend](#choosing-an-llm-backend). Runnable variants live in
[`examples/`](examples/): `workshop.yaml` (host Ollama),
`workshop.remote-openai.yaml` (hosted provider), and `workshop.with-mcp.yaml`
(with an MCP server).

On first launch the SDK installs uv, clones `NousResearch/hermes-agent` at the
pinned `VERSION`, builds a Python 3.11 venv, fetches Node 22 (for the WhatsApp
bridge), installs Playwright Chromium, writes a default `config.yaml` if absent,
and starts the gateway as a systemd user unit. This takes roughly 5 to 10
minutes; later `workshop refresh`es are fast.

---

## Running the agent

The `hermes` CLI runs **inside the workshop** (a wrapper at `~/.local/bin/hermes`
puts the bundled Node 22 on `PATH`); it is not installed on the host. Invoke it
through `workshop`, three equivalent ways:

```bash
# 1. One-off command (a TTY is forwarded, so interactive chat works):
workshop exec hermes -- hermes chat
workshop exec hermes -- hermes --version

# 2. Interactive shell, then use hermes directly:
workshop shell hermes

# 3. A named action from workshop.yaml (forwards trailing args):
workshop run hermes chat -- --model openrouter/anthropic/claude-3.5-sonnet
```

(Omit the workshop name `hermes` if the project has only one workshop.)

---

## Configuration

### Messaging credentials

The gateway sits in `activating`/`failed` until credentials are in place, and
the `check-health` hook reports `waiting` with a hint until then. Credentials
live in `~/.hermes/secrets/.env` (the `hermes-secrets` mount); `setup-project`
symlinks `~/.hermes/.env` to `secrets/.env` so the CLI and gateway see the same
file.

Edit them from inside the workshop:

```bash
workshop shell
$EDITOR ~/.hermes/secrets/.env
# e.g. TELEGRAM_BOT_TOKEN=..., DISCORD_BOT_TOKEN=...
systemctl --user restart hermes-gateway
```

To manage secrets from the **host** instead, point the `hermes-secrets` mount
at a host directory. It is separate from `hermes-home` so you can do this
without owning the rest of `~/.hermes`:

```bash
workshop remount <workshop>/hermes-agent:hermes-secrets ~/secrets/hermes
workshop exec <workshop> -- systemctl --user restart hermes-gateway
```

The SDK depends on no secret manager. `hermes-secrets` is just a mount, so what
backs it is your choice ([agenix](https://github.com/ryantm/agenix),
[sops](https://github.com/getsops/sops), a plain host file, or an age-encrypted
file decrypted at login into a tmpfs that you then remount).

### Choosing an LLM backend

The default `config.yaml` points at `http://localhost:11434/v1`, so the agent
works out of the box once something answers on port 11434.

- **Host-local or sibling-workshop Ollama**: wire the `llm-backend` tunnel plug
  to the endpoint (see [Quick start](#quick-start), or connect it to an `ollama`
  SDK's slot). No config changes needed.
- **Hosted provider (OpenAI, Anthropic, OpenRouter, ...)**: no tunnel is needed.
  The workshop reaches HTTPS providers over its normal outbound network. Set the
  `model:` block in `~/.hermes/config.yaml` and add the key to `secrets/.env`:

  ```yaml
  # ~/.hermes/config.yaml
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

  (OpenAI: `https://api.openai.com/v1`; Anthropic: `https://api.anthropic.com/v1`.)
  See [`examples/workshop.remote-openai.yaml`](examples/workshop.remote-openai.yaml).

---

## MCP servers

To give Hermes tools from an external
[MCP](https://modelcontextprotocol.io/) server, two separate pieces are
involved:

| | What it is | Lives in | When you need it |
| --- | --- | --- | --- |
| **`mcp_servers:` block** | Hermes config listing the servers to load | `~/.hermes/config.yaml` | For every MCP server you add |
| **`mcp-server` plug** | A Workshop network tunnel to a server in *another* workshop | `workshop.yaml` | Only for an HTTP server in a sibling workshop |

Every server you want is declared in the `mcp_servers:` block. The `mcp-server`
*plug* is just plumbing that makes a sibling workshop's HTTP server reachable; on
its own it does not tell Hermes to use anything.

Each entry in `mcp_servers:` uses one transport:

- **stdio** (`command:`): Hermes spawns the server as a subprocess. Use it when
  the server's binary is in the **same** workshop; no plug needed. Works best for
  interactive `hermes chat`. The gateway daemon runs with a minimal `PATH`, so
  for it either use HTTP or give `command:` an absolute path.
- **HTTP** (`url:`): the server runs elsewhere as its own process. For a server
  in a **sibling workshop**, connect the `mcp-server` plug to its HTTP slot; it is
  then reachable at `http://localhost:3000/mcp`, the `url:` you point at. This is
  the reliable choice for the gateway daemon.

Scope what Hermes sees per server with a `tools:` block:

- `include:` / `exclude:` lists select which tools are exposed. Prefer an
  `include:` allowlist for servers that can write or delete.
- `resources: false` / `prompts: false` drop the MCP resource and prompt wrappers.

### Registering a server

Use the `mcp-add` action, which edits `config.yaml` and reloads the gateway. (Or
hand-edit the `mcp_servers:` block directly, using the commented template already
in `config.yaml`, then restart the gateway or run `/reload-mcp` in chat.) It
merges by name, so re-running updates an entry in place:

```bash
# HTTP server in a sibling workshop, with an auth header from secrets/.env:
workshop run hermes mcp-add -- affine --url http://localhost:3000/mcp \
    --header 'Authorization: Bearer ${AFFINE_MCP_HTTP_TOKEN}'

# stdio server in the same workshop:
workshop run hermes mcp-add -- weather --command weather-mcp --env API_KEY=xyz

# remove an entry:
workshop run hermes mcp-add -- affine --remove
```

It applies the `resources: false` / `prompts: false` scoping by default
(`--keep-resources` / `--keep-prompts` to opt out, `--include TOOL` for an
allowlist). For a server that writes its token to a dotenv, `--bearer-from FILE
--bearer-var NAME` copies that token into `secrets/.env` and sets the
`Authorization: Bearer ${NAME}` header. It rewrites `config.yaml` through PyYAML,
so inline comments in that file are not preserved.

### Example: AFFiNE over HTTP (sibling workshop)

Pair the agent with the `affine-mcp-server` SDK, which runs its own HTTP
transport and exposes it as the `affine-mcp-http` slot. See
[`examples/workshop.with-mcp.yaml`](examples/workshop.with-mcp.yaml) for the
complete runnable file.

```yaml
# workshop.yaml: add the SDK and wire the plug to its HTTP slot
sdks:
  - name: hermes-agent
    channel: latest/stable
  - name: affine-mcp-server
    channel: latest/stable

connections:
  - plug: hermes-agent:mcp-server
    slot: affine-mcp-server:affine-mcp-http
```

The AFFiNE server generates its own bearer token on first launch. Point
`mcp-add` at the server's dotenv with `--bearer-from`; it copies that token into
`secrets/.env` and sets the auth header for you:

```bash
workshop run hermes mcp-add -- affine --url http://localhost:3000/mcp \
    --bearer-from ~/.config/affine-mcp/.env --bearer-var AFFINE_MCP_HTTP_TOKEN
workshop run hermes chat   # ask "Which MCP tools are available?" to confirm
```

> Across separate workshops the wiring is the same, but connect the plug by hand
> after launch: `workshop connect <hermes-ws>/hermes-agent:mcp-server
> <affine-ws>/affine-mcp-server:affine-mcp-http`.

---

## Interfaces

### Persistence model

Only your config, state, and secrets are mounted and persisted: everything
under `~/.hermes` (`config.yaml`, memory, skills, sessions, and `secrets/.env`).
The agent runtime is installed into the workshop sandbox, not onto host storage.
It survives `workshop refresh` and is rebuilt automatically only on a full
recreate, so you never need to back it up.

### Plugs (consumed)

| Plug | Interface | Endpoint / target | Purpose |
| --- | --- | --- | --- |
| `hermes-home` | mount | `~/.hermes` (`0o700`) | Agent config and state: `config.yaml`, `.env` (symlink), `SOUL.md`, memory, skills, sessions. Auto-connects to Workshop storage; survives `refresh`. |
| `hermes-secrets` | mount | `~/.hermes/secrets` (`0o700`) | Credentials (`.env`), as a narrower mount so the host can manage just the secrets. See [Messaging credentials](#messaging-credentials). |
| `llm-backend` | tunnel | `11434` | Ollama-compatible OpenAI endpoint. See [Choosing an LLM backend](#choosing-an-llm-backend). |
| `memory-backend` | tunnel | `8000` | Optional external memory service (e.g. a mem0/hindsight SDK) instead of built-in markdown memory. |
| `mcp-server` | tunnel | `3000` | HTTP MCP server in a sibling workshop. See [MCP servers](#mcp-servers). |
| `cognee-plugin` | mount | `~/.hermes/plugins/cognee_local` (`0o755`) | Optional memory-provider plugin delivered by mount (e.g. from the cognee-hermes-memory SDK). |

To manage a mount on a host path: `workshop stop <ws>`, then
`workshop remount <ws>/hermes-agent:<plug> <host-path>`, then `workshop start <ws>`.

### Slots (provided)

| Slot | Interface | Endpoint | Purpose |
| --- | --- | --- | --- |
| `gateway` | tunnel | `8765` | Exposes the gateway's loopback presence so host tooling can probe `hermes gateway` status endpoints. |

---

## Documentation and support

- [Hermes Agent docs](https://hermes-agent.nousresearch.com/docs/) ·
  [GitHub](https://github.com/NousResearch/hermes-agent) ·
  [Discord](https://discord.gg/jqVphNsB4H) ·
  [Discussions](https://github.com/NousResearch/hermes-agent/discussions)
- [Workshop docs](https://ubuntu.com/workshop/docs/) ·
  [Forum](https://discourse.ubuntu.com/)
- Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the
  local build/test workflow, and the
  [Code of Conduct](https://ubuntu.com/community/ethos/code-of-conduct) before
  participating.

---

## License

Copyright 2026 Matias Piipari. Licensed under the
[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).
The Hermes Agent itself is developed by Nous Research; consult its repository
for upstream license terms.
