# publish-evidence

Upload the files a QA report references -- screenshots, recordings, PDFs, traces
-- repoint the report's local links at them, and post the result where a reviewer
will see it.

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

## What gets published

What the report references, and nothing else. A capture the report never mentions
is not uploaded; it stays in the `evidence` artifact.

| # | Step | Reads | Writes |
|---|---|---|---|
| 1 | Scan | `qa-evidence/qa-report.md`: every markdown link, every embed, every HTML `src`/`href` | the list of files it references |
| 2 | Encode | each referenced video (`.mp4`, `.webm`, `.mov`) | `qa-evidence/motion/<name>.avif` |
| 3 | Upload | the list from step 1, plus the AVIFs from step 2 | objects in the bucket |
| 4 | Repoint | `qa-report.md`, the public URLs | the report with the bucket's links; `[![name](avif)](mp4)` for each video |

The report is `qa-report.md` inside the evidence directory, which is
`<workspace>/qa-evidence` in the shared pipeline. `report` overrides the name.

With no `qa-report.md` there is nothing to scan, so nothing is uploaded and no
comment is posted. That is a run that produced no evidence, and the verdict step
says so rather than a listing standing in for a result.

Uploads carry a real content type per extension, because a PDF served as
`application/octet-stream` downloads instead of opening.

## Recordings become an animated image

GitHub will not play a recording in a comment: its renderer deletes `<video>`,
`<iframe>`, `<object>` and `<embed>`, and its image proxy refuses every video
type, so `![](clip.mp4)` is a broken image. An animated AVIF is an image, so that
is what gets shown, and the recording is what the picture links to.

| Setting | Default | Effect |
|---|---|---|
| `MOTION_SECONDS` | `8` | How much of the recording is encoded. |
| `MOTION_WIDTH` | source | `0` keeps the recording's own width; a number is a ceiling (never an upscale). Resampling is what softens text. |
| `MOTION_FPS` | `10` | Frames per second of the AVIF. |
| `MOTION_CRF` | `32` | SVT-AV1 quality; text stays legible. |
| `MOTION_PRESET` | `10` | Fastest encode; a few seconds of clip takes under one. |
| `MAX_MOTION_BYTES` | `2097152` | Past this it retries at half the width; still past it, the recording stays a link. |

```markdown
[![after-flow.mp4](.../motion/after-flow.avif)](.../after-flow.mp4)
```

An encode that fails, or one that lands over the cap, is skipped: the recording
is then a plain link, because an embed that resolves to a broken image is worse
than no embed. All six are environment overrides; the defaults are the ones that
have been read in a comment.

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
| `max-video-bytes` | `104857600` | Same, for recordings: they are routinely bigger and worth keeping. |
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
- **No report is not a publication.** Nothing is uploaded, nothing is posted.
  Whether a run that produced no evidence is acceptable belongs to the verdict,
  which records `no-report` and fails closed; a listing standing in for a result
  would have hidden that.
- **A broken link fails.** If the report references a file that was not
  captured, the step stops. A broken image where evidence should be reads as a
  failed capture, which is misleading.
- **Resolution order** for a link: exact path relative to the evidence
  directory, then `output/…`, then the file name alone if it is unambiguous.
  Absolute paths into the evidence directory are accepted.
- **External links are left alone**, as are `#anchors`.
