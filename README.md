# .github

Organisation-wide community health files, and the GitHub Actions that more than
one repository in `natindonesia` runs.

## Actions

| Action | What it is for |
|---|---|
| [`publish-evidence`](actions/publish-evidence) | Upload a QA run's captures, repoint the report's local image links at them, and post the result as a pull request comment. |
| [`qa-verdict`](actions/qa-verdict) | Score that report and publish the `assurance/verified` check run, failing closed when there is no report. |

Both are composite actions and are versioned by tag:

```yaml
- uses: natindonesia/.github/actions/publish-evidence@v1
```

`v1` moves: a fix to a shared action has to reach its consumers, so the major
tag is force-updated and `v1.0`, `v1.1` … are the immutable points. A workflow
whose result must be reproducible byte for byte should pin one of those, or the
commit itself.

They exist because two repositories had the same ~150 lines of shell copied into
their `verify.yml`: install the AWS CLI, upload to the evidence bucket, rewrite
relative links, post a comment, then parse the verdict. The copy drifted, the
rewrite was only ever tested in one of them, and a fix to the link handling had
to be made twice.

### The contract the agent writes against

The agent never learns about object storage. It writes a report next to its
captures, with ordinary relative links:

```markdown
## QA Report: PASS WITH ISSUES

| state | capture |
|---|---|
| before | ![before](./before-home.png) |
| after  | ![after](./after-home.png) |
```

`publish-evidence` uploads `before-home.png` and `after-home.png`, rewrites both
links to public URLs, and posts the document. A link to a file that was never
captured fails the step rather than rendering as a broken image.

The verdict is read from the first heading that matches, so the report has to
carry one of `QA Report: PASS`, `PASS WITH ISSUES`, `FAIL`, or `PARTIAL`.
Longest match wins.

## Self-test

[`actions.yml`](.github/workflows/actions.yml) runs both actions against a
fixture in dry-run mode on every change here: it asserts that links are
repointed, that external links are left alone, that a broken link is rejected,
and that each verdict branch resolves correctly. Nothing touches the bucket.
