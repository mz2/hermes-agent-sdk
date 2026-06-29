# Hermes Agent SDK for Workshop

This SDK packages the [Hermes Agent](https://github.com/NousResearch/hermes-agent)
for [Workshop](https://ubuntu.com/workshop).

Hermes is a self-improving AI agent from Nous Research that creates skills from
experience, maintains persistent memory, and bridges to messaging platforms
(Telegram, Discord, Slack, Signal, Email) via its gateway daemon.

## What This SDK Provides

- Pre-built Hermes runtime in the SDK payload (no Python env bootstrap at launch)
- Persistent agent state in `~/.hermes` via mount plugs
- Separate persistent secrets mount at `~/.hermes/secrets`
- A systemd user service (`hermes-gateway.service`) for the gateway
- Tunnel plugs for LLM (`11434`) and optional external memory backend (`8000`)

## Quick Start

Minimal `workshop.yaml` pairing Hermes with a host-local Ollama-compatible
endpoint:

```yaml
name: hermes
base: ubuntu@24.04

sdks:
  - name: hermes-agent
    channel: latest/stable
  - name: system
    slots:
      llm-backend:
        interface: tunnel
        endpoint: localhost:11434

connections:
  - plug: hermes-agent:llm-backend
    slot: system:llm-backend

actions:
  chat: hermes chat "$@"
```

Then:

```bash
workshop launch
workshop connect hermes/hermes-agent:llm-backend hermes/system:llm-backend
workshop run hermes chat
```

## Running Hermes

```bash
workshop exec hermes -- hermes --version
workshop exec hermes -- hermes chat
workshop shell hermes
hermes gateway start
```

## Configuration

### LLM Backend

The default `~/.hermes/config.yaml` points to:

- `http://localhost:11434/v1`

For hosted providers (OpenAI, OpenRouter, Anthropic-compatible APIs), update
`~/.hermes/config.yaml` and place credentials in `~/.hermes/secrets/.env`.

### Messaging Credentials

Credentials live in:

- `~/.hermes/secrets/.env`

`setup-project` symlinks `~/.hermes/.env` to `secrets/.env` so both the CLI and
the gateway service use the same file.

The SDK enables the gateway unit during setup but does not auto-start it on
first install. If you start it yourself, refreshes preserve that running state:
the SDK records whether the unit was active before refresh and starts it again
after restore.

## Interfaces

### Plugs (consumed)

- `hermes-home` (`mount` -> `/home/workshop/.hermes`): agent config and state
- `hermes-secrets` (`mount` -> `/home/workshop/.hermes/secrets`): secrets only
- `llm-backend` (`tunnel` -> `11434`): Ollama-compatible OpenAI endpoint
- `memory-backend` (`tunnel` -> `8000`): optional external memory service

### Slots (provided)

- `gateway` (`tunnel` -> `8765`): gateway loopback presence for host tooling

## Development

See `CONTRIBUTING.md` for local build/test workflow.

## License

This SDK repository is licensed under the [MIT License](LICENSE).
