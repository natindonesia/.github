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
HEAD_SHA="${HEAD_SHA:-}"
DRY_RUN="${DRY_RUN:-false}"
MAX_BYTES="${MAX_BYTES:-10485760}"
# Recordings are the one artefact that is routinely bigger than a screenshot and
# routinely worth keeping. The agent shrinks them; this is the backstop for the
# one it forgot to.
MAX_VIDEO_BYTES="${MAX_VIDEO_BYTES:-104857600}"

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

# --- recover a report that arrived as a review -------------------------------
#
# The QA agent posts its findings as a pull request review, not as a file, so a
# complete run can leave the evidence directory empty and still hold a verdict.
# The listing below would then be the only trace of it. The newest review bound
# to the commit under test is the report.
recovered_review=false
if [ -z "$report_path" ] && [ -n "$HEAD_SHA" ] && [ -z "${SKIP_NOTE:-}" ]; then
  review_body="${RUNNER_TEMP:-/tmp}/qa-review-body.md"
  if gh api "repos/${REPO}/pulls/${PR}/reviews?per_page=100" \
       --jq "[.[] | select(.commit_id == \"${HEAD_SHA}\" and ((.body // \"\") | length > 0))] | last | .body // \"\"" \
       > "$review_body" 2>/dev/null \
     && [ -n "$(tr -d '[:space:]' < "$review_body" 2>/dev/null || true)" ]; then
    report_path="$review_body"
    recovered_review=true
    log "recovered the report from the agent's review on ${HEAD_SHA:0:12}"
  else
    log "no review bound to ${HEAD_SHA:0:12}; falling back to the file listing"
  fi
fi

if [ "$root_missing" = true ] && [ -z "$report_path" ]; then
  warning "no evidence directory at $root, so nothing could be published"
  summary "### Evidence"
  summary ""
  summary "The run left no \`$EVIDENCE_DIR\` directory, so there was nothing to collect."
  echo "uploaded=0" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

files=()
if [ "$root_missing" = false ]; then
  while IFS= read -r -d '' file; do
    case "${file##*.}" in
      mp4|webm|mov) cap="$MAX_VIDEO_BYTES" ;;
      *)            cap="$MAX_BYTES" ;;
    esac
    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$cap" ]; then
      rel="${file#"$root"/}"
      printf '::warning title=Evidence file skipped::%s is %sMB, over the %s byte cap for its type\n' \
        "$rel" "$((size / 1048576))" "$cap"
      continue
    fi
    files+=("$file")
  done < <(find "$root" -type f -not -name '.*' -print0 | sort -z)
fi

if [ ${#files[@]} -eq 0 ] && [ -z "$report_path" ]; then
  log "No evidence files in $root."
  summary "### Evidence"
  summary ""
  summary "The run produced no files in \`$EVIDENCE_DIR\`, so nothing is shown here."
  echo "uploaded=0" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
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
    png)          echo "image/png" ;;
    jpg|jpeg)     echo "image/jpeg" ;;
    gif)          echo "image/gif" ;;
    webp)         echo "image/webp" ;;
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
    png|jpg|jpeg|gif|webp|svg) return 0 ;;
    *) return 1 ;;
  esac
}

is_video() {
  case "${1##*.}" in
    mp4|webm|mov) return 0 ;;
    *) return 1 ;;
  esac
}

# --- posters for the recordings ----------------------------------------------
#
# A link to an mp4 is not something a reviewer can look at, and GitHub's comment
# renderer will not play one inline. A still from the recording, linking to it,
# is. Generated next to the video rather than in the report, so the agent never
# has to know this happens.

if [ "$root_missing" = false ] && command -v ffmpeg >/dev/null 2>&1; then
  while IFS= read -r -d '' video; do
    rel="${video#"$root"/}"
    poster="$root/posters/${rel%.*}.jpg"
    [ -f "$poster" ] && continue
    mkdir -p "$(dirname "$poster")"
    # One second in is where a recording has usually settled; a very short one
    # has no frame there at all, so fall back to its first.
    if ffmpeg -loglevel error -y -ss 1 -i "$video" -frames:v 1 -vf "scale=640:-2" "$poster" 2>/dev/null \
      || ffmpeg -loglevel error -y -i "$video" -frames:v 1 -vf "scale=640:-2" "$poster" 2>/dev/null; then
      files+=("$poster")
      log "poster for ${rel}"
    else
      rm -f "$poster"
    fi
  done < <(find "$root" -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.mov' \) -print0)
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

rendered="${RUNNER_TEMP:-/tmp}/qa-evidence-rendered.md"

# A recording is evidence, but a bare mp4 link is not something a reviewer can
# look at. Everything else that is embeddable is embedded; the rest is a link.
render_file() {
  local rel="$1" url="$2" poster
  if is_image "$rel"; then
    printf '![%s](%s)' "$rel" "$url"
  elif is_video "$rel" && poster="$(poster_url_for "$rel")"; then
    printf '[![%s](%s)](%s)' "$rel" "$poster" "$url"
  elif is_video "$rel"; then
    printf '[▶ %s](%s)' "$rel" "$url"
  else
    printf '[%s](%s)' "$rel" "$url"
  fi
}

poster_url_for() {
  local rel="$1" key="posters/${1%.*}.jpg" k u
  while IFS=$'\t' read -r k u; do
    if [ "$k" = "$key" ]; then printf '%s' "$u"; return 0; fi
  done < "$mapping"
  return 1
}

if [ -n "$report_path" ]; then
  if [ -s "$mapping" ]; then
    if [ "$recovered_review" = true ]; then
      # A review may quote files this run never captured, because the review is
      # prose about the change rather than a manifest of this run's captures.
      # Being wrong about a link there is not a reason to publish nothing -- but
      # a *written* report that points at a capture it did not produce is a hole
      # in the evidence, and must still fail.
      if ! REPORT_PATH="$report_path" MAPPING="$mapping" EVIDENCE_ROOT="$root" RENDERED="$rendered" \
        python3 "$(dirname "$0")/render.py"; then
        cp "$report_path" "$rendered"
        log "could not repoint every link; posting the recovered review as written"
      fi
    else
      REPORT_PATH="$report_path" MAPPING="$mapping" EVIDENCE_ROOT="$root" RENDERED="$rendered" \
        python3 "$(dirname "$0")/render.py"
    fi
  else
    # Nothing was uploaded, so there is no URL to point at. Post the report as
    # written: its links will not render, but the verdict is still readable,
    # which is what the gate needs. The captures are in the artifact.
    cp "$report_path" "$rendered"
    log "no URLs available; posting the report with its local links intact"
  fi
elif [ -s "$mapping" ]; then
  # No narrative. Either the caller knows why (it skipped the agent on purpose),
  # or nobody does -- and those two must not read the same, because one is a
  # healthy run and the other is a run that proved nothing.
  {
    echo "### Evidence from the verification run"
    echo
    if [ -n "${SKIP_NOTE:-}" ]; then
      printf '> %s\n' "$SKIP_NOTE"
    else
      echo "> No report was written, so this is a file listing, not a described"
      echo "> result. Treat it as uncontextualised."
    fi
    echo
    while IFS=$'\t' read -r rel url; do
      [ -n "$rel" ] || continue
      case "$rel" in posters/*) continue ;; esac
      echo "**\`${rel}\`**"
      echo
      render_file "$rel" "$url"
      echo
    done < "$mapping"
  } > "$rendered"
fi

if [ "$recovered_review" = true ] && [ -s "$rendered" ]; then
  { echo "> Recovered from the agent's review on \`${HEAD_SHA:0:12}\`; the run wrote no separate report."; echo; cat "$rendered"; } > "${rendered}.review"
  mv "${rendered}.review" "$rendered"
fi

# --- show what the report did not --------------------------------------------
#
# The agent posts its findings as prose, and prose about a before/after change
# usually ends up without a single image even when the captures exist. An
# evidence comment with no images is a claim, not a look. Anything the run
# captured and the report did not cite is appended, collapsed, and labelled as
# uncited -- so the reviewer sees it without it being passed off as the report.

if [ -s "$mapping" ] && [ -s "$rendered" ]; then
  uncited=()
  while IFS=$'\t' read -r rel url; do
    [ -n "$rel" ] || continue
    [ "$rel" = "${REPORT:-}" ] && continue
    case "$rel" in posters/*) continue ;; esac
    # Cited means cited, however the report points at it. A markdown link and an
    # embed are both a reference; keying on the published URL also catches the
    # file renamed into a table cell or onto a line of its own.
    grep -qF -- "$url" "$rendered" && continue
    if is_image "$rel" || is_video "$rel"; then uncited+=("$rel" "$url"); fi
  done < "$mapping"

  if [ ${#uncited[@]} -gt 0 ]; then
    {
      echo
      echo "<details><summary>Captures from this run, not cited by the report</summary>"
      echo
      echo "> The report does not embed these, so they are not an argument about"
      echo "> the change. They are what the run looked at."
      echo
      echo "| capture | |"
      echo "|---|---|"
      i=0
      while [ "$i" -lt ${#uncited[@]} ]; do
        rel="${uncited[$i]}"
        url="${uncited[$((i + 1))]}"
        printf '| `%s` | %s |\n' "$rel" "$(render_file "$rel" "$url")"
        i=$((i + 2))
      done
      echo
      echo "</details>"
    } >> "$rendered"
    log "appended $(( ${#uncited[@]} / 2 )) uncited capture(s) as a collapsed gallery"
  fi
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
