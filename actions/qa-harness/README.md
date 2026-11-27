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

## Inputs and outputs

`resolve` -> `product-paths`, `after-image`, `before-image`, `mode`, `urls`,
`accounts`, `focus`, `max-budget`, `max-iterations`, `agent-timeout`.

`up` -> `mode` (possibly degraded), `probes`, `notes`.

See the top-level README for the `qa.yml` and `compose.verify.yaml` contracts.
