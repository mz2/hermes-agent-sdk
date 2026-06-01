# Contributing

This SDK is defined by `sdkcraft.yaml`, the `hooks/` scripts, and the bundled
`services/` unit. The agent runtime itself is installed at launch by
`hooks/setup-project`, not built into the package.

## Build and try locally

Build a local SDK (no Store upload) and run it against the examples:

```bash
git checkout latest
sdkcraft try                 # packs amd64+arm64, registers as `try-hermes-agent`
cd examples
workshop launch --verbose    # first launch 5 to 10 min; refreshes are fast
workshop connect hermes/hermes-agent:llm-backend hermes/system:llm-backend
workshop run hermes chat
```

## Iterate

Edit `sdkcraft.yaml` or `hooks/`, re-run `sdkcraft try`, then `workshop refresh`
(not remove+launch). `setup-project` is idempotent: on refresh it short-circuits
when the version matches, or upgrades in place.

> In `connections:`, reference the plug by the SDK's real name `hermes-agent`,
> **not** `try-hermes-agent`. The `try-` prefix is reserved in plug/slot
> references.

## Submitting

Open issues or pull requests on the repository. CI runs `sdkcraft test` and a
branch-parity check, so make sure both pass locally before pushing.
