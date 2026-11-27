# qa-agent

Ask an agent to verify a pull request by using a product that is already running.

It is not the upstream `qa-changes` plugin, and the difference is deliberate. That
plugin's prompt tells the agent to set the environment up itself and to post its
findings as a pull request review. Here:

- the product is started before the agent runs, from images the repository
  published, so the agent cannot spend its budget rebuilding the environment and
  a broken build cannot arrive as a verdict about the change;
- the report is a file, so `publish-evidence` can publish it and `qa-verdict` can
  score it;
- the agent works in a scratch directory, never in the change, so project skills
  discovered from the working directory are never the change's own.

Two rules are Common's, not the agent's:

1. **Never build.** No `docker build`, no installs, no restarts. A product that is
   not up is caught before the agent is called.
2. **Observation is not judgement.** Observations are reproducible and carry an
   evidence link; judgements name the observations they rest on; anything not
   exercised is listed as unverified.

The rest -- what to open, what to capture, how to compare the two revisions, what
a difference means, and the shape of the report -- is the agent's call.

## One agreed path

The agent is handed [`report.template.md`](report.template.md) and told to write
`qa-report.md` in the evidence directory. It also owns the directory: anything
the report references has to be there, with a relative name, because that is what
gets uploaded. Common reads that one file and no other, and does not search the
filesystem for what the agent forgot to move.

The template is not enforced. What is enforced is the heading -- `## QA Report:
PASS | PASS WITH ISSUES | FAIL | PARTIAL` -- because the check run reads it, and
`publish-evidence` refuses a report whose links point at captures that were never
uploaded. The one
structural requirement is the verdict heading, `## QA Report: PASS | PASS WITH
ISSUES | FAIL | PARTIAL`, because the check run reads it.

## Runtime pins

`litellm`, `openhands-sdk` and `openhands-tools` are pinned in `action.yml`. A
model whose tool layer changed under it is a different judge, so the pins move
with a release, not with a merge.
