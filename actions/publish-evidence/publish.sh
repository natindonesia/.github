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
[ -d "$root" ] || fail "no evidence directory at $root"

# Absolute, normalised, so every later `-f` test is unambiguous.
root="$(cd "$root" && pwd)"

files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done < <(find "$root" -type f -not -name '.*' -size -"${MAX_BYTES}"c -print0 | sort -z)

if [ ${#files[@]} -eq 0 ]; then
  log "No evidence files in $root."
  summary "### Evidence"
  summary ""
  summary "The run produced no files in \`$EVIDENCE_DIR\`, so nothing is shown here."
  echo "uploaded=0" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# --- pick the report ---------------------------------------------------------

if [ -z "$REPORT" ]; then
  for candidate in qa-report.md evidence.md report.md QA_REPORT.md; do
    if [ -f "$root/$candidate" ]; then REPORT="$candidate"; break; fi
  done
fi

report_path=""
if [ -n "$REPORT" ]; then
  case "$REPORT" in
    /*) report_path="$REPORT" ;;
    *)  report_path="$root/$REPORT" ;;
  esac
  [ -f "$report_path" ] || report_path=""
fi

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
    png)         echo "image/png" ;;
    jpg|jpeg)    echo "image/jpeg" ;;
    gif)         echo "image/gif" ;;
    webp)        echo "image/webp" ;;
    svg)         echo "image/svg+xml" ;;
    mp4)         echo "video/mp4" ;;
    webm)        echo "video/webm" ;;
    mov)         echo "video/quicktime" ;;
    pdf)         echo "application/pdf" ;;
    json)        echo "application/json" ;;
    txt|log|md)  echo "text/plain; charset=utf-8" ;;
    *)           echo "application/octet-stream" ;;
  esac
}

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

rendered="${RUNNER_TEMP:-/tmp}/qa-evidence-rendered.md"
is_capture() {
  case "${1##*.}" in
    png|jpg|jpeg|gif|webp|svg|mp4|webm|mov) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "$report_path" ]; then
  if [ -s "$mapping" ]; then
    REPORT_PATH="$report_path" MAPPING="$mapping" EVIDENCE_ROOT="$root" RENDERED="$rendered" \
      python3 "$(dirname "$0")/render.py"
  else
    # Nothing was uploaded, so there is no URL to point at. Post the report as
    # written: its links will not render, but the verdict is still readable,
    # which is what the gate needs. The captures are in the artifact.
    cp "$report_path" "$rendered"
    log "no URLs available; posting the report with its local links intact"
  fi
elif [ -s "$mapping" ]; then
  # No narrative from the agent. Pair the captures by name so before/after at
  # least sit next to each other, and say plainly that there is no account of
  # what they show.
  {
    echo "### Evidence from the verification run"
    echo
    echo "> No report was written, so this is a file listing, not a described"
    echo "> result. Treat it as uncontextualised."
    echo
    while IFS=$'\t' read -r rel url; do
      [ -n "$rel" ] || continue
      echo "**\`${rel}\`**"
      echo
      if is_capture "$rel"; then echo "![${rel}](${url})"; else echo "[${rel}](${url})"; fi
      echo
    done < "$mapping"
  } > "$rendered"
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
