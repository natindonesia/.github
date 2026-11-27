# qa-harness

Read a repository's `qa.yml`, start the product it describes, and stop it again.

Four commands, because they run at four moments and only one of them may fail the
build:

| command | when | may fail the run |
|---|---|---|
| `resolve` | before the scope gate | yes -- a contract that does not parse is a repository bug |
| `up` | after the gate | yes -- a product that never answers is an environment failure |
| `environment` | after `up` | no |
| `down` | `always()` | no |

`resolve` also does the two checks that keep the gate honest:

- every image must come from `ghcr.io/natindonesia/<repo>`, so a pull request
  cannot point the gate at an image it did not build;
- the image built from the change may not resolve to the same image as its
  baseline, so a run cannot compare a change to itself.

When the baseline image is missing or will not start, `up` degrades to single
mode instead of failing: a missing baseline is a fact about the repository's
build history, not a verdict about the change. The degradation is recorded in the
step summary, in `environment.json`, and in the note the agent reads.

`up` then starts the product in the order the contract implies: the `seed`
service to completion if the compose file has one (it lives in the `seed`
profile, so `up` itself cannot start it), then `up --wait`, then the declared
URLs. Hostnames in `urls` are pointed at `127.0.0.1` on the runner, so a product
that resolves one site per hostname can be declared by that name. An answer of
`404` is not the product being up -- for those products it is the
site-does-not-exist page, and an agent handed it would blame the change.

## Inputs and outputs

`resolve` -> `product-paths`, `after-image`, `before-image`, `mode`, `urls`,
`accounts`, `focus`, `max-budget`, `max-iterations`, `agent-timeout`.

`up` -> `mode` (possibly degraded), `probes`, `notes`.

See the top-level README for the `qa.yml` and `compose.verify.yaml` contracts.
