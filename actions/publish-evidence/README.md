# publish-evidence

Upload a QA run's captures, repoint the report's local links at them, and post
the result where a reviewer will see it.

```yaml
- id: evidence
  uses: natindonesia/.github/actions/publish-evidence@v1
  if: always()
  with:
    pr-number: ${{ github.event.pull_request.number }}
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    AWS_ACCESS_KEY_ID: ${{ secrets.QA_EVIDENCE_B2_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.QA_EVIDENCE_B2_APPLICATION_KEY }}
```

## Why the bucket has to be public

GitHub renders images in a comment by proxying them. That proxy will not send
credentials, so the URL has to be readable anonymously: a raw branch URL in a
private repository is not, and a release asset needs a session cookie. The
bucket is therefore `allPublic`, the key is scoped to that one bucket, and the
object key includes the repository, pull request, and run id so entries cannot
be guessed from a pattern.

If that trade is wrong for a repository, do not use this action; keep the
captures in an artifact and accept that they are a download rather than an
inline image.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `pr-number` | required | Where the comment goes. |
| `evidence-dir` | `output` | Absolute, or relative to the workspace. |
| `report` | auto | `qa-report.md`, `evidence.md`, `report.md`, `QA_REPORT.md`. |
| `bucket` | `natindonesia-qa-screenshots` | |
| `endpoint` | `https://s3.us-east-005.backblazeb2.com` | |
| `public-base` | `https://f005.backblazeb2.com/file/natindonesia-qa-screenshots` | |
| `prefix` | `repo/<repo>/pr-<n>/<run>` | |
| `post-comment` | `true` | |
| `comment-marker` | `<!-- qa-evidence -->` | A re-run updates its own comment. |
| `max-bytes` | `10485760` | Bigger files are skipped. |
| `dry-run` | `false` | Lists uploads and renders without uploading or commenting. |

## Outputs

| Output | Notes |
|---|---|
| `rendered-report` | Markdown with public URLs. Pass to `qa-verdict`. |
| `uploaded` | Number of objects uploaded. |
| `prefix` | Key prefix used. |

## Behaviour worth knowing

- **No credentials is not a failure.** The step warns and exits 0, so a
  repository without the bucket secrets still passes; the report is posted with
  its local links intact and the captures stay in whatever artifact the caller
  uploads.
- **No capture directory is not a failure either.** Whether a run that captured
  nothing is acceptable is the verdict's call, and this step failing first would
  hide the reason the agent never ran.
- **A broken link fails.** If the report references a file that was not
  captured, the step stops. A broken image where evidence should be reads as a
  failed capture, which is misleading.
- **No report is a listing.** With captures but no report, a labelled file
  listing is posted with an explicit note that it is uncontextualised.
- **Resolution order** for a link: exact path relative to the evidence
  directory, then `output/…`, then the file name alone if it is unambiguous.
  Absolute paths into the evidence directory are accepted.
- **External links are left alone**, as are `#anchors`.
