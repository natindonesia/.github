#!/usr/bin/env bash
# Publish QA evidence: upload the captures, repoint the report at them, and put
# the result where a reviewer will see it.
#
# The agent writes a report with ordinary relative image links --
# `![caption](./after-home.png)` -- and this turns them into public URLs. That
# keeps the agent's job local and filesystem-shaped, which it is good at, and
# keeps the storage detail out of the prompt.
#
# Called by action.yml. Everything comes in through the environment so the
# script can be run by hand against a scratch directory.
set -euo pipefail

EVIDENCE_DIR="${EVIDENCE_DIR:-output}"
REPORT="${REPORT:-}"
PREFIX_INPUT="${PREFIX:-}"
BUCKET="${BUCKET:?BUCKET is required}"
ENDPOINT="${ENDPOINT:?ENDPOINT is required}"
PUBLIC_BASE="${PUBLIC_BASE:?PUBLIC_BASE is required}"
POST_COMMENT="${POST_COMMENT:-true}"
COMMENT_MARKER="${COMMENT_MARKER:-<!-- qa-evidence -->}"
DRY_RUN="${DRY_RUN:-false}"
MAX_BYTES="${MAX_BYTES:-10485760}"
# Recordings are the one artefact that is routinely bigger than a screenshot and
# routinely worth keeping. The agent shrinks them; this is the backstop for the
# one it forgot to.
MAX_VIDEO_BYTES="${MAX_VIDEO_BYTES:-104857600}"

# The inline copy of a recording. GitHub deletes every tag that can play a video
# and its image proxy refuses every video type, so the only way a recording moves
# in a comment is an animated image. AVIF is a moving picture a reviewer can read
# text in for a fraction of the bytes a gif costs; the first seconds are where a
# flow shows what changed.
#
# The animation is the recording's own width -- no resampling, so nothing is
# blurred before the encoder sees it -- and the byte cap below is what stops it,
# not a width. Set MOTION_WIDTH to a number to impose a ceiling.
MOTION_SECONDS="${MOTION_SECONDS:-8}"
MOTION_FPS="${MOTION_FPS:-10}"
MOTION_WIDTH="${MOTION_WIDTH:-0}"
MOTION_CRF="${MOTION_CRF:-32}"
MOTION_PRESET="${MOTION_PRESET:-10}"
# Past this the animation is not worth its bytes, and the recording stays a link.
MAX_MOTION_BYTES="${MAX_MOTION_BYTES:-2097152}"

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
PR="${PR_NUMBER:?PR_NUMBER is required}"
RUN_ID="${GITHUB_RUN_ID:-local}"

log() { printf '%s\n' "$*"; }
summary() { printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
warning() { printf '::warning title=Evidence not published::%s\n' "$*"; }
fail() { printf '::error title=Evidence::%s\n' "$*"; exit 1; }

# --- locate the evidence -----------------------------------------------------

case "$EVIDENCE_DIR" in
  /*) root="$EVIDENCE_DIR" ;;
  *)  root="${GITHUB_WORKSPACE:-$PWD}/$EVIDENCE_DIR" ;;
esac

# A missing directory is not this step's failure. Deciding that a run which
# captured nothing is unacceptable belongs to the verdict, which knows whether
# an agent was supposed to run at all; failing here would also turn a run that
# stopped before the agent started into a publish error and hide the reason.
root_missing=false
if [ ! -d "$root" ]; then
  root_missing=true
  log "no evidence directory at $root"
else
  # Absolute, normalised, so every later `-f` test is unambiguous.
  root="$(cd "$root" && pwd)"
fi

# --- pick the report ---------------------------------------------------------

if [ "$root_missing" = false ]; then
  if [ -z "$REPORT" ]; then
    for candidate in qa-report.md evidence.md report.md QA_REPORT.md; do
      if [ -f "$root/$candidate" ]; then REPORT="$candidate"; break; fi
    done
  fi
fi

report_path=""
if [ -n "$REPORT" ] && [ "$root_missing" = false ]; then
  case "$REPORT" in
    /*) report_path="$REPORT" ;;
    *)  report_path="$root/$REPORT" ;;
  esac
  [ -f "$report_path" ] || report_path=""
fi

# --- what the report refers to -----------------------------------------------
#
# Only what `qa-report.md` names is published. A capture the agent took and never
# mentioned stays in the artifact: uploading it would put pictures in the
# comment that the report does not stand behind, and the report is what the
# verdict is about. No report is no publication -- a run that produced no
# evidence must not be dressed up as one, and the verdict says `no-report`.

if [ -z "$report_path" ]; then
  warning "no ${EVIDENCE_DIR} report at ${root}/${REPORT:-qa-report.md}, so nothing was published"
  summary "### Evidence"
  summary ""
  summary "The run produced no report, so there was nothing to publish."
  echo "uploaded=0" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# Every file in the directory is a candidate, so a link written as `./x.mp4`,
# `output/x.mp4` or a bare `x.mp4` resolves to the same object; the report decides
# which of them are published. A reference to a file that is not there stays
# unresolved here and fails at the rewrite, which is where it belongs.
refmap="$(mktemp)"
find "$root" -type f -not -name '.*' -printf '%P\t%P\n' | sort > "$refmap"
mapfile -t referenced < <(
  REPORT_PATH="$report_path" MAPPING="$refmap" EVIDENCE_ROOT="$root" RENDERED=/dev/null \
    python3 "$(dirname "$0")/render.py" --refs 2>/dev/null || true
)
rm -f "$refmap"
log "the report refers to ${#referenced[@]} file(s)"

files=()
for rel in "${referenced[@]}"; do
  [ -f "$root/$rel" ] || continue
  case "$rel" in
    *.mp4|*.webm|*.mov) cap="$MAX_VIDEO_BYTES" ;;
    *)                  cap="$MAX_BYTES" ;;
  esac
  size="$(stat -c %s "$root/$rel" 2>/dev/null || echo 0)"
  if [ "$size" -ge "$cap" ]; then
    printf '::warning title=Evidence file skipped::%s is %sMB, over the %s byte cap for its type\n' \
      "$rel" "$((size / 1048576))" "$cap"
    continue
  fi
  files+=("$root/$rel")
done

# --- upload ------------------------------------------------------------------

mapping="$(mktemp)"
trap 'rm -f "$mapping"' EXIT
: > "$mapping"

# Credentials decide whether anything is uploaded, not whether the report is
# rendered. Bailing out before rendering looked like a shortcut and was a bug:
# a repository without the bucket secrets lost its report, so the verdict step
# saw nothing and failed it closed. The captures still reach whatever artifact
# the caller uploads; only the inline rendering needs storage.
has_creds=false
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  has_creds=true
fi
can_upload=false
if [ "$has_creds" = true ] && [ "$DRY_RUN" != "true" ]; then
  can_upload=true
fi

if [ "$has_creds" != true ]; then
  warning "no storage credentials are available to this run, so the captures stay in the artifact and the report is posted without inline images"
fi

if [ "$can_upload" = true ] && ! command -v aws >/dev/null 2>&1; then
  # Present on the standard runner image. Installed only when it is not, so a
  # different image cannot break publishing silently.
  log "installing aws cli"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp
  /tmp/aws/install -i /tmp/awscliv2 -b /tmp/awsbin >/dev/null
  export PATH="/tmp/awsbin:$PATH"
fi

content_type() {
  case "${1##*.}" in
    png)          echo "image/png" ;;
    jpg|jpeg)     echo "image/jpeg" ;;
    gif)          echo "image/gif" ;;
    webp)         echo "image/webp" ;;
    avif)         echo "image/avif" ;;
    svg)          echo "image/svg+xml" ;;
    mp4)          echo "video/mp4" ;;
    webm)         echo "video/webm" ;;
    mov)          echo "video/quicktime" ;;
    pdf)          echo "application/pdf" ;;
    json|har)     echo "application/json" ;;
    zip)          echo "application/zip" ;;
    csv)          echo "text/csv" ;;
    html|htm)     echo "text/html" ;;
    xml)          echo "application/xml" ;;
    vtt)          echo "text/vtt" ;;
    md)           echo "text/markdown; charset=utf-8" ;;
    txt|log)      echo "text/plain; charset=utf-8" ;;
    *)            echo "application/octet-stream" ;;
  esac
}

is_image() {
  case "${1##*.}" in
    png|jpg|jpeg|gif|webp|avif|svg) return 0 ;;
    *) return 1 ;;
  esac
}

is_video() {
  case "${1##*.}" in
    mp4|webm|mov) return 0 ;;
    *) return 1 ;;
  esac
}

# --- motion for the recordings the report refers to ---------------------------
#
# GitHub will not play a recording in a comment: the renderer deletes <video>,
# <iframe>, <object> and <embed>, and `![](clip.mp4)` becomes a broken image
# because the image proxy refuses every video type. An animated AVIF is an
# image, so it embeds and it moves.
#
# Only the recordings the report actually refers to are encoded, and that scan
# happens before anything is uploaded: the rest of the directory travels as it
# is. With no report there is only the listing, which shows every capture, so
# every recording is encoded.

if command -v ffmpeg >/dev/null 2>&1; then
  # One encode attempt. The filter decides the size; the caller decides whether
  # the result was small enough.
  encode_motion() {
    local filter="$1" crf="$2" out="$3"
    ffmpeg -loglevel error -y -t "$MOTION_SECONDS" -i "$video" \
      -vf "$filter" \
      -c:v libsvtav1 -crf "$crf" -preset "$MOTION_PRESET" -f avif "$out" \
      </dev/null >/dev/null 2>&1
  }

  for video in "${files[@]}"; do
    is_video "$video" || continue
    rel="${video#"$root"/}"
    motion="$root/motion/${rel%.*}.avif"
    if [ ! -f "$motion" ]; then
      mkdir -p "$(dirname "$motion")"
      # The recording's own width, optionally capped. libsvtav1 takes yuv420, so
      # an odd dimension is rounded down to even rather than resampled.
      if [ "${MOTION_WIDTH:-0}" -gt 0 ] 2>/dev/null; then
        at_source="scale='min(${MOTION_WIDTH},iw)':-2:flags=lanczos"
      else
        at_source="scale='trunc(iw/2)*2':'trunc(ih/2)*2'"
      fi
      if ! encode_motion "fps=${MOTION_FPS},${at_source}" "$MOTION_CRF" "$motion"; then
        rm -f "$motion"
        warning "could not encode an animated copy of ${rel}; the recording stays a link"
        continue
      fi
      # Source width is the default because resampling is what softens text, but
      # motion in the comment beats a sharp link nobody opens: over the cap, one
      # retry at half the width.
      if [ "$(stat -c %s "$motion" 2>/dev/null || echo 0)" -ge "$MAX_MOTION_BYTES" ]; then
        rm -f "$motion"
        log "the source-width copy of ${rel} is over the cap; retrying smaller"
        if ! encode_motion "fps=${MOTION_FPS},scale='trunc(iw/4)*2':'trunc(ih/4)*2'" "$MOTION_CRF" "$motion"; then
          rm -f "$motion"
          warning "could not encode an animated copy of ${rel}; the recording stays a link"
          continue
        fi
      fi
    fi
    size="$(stat -c %s "$motion" 2>/dev/null || echo 0)"
    # A box named moov is a track, which is what makes an AVIF a sequence rather
    # than a still. An ffmpeg whose avif muxer cannot write one would otherwise
    # publish a frozen frame that looks like working evidence.
    if ! head -c 8192 "$motion" | grep -aq moov; then
      rm -f "$motion"
      warning "this ffmpeg wrote a still, not an animation, for ${rel}; the recording stays a link"
      continue
    fi
    if [ "$size" -ge "$MAX_MOTION_BYTES" ]; then
      rm -f "$motion"
      warning "the animated copy of ${rel} is $((size / 1024))KiB even after shrinking, over the ${MAX_MOTION_BYTES} byte cap; the recording stays a link"
      continue
    fi
    files+=("$motion")
    log "motion for ${rel}"
  done
fi

# The prefix names the repository as well as the pull request: one bucket holds
# evidence from every repository, and PR numbers collide across them.
PREFIX="${PREFIX_INPUT:-repo/${REPO}/pr-${PR}/${RUN_ID}}"
uploaded=0

for file in "${files[@]}"; do
  rel="${file#"$root"/}"
  key="${PREFIX}/${rel}"
  url="${PUBLIC_BASE}/${key}"

  if [ "$has_creds" = true ] || [ "$DRY_RUN" = "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      log "[dry-run] would upload ${rel} -> ${url}"
    else
      aws --endpoint-url "$ENDPOINT" s3 cp "$file" "s3://${BUCKET}/${key}" \
        --content-type "$(content_type "$file")" --only-show-errors \
        || fail "could not upload ${rel}; check the bucket name, endpoint and key scope"
      log "uploaded ${rel}"
    fi
    printf '%s\t%s\n' "$rel" "$url" >> "$mapping"
    uploaded=$((uploaded + 1))
  fi
done

# --- render the report -------------------------------------------------------

# Unique per invocation, not per job: the self-test publishes three different
# fixtures in one job, and a fixed name means the last one silently replaces the
# rendered report the previous assertion is about to read.
rendered="${RUNNER_TEMP:-/tmp}/qa-evidence-rendered-$$.md"

if [ -s "$mapping" ]; then
  # render.py repoints every link and turns each recording into its animation.
  # A reference it cannot resolve fails the step: a broken image where evidence
  # should be reads as a failed capture, which is worse than an error here.
  REPORT_PATH="$report_path" MAPPING="$mapping" EVIDENCE_ROOT="$root" RENDERED="$rendered" \
    python3 "$(dirname "$0")/render.py"
else
  # Nothing was uploaded, so there is no URL to point at. Post the report as
  # written: its links will not render, but the verdict is still readable,
  # which is what the gate needs. The captures are in the artifact.
  cp "$report_path" "$rendered"
  log "no URLs available; posting the report with its local links intact"
fi

# --- deliver -----------------------------------------------------------------

if [ "$POST_COMMENT" = "true" ] && [ "$DRY_RUN" != "true" ]; then
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$GH_TOKEN" ]; then
    warning "no token, so the rendered evidence was not posted"
  else
    # One comment per marker: a re-run updates its own evidence instead of
    # stacking a second copy on the pull request.
    existing="$(gh api "repos/${REPO}/issues/${PR}/comments?per_page=100" \
      --jq "[.[] | select(.body | contains(\"${COMMENT_MARKER}\"))] | last | .id // \"\"" 2>/dev/null || true)"
    {
      printf '%s\n' "$COMMENT_MARKER"
      cat "$rendered"
    } > /tmp/qa-evidence-comment.md

    if [ -n "$existing" ]; then
      gh api -X PATCH "repos/${REPO}/issues/comments/${existing}" \
        -F body=@/tmp/qa-evidence-comment.md >/dev/null
      log "updated comment ${existing}"
      summary "Updated the evidence comment on #${PR}."
    else
      gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
        -F body=@/tmp/qa-evidence-comment.md >/dev/null
      log "posted a new evidence comment"
      summary "Posted the evidence on #${PR}."
    fi
  fi
fi

summary "### Evidence"
summary ""
summary "${uploaded} file(s) uploaded to \`${BUCKET}/${PREFIX}\`."
if [ -n "$report_path" ]; then
  summary "Rendered from \`${REPORT}\` with relative links repointed."
fi

printf 'rendered-report=%s\n' "$rendered" >> "${GITHUB_OUTPUT:-/dev/null}"
printf 'uploaded=%s\n' "$uploaded" >> "${GITHUB_OUTPUT:-/dev/null}"
printf 'prefix=%s\n' "$PREFIX" >> "${GITHUB_OUTPUT:-/dev/null}"

log "rendered ${rendered}"
