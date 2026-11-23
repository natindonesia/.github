#!/usr/bin/env python3
"""Turn a rendered QA report into the `assurance/verified` check run.

Two repositories publishing evidence the same way should also score it the same
way, or the shared action only moved the first half of the duplication.

Read order:

1. the rendered report from publish-evidence (the document a reviewer sees)
2. a review on this pull request bound to this commit
3. nothing -- which is not a pass

Exit status is meaningful: a missing report fails the job when
`fail-on-no-report` is set, because a gate that reports "no report" and exits 0
looks healthy in a pull request's check list.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Longest prefix first: PASS WITH ISSUES would otherwise match PASS.
VERDICTS = (
    ("QA Report: PASS WITH ISSUES", "action_required", "pass-with-issues"),
    ("QA Report: PASS", "success", "pass"),
    ("QA Report: FAIL", "failure", "fail"),
    ("QA Report: PARTIAL", "action_required", "partial"),
)

SUMMARY_LIMIT = 65000


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def api(path: str, method: str = "GET", payload: dict | None = None):
    token = env("GH_TOKEN") or env("GITHUB_TOKEN")
    if not token:
        raise SystemExit("GH_TOKEN is required to publish a check run")

    request = urllib.request.Request(f"https://api.github.com{path}", method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if payload is not None:
        request.add_header("Content-Type", "application/json")
        request.data = json.dumps(payload).encode()

    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read().decode()
        return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        detail = (error.read() or b"").decode("utf-8", errors="replace").strip()
        raise SystemExit(f"GitHub API {method} {path} failed: HTTP {error.code} {detail}") from error


def from_file() -> str:
    path = env("REPORT_PATH")
    if not path:
        return ""
    candidate = Path(path)
    if not candidate.is_file():
        return ""
    return candidate.read_text(encoding="utf-8", errors="replace").strip()


def from_reviews() -> tuple[str, str]:
    """A review is bound to the commit it was submitted against.

    Without that filter a failed run inherits the previous run's PASS, which is
    exactly the failure mode a gate exists to prevent.
    """
    repo, pr, head = env("GITHUB_REPOSITORY"), env("PR_NUMBER"), env("HEAD_SHA")
    if not (repo and pr and head):
        return "", ""
    try:
        reviews = api(f"/repos/{repo}/pulls/{pr}/reviews?per_page=100") or []
    except SystemExit:
        return "", ""
    for review in reversed(reviews):
        body = review.get("body") or ""
        if review.get("commit_id") == head and "QA Report" in body:
            return body, review.get("html_url", "")
    return "", ""


def main() -> int:
    head = env("HEAD_SHA")
    run_url = env("RUN_URL")
    check_name = env("CHECK_NAME") or "assurance/verified"

    body = from_file()
    if not body:
        body, _ = from_reviews()

    source = "report" if body else "none"

    conclusion, verdict = "action_required", "no-report"
    if env("NOT_APPLICABLE") == "true":
        conclusion, verdict = "success", "not-applicable"
        if not body:
            body = env("NOT_APPLICABLE_TEXT") or (
                "No product files changed, so there was nothing for an agent to"
                " exercise. Any captures from this run are unchanged-state baselines."
            )
    else:
        for marker, matched_conclusion, matched_verdict in VERDICTS:
            if marker in body:
                conclusion, verdict = matched_conclusion, matched_verdict
                break

    if not body:
        body = (
            f"No QA report was produced for `{head}`. This is not a pass."
        )
        if env("NO_REPORT_HINT"):
            body += "\n\n" + env("NO_REPORT_HINT")

    if env("DRY_RUN") == "true":
        print(f"qa: {verdict} ({conclusion}) from {source} [dry run]")
        return 0

    summary = f"{body}\n\n---\nRun: [{verdict}]({run_url})\n" if run_url else body
    if len(summary) > SUMMARY_LIMIT:
        summary = summary[: SUMMARY_LIMIT - 40] + "\n\n… [truncated]\n"

    repo = env("GITHUB_REPOSITORY")
    api(
        f"/repos/{repo}/check-runs",
        "POST",
        {
            "name": check_name,
            "head_sha": head,
            "status": "completed",
            "conclusion": conclusion,
            "output": {"title": f"qa: {verdict}", "summary": summary},
        },
    )

    print(f"qa: {verdict} ({conclusion}) on {head}, from {source}")

    if verdict == "no-report" and env("FAIL_ON_NO_REPORT") == "true":
        print(
            "::error title=No QA report::this run verified nothing, so the gate"
            " fails rather than looking healthy.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
