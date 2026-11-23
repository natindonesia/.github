# qa-verdict

Score a QA report and publish the `assurance/verified` check run.

```yaml
- uses: natindonesia/.github/actions/qa-verdict@v1
  if: always()
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  with:
    pr-number: ${{ github.event.pull_request.number }}
    head-sha: ${{ github.event.pull_request.head.sha }}
    report-path: ${{ steps.evidence.outputs.rendered-report }}
```

## Where the report comes from

1. `report-path` — the rendered document from `publish-evidence`, which is what
   a reviewer actually saw.
2. A review on the pull request, but only one submitted against `head-sha`.
   GitHub stamps reviews with the commit they were made on; without that filter
   a failed run inherits a previous PASS, which is the exact failure a gate is
   for.
3. Nothing.

## Verdicts

| Heading in the report | Check conclusion | Title |
|---|---|---|
| `QA Report: PASS WITH ISSUES` | `action_required` | `qa: pass-with-issues` |
| `QA Report: PASS` | `success` | `qa: pass` |
| `QA Report: FAIL` | `failure` | `qa: fail` |
| `QA Report: PARTIAL` | `action_required` | `qa: partial` |
| *(none)*, `not-applicable: false` | `action_required` | `qa: no-report` |
| *(none)*, `not-applicable: true` | `success` | `qa: not-applicable` |

Longest prefix wins, so `PASS WITH ISSUES` does not degrade to `PASS`.

## Failing closed

Publishing a `no-report` check run and exiting 0 is how a job that verified
nothing ends up green in a pull request's check list. With
`fail-on-no-report: true` (the default) the action exits 1 in that case.

Set `not-applicable: true` when the diff cannot alter the product — a change
confined to `.github/`, for instance — rather than paying an agent to exercise
software that did not change.

## Inputs

| Input | Default |
|---|---|
| `pr-number` | required |
| `head-sha` | required |
| `check-name` | `assurance/verified` |
| `report-path` | `""` |
| `not-applicable` | `false` |
| `not-applicable-text` | a generic explanation |
| `no-report-hint` | `""` — usually how to fix the environment |
| `fail-on-no-report` | `true` |
| `run-url` | this run |
