# .github

Organisation-wide community health files, and the GitHub Actions that more than
one repository in `natindonesia` runs.

## Actions

| Action | What it is for |
|---|---|
| [`publish-evidence`](actions/publish-evidence) | Upload a QA run's evidence -- screenshots, recordings, PDFs, traces -- repoint the report's local links at them, and post the result as a pull request comment. |
| [`qa-verdict`](actions/qa-verdict) | Score that report and publish the `assurance/verified` check run, failing closed when there is no report. |
| [`qa-setup`](actions/qa-setup) | Install the toolchain around the agent: Python, uv, Playwright, ffmpeg, gh. Blind to the product. |
| [`qa-harness`](actions/qa-harness) | Read `qa.yml`, start the product a change provides, probe it, write down what the agent is getting, and stop it. |
| [`qa-agent`](actions/qa-agent) | Ask an agent to verify the change by using the running product, and require it to keep observation apart from judgement. |

Everything is a composite action or a reusable workflow, and is versioned by tag:

```yaml
- uses: natindonesia/.github/actions/publish-evidence@v1
- uses: natindonesia/.github/.github/workflows/qa-verify.yml@v1
```

`v1` moves: a fix to a shared action has to reach its consumers, so the major
tag is force-updated and `v1.0`, `v1.1` … are the immutable points. A workflow
whose result must be reproducible byte for byte should pin one of those, or the
commit itself.

The actions exist because two repositories had the same ~150 lines of shell
copied into their `verify.yml`: install the AWS CLI, upload to the evidence
bucket, rewrite relative links, post a comment, then parse the verdict. The copy
drifted, the rewrite was only ever tested in one of them, and a fix to the link
handling had to be made twice.

## The verification pipeline

[`qa-verify.yml`](.github/workflows/qa-verify.yml) is the whole gate. It exists
because six repositories had the same `verify.yml` -- the same checkouts, the
same scope gate, the same agent invocation, the same evidence upload, the same
verdict -- and the copies had already diverged: one had reimplemented the verdict
in ninety lines of Python, two could not compare against a baseline at all.

A repository now contributes only what it alone knows: the images, where they
answer, who can sign in, and how to start them.

### Who is responsible for what

| Item | App | Agent | Common |
|---|---|---|---|
| `verify.yml` caller, `permissions:`, `runs-on` input | ✔ | | |
| `product-paths`: which files can change the product | ✔ | | |
| Toolchain and build (Flutter, Go, Node, Frappe) in the repo's own build workflow | ✔ | | |
| Publish the image built from the change, and pass its ref in | ✔ | | |
| Name the baseline image in `qa.yml`, as `{base_sha}` | ✔ | | |
| `compose.verify.yaml`: services, dependencies, healthchecks; a `seed` service in the `seed` profile, or seeding inside the service when the schema only exists once it serves | ✔ | | |
| `fixtures/qa`: the seed that decides what the agent signs in to | ✔ | | |
| Declare `urls` and `accounts`, plus an optional `focus:` | ✔ | | |
| Budget, iterations and timeout, capped by Common | ✔ | | |
| `concurrency`, base and head checkouts | | | ✔ |
| Refuse a change that edits its own verifier | | | ✔ |
| Scope gate: diff against `product-paths` | | | ✔ |
| Resolve the image refs; refuse a package the base branch's contract does not name | | | ✔ |
| Refuse a "change" whose image is identical to its baseline | | | ✔ |
| Log in, pull both images | | | ✔ |
| Degrade to single mode when there is no baseline to compare against | | | ✔ |
| Run `seed` to completion, then `docker compose up --wait` | | | ✔ |
| Probe the declared URLs before the agent starts | | | ✔ |
| Python, uv, Playwright, ffmpeg, gh | | | ✔ |
| Write the note that says what the agent is being given | | | ✔ |
| Tell the agent it may not build, install or start anything | | | ✔ |
| Require observation and judgement to be written separately | | | ✔ |
| Read the pull request discussion with `gh` | | ✔ | |
| Decide what a user would do to reach the changed behaviour | | ✔ | |
| Decide what to capture, and how to compare the two revisions | | ✔ | |
| Decide what a difference means: intended, or a regression | | ✔ | |
| Choose the report's shape; embed any file type | | ✔ | |
| State the verdict | | ✔ | |
| Put everything the report references in the evidence directory | | ✔ | |
| Upload every file type, encode each recording as an animated AVIF, repoint links | | | ✔ |
| Comment on the pull request; keep an artifact fallback | | | ✔ |
| Fall back to the agent's review when no report file was written | | | ✔ |
| `assurance/verified`, not-applicable, fail closed when there is no verdict | | | ✔ |
| Stop the project, capture and upload the product log | | | ✔ |

### What a repository provides

**`.github/workflows/verify.yml`** -- the caller, and nothing else:

```yaml
name: verify
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
  pull-requests: write
  issues: write
  checks: write
  packages: read
concurrency:
  group: verify-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  qa:
    uses: natindonesia/.github/.github/workflows/qa-verify.yml@v1
    secrets: inherit
    with:
      after-image: ${{ needs.build.outputs.image }}
```

**`.github/qa.yml`** -- the contract. Read from the base branch, never from the
pull request, so a change cannot describe itself as needing less verification.
Every verifier file is read that way, including the seed in `fixtures/qa`: mount
it from the checkout into the `seed` service (`./fixtures/qa:/qa-fixtures:ro`)
rather than running the copy that happens to be inside the image under test,
because a change that can edit its own fixture is judging itself.

```yaml
product-paths: '^(src/|vite\.|Dockerfile$|package-lock\.json$)'

images:
  # `after` is normally passed in from the build job; this is the fallback.
  after: ghcr.io/natindonesia/fayolearn-web-frontend:pr-${{ github.event.pull_request.number }}
  before: ghcr.io/natindonesia/fayolearn-web-frontend:{base_sha}

urls:
  after: http://127.0.0.1:8200
  before: http://127.0.0.1:8100   # omit for single mode

accounts:
  - role: admin
    email: qa-admin@fayolex.local
    password: QaVerification2026!
  - role: member
    email: member@qa.fayolex.local
    password: QaVerification2026!

focus: Course catalogue, enrolment, and switching tenants as an admin.

agent:
  max-budget: 0.75
  max-iterations: 60
  agent-timeout: 18
```

`{base_sha}` and `{head_sha}` are substituted into image names. Passwords reach
the agent as `QA_PASSWORD_<ROLE>` and are deliberately not written into the
evidence directory, which is published to a public bucket. An account with no
`password` is a passwordless one -- an email link, a passkey -- and the agent is
told to sign in the way the product signs people in.

The images are pulled with the workflow token, which reads this repository's own
packages. A compose file that starts *another* repository's private package --
a shared backend, a runtime base -- needs a token that can read it: pass
`secrets.GHCR_READ_TOKEN` from the caller (`secrets: inherit` is enough) and set
it to a fine-grained PAT with `read:packages`, or add this repository to that
package's access list.

**`compose.verify.yaml`** -- how the product starts:

```yaml
services:
  after:
    image: ${AFTER_IMAGE:?set by the pipeline}
    profiles: [after]
    ports: ["8200:80"]
    depends_on:
      db: {condition: service_healthy}
  before:
    image: ${BEFORE_IMAGE:?set by the pipeline}
    profiles: [before]
    ports: ["8100:80"]
    depends_on:
      db: {condition: service_healthy}
  db:
    image: postgres:16
    healthcheck: {test: ["CMD", "pg_isready"], interval: 2s, retries: 30}
  seed:
    image: ${AFTER_IMAGE:?set by the pipeline}
    # Its own profile, so `up` never starts it: the pipeline runs it first.
    profiles: [seed]
    command: ["./seed.sh"]
    depends_on:
      db: {condition: service_healthy}
```

The pipeline sets `AFTER_IMAGE`, `BEFORE_IMAGE`, `QA_MODE` and `QA_PROJECT`, runs
the `seed` service to completion if there is one, enables the profiles for the
chosen mode, runs `up --wait`, and finally waits until the declared URLs answer.
Ports published here must match `urls` in `qa.yml`.

Two things about this file that are easy to get wrong, both of them silent:

- **Shell variables are `$$NAME`, not `$NAME`.** Compose interpolates `$NAME`
  itself, from the host environment, before the container sees the command --
  `--admin-password "$ADMIN_PASSWORD"` reaches the container as
  `--admin-password ""` and the product either prompts for input that is not
  coming or starts with an empty secret.
- **Seeding runs before anything serves, not after.** A site created while a
  server is already up is a site that server may not know about, and the first
  request after seeding is exactly the one the agent makes.
- **Unless the service creates its own schema.** A product that applies
  migrations on startup has no table to seed until it is serving, so it cannot
  use the `seed` step. It seeds from the checkout inside its own service instead,
  and reports healthy only once the seeded account can actually sign in -- `up
  --wait` then means "up *and* enterable", rather than "listening, probably".
- **A database user that exists is not a database user that can log in.** Frappe's
  `bench new-site` grants the site's user to the host it connected from, which is
  the seed container's IP. That container exits, Docker hands its address to one
  of the containers that then serve the product, and the other revision answers
  `1045 Access denied` -- different run, different victim. Pass
  `--mariadb-user-host-login-scope='%'`, and have the seed check the grant rather
  than assume it, because the stack looks healthy either way.

A `urls` entry may name a hostname rather than `127.0.0.1` -- `http://qa.localhost:8200`
-- which is how a product that resolves one site per hostname (Frappe, anything
multi-tenant) can be reached at all. The pipeline points the declared hostnames
at `127.0.0.1` on the runner. It also refuses to call a URL "up" when it answers
`404`: for those products that is the site-does-not-exist page, and handing it to
the agent would turn an environment failure into a verdict about the change.

### Before and after

Compare mode is on when `images.before` and `urls.before` are both declared. The
baseline is the image published for the commit the pull request is based on, so
the two revisions differ only by the change.

When the baseline is missing -- no image for that commit, or an image that will
not start -- the run degrades to single mode and says so: in the note the agent
reads, in the evidence, and in the step summary. It does not fail, because a
missing baseline is a fact about the repository's build history, not a verdict
about the change.

Give `before` no healthcheck:

```yaml
  before:
    image: ${BEFORE_IMAGE:?set by the pipeline}
    profiles: [before]
    healthcheck:
      disable: true
```

The harness starts the project detached and polls it, so everything else has to
reach running and healthy; `before` is only observed, and the probe that follows
decides whether there is a comparison. `compose up --wait` cannot be used for
this: it fails the whole run for a service that declares no healthcheck, and it
fails for a container that exits -- which is exactly the baseline that is
supposed to degrade quietly.

What the change is compared to must be the change: an `after` image carrying a
revision label that disagrees with the head commit is refused, and so is an
`after` that resolves to the same image as its `before`.

### The two things the agent is told

Everything else about the agent's work is its own judgement. These are not:

1. **It may not build anything.** No `docker build`, no installs, no restarts. A
   product that is not running is an environment failure and is caught before the
   agent starts -- so an agent that reports "could not verify" is telling the
   truth about the change, not about its own setup.
2. **Observation is not judgement.** Observations are reproducible and carry an
   evidence link; judgements name the observations they rest on; anything not
   exercised is listed as unverified. The report's shape is the agent's, but it
   must begin with `## QA Report: PASS | PASS WITH ISSUES | FAIL | PARTIAL`,
   because that heading is what the check run reads.

### The contract the agent writes against

The agent never learns about object storage, and Common never goes looking for
it. One path is agreed before the run: `qa-report.md` in the evidence directory,
started from the template the agent is handed
([`report.template.md`](actions/qa-agent/report.template.md)). Whatever the agent
captures lives beside it, and the pipeline uploads that directory. Anything left
somewhere else is the agent's mistake and stays unpublished -- the run does not
grow a search path that changes from run to run.

The agent writes a report next to its captures, with ordinary relative links:

```markdown
## QA Report: PASS WITH ISSUES

| state | capture |
|---|---|
| before | ![before](./before-home.png) |
| after  | ![after](./after-home.png) |

A recording: [the same clip](./after-flow.mp4).
A document: [login spec](./login-spec.pdf).
```

`publish-evidence` uploads every file in the directory, rewrites markdown links
and HTML `src`/`href` to public URLs, encodes an animated AVIF from each
recording so a reviewer sees it move without downloading an mp4 -- a comment
cannot play a video -- and posts the document. A link to a file that was never
captured fails the step rather than rendering as a broken image.

## Self-test

[`actions.yml`](.github/workflows/actions.yml) does three things on every change
here:

- runs `publish-evidence` and `qa-verdict` against a fixture in dry-run mode, and
  asserts that links are repointed (images, recordings, PDFs, traces), that
  external links are left alone, that a broken link is rejected, that the uncited
  gallery appears once, and that each verdict branch resolves correctly;
- lints every workflow with `actionlint`;
- calls `qa-verify.yml` end to end with a two-nginx fixture standing in for a
  product, in dry-run mode, so the compose contract, the probes and the teardown
  are exercised without an agent, a bucket, or a pull request.

Nothing touches the bucket.
