#!/usr/bin/env python3
"""Start the product a change is meant to alter, and probe it.

The pipeline this belongs to has one rule that shapes everything here: the agent
never builds and never starts anything. By the time it runs, two revisions of the
product are already answering at the URLs the repository declared.

Three subcommands, because they run at three different moments and only one of
them may fail the run:

    resolve      read qa.yml, resolve the images, decide whether there is a
                 baseline to compare against. Runs before the scope gate, and
                 must not touch docker.
    up           log in, pull, compose up, seed, probe. A product that does not
                 come up is an environment failure, not a verdict about the
                 change -- so it fails loudly here instead of reaching an agent
                 that would then report "could not verify anything".
    environment  write what the agent is being given, as markdown, into the
                 evidence directory. Passwords are deliberately not written:
                 the evidence directory is published to a public bucket.
    down         stop the project and capture the product log.

Everything the application side owns -- the compose file, the images, the URLs,
the accounts -- comes in through qa.yml and compose.verify.yaml. Nothing here
knows what a course catalogue, a tenant or a Frappe site is.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import yaml

REGISTRY_ALLOWLIST = "ghcr.io/natindonesia"

DEFAULTS: dict[str, Any] = {
    "max-budget": 0.75,
    "max-iterations": 60,
    "agent-timeout": 18,
}

REQUIRED_URIS = ("after",)


def ensure_hosts(urls: dict[str, str]) -> None:
    """Make a declared URL resolve, without asking the repository to explain why.

    A product that is one site per hostname -- anything built on Frappe, and most
    things with a tenant domain -- cannot be reached on `127.0.0.1` at all: the
    request arrives for a site that does not exist. The repository declares the
    URL it means, and this makes that URL reachable from the runner and from the
    browser the agent drives.
    """
    unparsed = []
    for url in urls.values():
        host = urllib.parse.urlsplit(url).hostname or ""
        if not host or host in ("127.0.0.1", "localhost"):
            continue
        try:
            socket.gethostbyname(host)
        except OSError:
            unparsed.append(host)
    if not unparsed:
        return

    entry = "127.0.0.1 " + " ".join(sorted(set(unparsed)))
    for as_root in (False, True):
        try:
            if as_root:
                subprocess.run(["sudo", "sh", "-c", f'echo "{entry}" >> /etc/hosts'], check=True)
            else:
                with open("/etc/hosts", "a", encoding="utf-8") as handle:
                    handle.write(f"\n{entry}\n")
            log(f"/etc/hosts: {entry}")
            return
        except (PermissionError, OSError, subprocess.CalledProcessError):
            continue
    warn(
        f"could not point {', '.join(unparsed)} at 127.0.0.1; a URL declared by "
        "hostname may not resolve for the agent"
    )


def log(message: str) -> None:
    print(message, flush=True)


def fail(message: str) -> None:
    print(f"::error title=Verification environment::{message}", flush=True)
    sys.exit(1)


def warn(message: str) -> None:
    print(f"::warning title=Verification environment::{message}", flush=True)


def summary(lines: list[str]) -> None:
    path = os.getenv("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def output(name: str, value: str) -> None:
    path = os.getenv("GITHUB_OUTPUT")
    if not path:
        log(f"{name}={value}")
        return
    with open(path, "a", encoding="utf-8") as handle:
        if "\n" in value:
            handle.write(f"{name}<<__QA_EOF__\n{value}\n__QA_EOF__\n")
        else:
            handle.write(f"{name}={value}\n")


def export(name: str, value: str) -> None:
    path = os.getenv("GITHUB_ENV")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")
    os.environ[name] = value


def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    log("+ " + " ".join(command))
    return subprocess.run(command, text=True, capture_output=True, **kwargs)


# --- resolve -----------------------------------------------------------------


def load_config(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(
            f"no verification contract at {path}. A repository that calls this "
            "workflow must describe its product in qa.yml: see README.md."
        )
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as error:
        fail(f"{path} is not valid YAML: {error}")

    if not isinstance(raw, dict):
        fail(f"{path} must be a mapping at the top level")

    if not raw.get("product-paths"):
        fail(f"{path} has no `product-paths`: without it every change is in scope, or none is")

    try:
        re.compile(str(raw["product-paths"]))
    except re.error as error:
        fail(f"{path}: `product-paths` is not a valid regular expression: {error}")

    urls = raw.get("urls") or {}
    if not isinstance(urls, dict) or not urls.get("after"):
        fail(f"{path} must declare `urls.after`: where the change answers once started")
    for name in urls:
        if name not in ("before", "after"):
            fail(f"{path}: unknown url {name!r}; expected `before` and/or `after`")

    images = raw.get("images") or {}
    for name in images:
        if name not in ("before", "after"):
            fail(f"{path}: unknown image {name!r}; expected `before` and/or `after`")

    accounts = raw.get("accounts") or []
    if not isinstance(accounts, list):
        fail(f"{path}: `accounts` must be a list")
    for account in accounts:
        if not isinstance(account, dict) or not account.get("role"):
            fail(f"{path}: every account needs a `role`")

    agent = raw.get("agent") or {}
    for name in agent:
        if name not in DEFAULTS:
            fail(f"{path}: unknown agent setting {name!r}; expected one of {sorted(DEFAULTS)}")

    return {
        "product-paths": str(raw["product-paths"]),
        "urls": {name: str(url).rstrip("/") for name, url in urls.items()},
        "images": {name: str(image) for name, image in images.items()},
        "accounts": accounts,
        "focus": str(raw.get("focus") or "").strip(),
        "agent": {**DEFAULTS, **agent},
    }


def substitute(image: str, base_sha: str, head_sha: str) -> str:
    return image.replace("{base_sha}", base_sha).replace("{head_sha}", head_sha)


def check_registry(image: str, repository: str, dry_run: bool) -> None:
    allowed = f"{REGISTRY_ALLOWLIST}/{repository}"
    if image.startswith(allowed):
        return
    if dry_run:
        log(f"[dry-run] {image} is outside {allowed}; allowed because this is a dry run")
        return
    fail(
        f"refusing {image}: a product image must come from {allowed}. "
        "The gate cannot compare a change to an image it did not build."
    )


def cmd_resolve(args: argparse.Namespace) -> int:
    config = load_config(Path(args.config))
    base_sha = os.getenv("BASE_SHA", "")
    head_sha = os.getenv("HEAD_SHA", "")
    repository = os.getenv("GITHUB_REPOSITORY", "").split("/")[-1]

    after = args.after_image or config["images"].get("after", "")
    if not after:
        fail(
            "no image for this change. Pass `after-image` from the build job, "
            "or set `images.after` in qa.yml."
        )
    after = substitute(after, base_sha, head_sha)
    check_registry(after, repository, args.dry_run)

    before = config["images"].get("before", "")
    before = substitute(before, base_sha, head_sha) if before else ""
    if before:
        check_registry(before, repository, args.dry_run)

    mode = "compare" if before and config["urls"].get("before") else "single"

    output("product-paths", config["product-paths"])
    output("after-image", after)
    output("before-image", before)
    output("mode", mode)
    output("urls", json.dumps(config["urls"]))
    output("accounts", json.dumps(config["accounts"]))
    output("focus", config["focus"])
    for name, value in config["agent"].items():
        output(name, str(value))

    summary(
        [
            "### Verification contract",
            "",
            f"- mode: **{mode}**" + ("" if mode == "compare" else " (no baseline declared)"),
            f"- after: `{after}`",
            f"- before: `{before or '—'}`",
            f"- urls: `{', '.join(f'{k}={v}' for k, v in config['urls'].items())}`",
            "",
        ]
    )
    log(f"mode={mode} after={after} before={before or '-'}")
    return 0


# --- up ----------------------------------------------------------------------


def docker_login(token: str) -> None:
    if not token:
        log("no registry token; assuming the images are readable without one")
        return
    result = subprocess.run(
        ["docker", "login", "ghcr.io", "--username", "x-access-token", "--password-stdin"],
        input=token,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        warn(f"docker login failed: {result.stderr.strip()}")


def pull(image: str, what: str) -> bool:
    result = run(["docker", "pull", image], timeout=1800)
    if result.returncode != 0:
        warn(f"could not pull the {what} image {image}: {result.stderr.strip()[-400:]}")
        return False
    return True


def image_id(image: str) -> str:
    result = run(["docker", "inspect", "--format", "{{.Id}}", image])
    return result.stdout.strip() if result.returncode == 0 else ""


def revision(image: str) -> str:
    result = run(
        [
            "docker",
            "inspect",
            "--format",
            '{{index .Config.Labels "org.opencontainers.image.revision"}}',
            image,
        ]
    )
    value = result.stdout.strip()
    return "" if value in ("", "<no value>") else value


def compose(
    args: argparse.Namespace,
    command: list[str],
    profiles: list[str],
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    environment = {
        **os.environ,
        # A compose file that requires the image variables must still be readable
        # during teardown, where nothing is pulled and only the project name
        # matters. Interpolation has to succeed for `down` to run at all.
        "AFTER_IMAGE": os.environ.get("AFTER_IMAGE") or "unused",
        "BEFORE_IMAGE": os.environ.get("BEFORE_IMAGE") or "unused",
        "QA_MODE": os.environ.get("QA_MODE", "single"),
        "QA_PROJECT": args.project,
        "COMPOSE_PROFILES": ",".join(profiles),
    }
    return subprocess.run(
        [
            "docker",
            "compose",
            "--project-name",
            args.project,
            "--project-directory",
            str(Path(args.compose).parent),
            "-f",
            args.compose,
            *command,
        ],
        text=True,
        env=environment,
        capture_output=capture,
    )


def answered(status: int) -> bool:
    """Whether a declared URL is serving the product, not refusing to.

    A 404 at the root is how a product that is one site per hostname -- Frappe,
    and most multi-tenant stacks -- says this hostname is not a site. Counting
    that as "up" hands the agent a URL that answers every request with the same
    error page, and the report then blames the change for it.
    """
    return status < 400 or status in (401, 403)


def probe(url: str, timeout_seconds: int = 180) -> tuple[bool, str]:
    deadline = time.time() + timeout_seconds
    last = "no attempt made"
    while time.time() < deadline:
        try:
            request = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(request, timeout=10) as response:
                if answered(response.status):
                    return True, f"HTTP {response.status}"
                last = f"HTTP {response.status}"
        except urllib.error.HTTPError as error:
            if answered(error.code):
                return True, f"HTTP {error.code}"
            last = f"HTTP {error.code}"
        except Exception as error:  # noqa: BLE001 - any failure means "not answered yet"
            last = str(error)
        time.sleep(3)
    return False, last


def service_states(args: argparse.Namespace) -> dict[str, dict[str, str]]:
    """Every container in the project, by service name, as compose reports it."""
    listing = compose(args, ["ps", "--all", "--format", "json"], [], capture=True)
    if listing.returncode != 0:
        return {}
    text = listing.stdout.strip()
    if not text:
        return {}
    records: list[dict[str, str]] = []
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        # Older compose prints one object per line rather than an array.
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    else:
        records = parsed if isinstance(parsed, list) else [parsed]
    states: dict[str, dict[str, str]] = {}
    for record in records:
        service = record.get("Service") or record.get("service") or ""
        if service:
            states[service] = record
    return states


def describe(record: dict[str, str]) -> str:
    state = (record.get("State") or record.get("state") or "?").lower()
    health = (record.get("Health") or record.get("health") or "").lower()
    return f"{state}/{health}" if health else state


def wait_ready(args: argparse.Namespace, timeout: int = 600) -> list[str]:
    """Wait for the product, without letting a missing healthcheck fail the run.

    `up --detach --wait` is not used on purpose: compose treats a service that
    declares no healthcheck as a failure, and `before` declares none. If the
    baseline cannot start -- an nginx template it no longer matches, an image that
    exits -- the run should degrade to single mode, not lose the change's verdict.
    So everything except `before` has to reach running, and healthy where it has a
    healthcheck; `before` is only observed here and probed afterwards.
    """
    deadline = time.time() + timeout
    last = ""
    states: dict[str, dict[str, str]] = {}
    while True:
        states = service_states(args)
        if states:
            ready = True
            problems: list[str] = []
            for service, record in states.items():
                if service in ("before", "seed"):
                    continue
                state = (record.get("State") or "").lower()
                health = (record.get("Health") or "").lower()
                if state == "running" and health in ("", "healthy"):
                    continue
                if state in ("exited", "dead"):
                    problems.append(f"{service} is {state}")
                else:
                    ready = False
                    last = f"{service} is {describe(record)}"
            if problems:
                fail("the product did not stay up: " + "; ".join(problems))
            if ready:
                break
        if time.time() > deadline:
            fail(
                f"the product was still not ready after {timeout}s: "
                f"{last or 'no container reported a state'}"
            )
        time.sleep(2)

    notes: list[str] = []
    before = states.get("before")
    if before is not None:
        state = (before.get("State") or "").lower()
        if state != "running":
            notes.append(
                f"the baseline container is {describe(before)}, so there is no "
                "before/after comparison"
            )
    return notes


def cmd_up(args: argparse.Namespace) -> int:
    base_sha = os.getenv("BASE_SHA", "")
    head_sha = os.getenv("HEAD_SHA", "")
    urls = json.loads(args.urls) if args.urls else {}
    mode = args.mode or "single"

    ensure_hosts(urls)

    export("QA_MODE", mode)
    export("AFTER_IMAGE", args.after_image)
    export("BEFORE_IMAGE", args.before_image or "")

    notes: list[str] = []

    if not args.dry_run:
        docker_login(os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN", ""))
        if not pull(args.after_image, "change"):
            fail(f"the image for this change could not be pulled: {args.after_image}")

        head = revision(args.after_image)
        if head and head_sha and not head_sha.startswith(head[:12]) and not head.startswith(head_sha[:12]):
            fail(
                f"the image for this change was built from {head}, not {head_sha[:12]}. "
                "The gate would otherwise judge a revision other than the one under test."
            )

        if args.before_image:
            if pull(args.before_image, "baseline"):
                before_revision = revision(args.before_image)
                if before_revision and base_sha and not base_sha.startswith(before_revision[:12]) and not before_revision.startswith(base_sha[:12]):
                    warn(
                        f"the baseline image was built from {before_revision}, not {base_sha[:12]}"
                    )
                if image_id(args.after_image) == image_id(args.before_image):
                    fail(
                        "the change and its baseline resolve to the same image, so "
                        "comparing them would compare the change to itself."
                    )
            else:
                mode = "single"
                notes.append(
                    f"the baseline image `{args.before_image}` could not be pulled, so there is no before/after comparison"
                )
    else:
        log("[dry-run] skipping registry login, pulls and image identity checks")
        for image in filter(None, [args.after_image, args.before_image]):
            if not pull(image, "sample"):
                fail(f"a dry run still needs its images to exist: {image}")

    profiles = ["after"] + (["before"] if mode == "compare" else [])

    # One-shot preparation runs before anything serves. A site created after the
    # server started is a site the server may not know about, and the first
    # request after seeding is exactly the one the agent makes. The seed service
    # lives in its own profile so `up` never starts it a second time.
    declared = compose(args, ["config", "--profiles"], [], capture=True)
    if declared.returncode == 0 and "seed" in declared.stdout.split():
        log("running the seed service, before the product starts")
        seeded = compose(args, ["run", "--rm", "seed"], profiles)
        if seeded.returncode != 0:
            fail(f"the seed service failed (exit {seeded.returncode})")

    up = compose(args, ["up", "--detach"], profiles)
    if up.returncode != 0:
        fail(f"docker compose could not start the product (exit {up.returncode})")

    # Waited for here rather than by `--wait`, which fails the run for a service
    # that declares no healthcheck -- exactly what a baseline that must be
    # allowed to fail looks like.
    notes.extend(wait_ready(args))

    probed: dict[str, str] = {}
    for name in ("after", "before"):
        if name not in urls or (name == "before" and mode != "compare"):
            continue
        ok, detail = probe(urls[name])
        probed[name] = detail
        if ok:
            log(f"{name} answered: {detail} at {urls[name]}")
            continue
        if name == "before":
            mode = "single"
            notes.append(f"the baseline at `{urls[name]}` never answered ({detail}), so there is no before/after comparison")
            export("QA_MODE", mode)
            continue
        fail(
            f"the product never answered at {urls[name]} ({detail}). This is an "
            "environment failure: nothing was verified, and the agent was not started."
        )

    Path(args.evidence_dir, "input").mkdir(parents=True, exist_ok=True)
    context = {
        "mode": mode,
        "urls": urls,
        "probes": probed,
        "notes": notes,
        "after_image": args.after_image,
        "before_image": args.before_image if mode == "compare" else "",
        "base_sha": base_sha,
        "head_sha": head_sha,
    }
    Path(args.evidence_dir, "input", "environment.json").write_text(
        json.dumps(context, indent=2) + "\n", encoding="utf-8"
    )

    output("mode", mode)
    output("probes", json.dumps(probed))
    output("notes", json.dumps(notes))

    lines = ["### Verification environment", "", f"- result: **up** ({mode})", ""]
    for name, detail in probed.items():
        lines.append(f"- {name}: `{urls[name]}` → {detail}")
    for note in notes:
        lines.append(f"- {note}")
    lines.append("")
    summary(lines)
    return 0


# --- environment -------------------------------------------------------------


def cmd_environment(args: argparse.Namespace) -> int:
    urls = json.loads(args.urls) if args.urls else {}
    accounts = json.loads(args.accounts or "[]")
    mode = args.mode or "single"

    lines = [
        "# What you are looking at",
        "",
        f"Mode: **{mode}**.",
        "",
    ]
    if mode == "compare":
        lines += [
            "Two revisions of the same product are running side by side. They share "
            "one database and one tenant, so a difference between them is the "
            "change and nothing else:",
            "",
            f"- **before** (the revision this change is based on): {urls.get('before', '—')}",
            f"- **after** (this change): {urls.get('after', '—')}",
            "",
        ]
    else:
        lines += [
            "One revision is running: this change. There is no baseline to compare "
            "against for this run, so describe what you see and say what you could "
            "not check.",
            "",
            f"- **after** (this change): {urls.get('after', '—')}",
            "",
        ]

    if accounts:
        lines += ["Sign in with these roles. Passwords are in the environment, not in this file:", ""]
        for account in accounts:
            label = account.get("email") or account.get("username") or ""
            lines.append(f"- `{account['role']}`: {label}")
        lines.append("")

    lines += [
        "The product was built and started before you were called. You cannot "
        "build it, install it, or start it.",
        "",
    ]

    target = Path(args.evidence_dir, "input", "environment.md")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines), encoding="utf-8")
    log(f"wrote {target}")
    return 0


# --- down --------------------------------------------------------------------


def cmd_down(args: argparse.Namespace) -> int:
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as handle:
        result = subprocess.run(
            [
                "docker",
                "compose",
                "--project-name",
                args.project,
                "--project-directory",
                str(Path(args.compose).parent),
                "-f",
                args.compose,
                "logs",
                "--no-color",
            ],
            text=True,
            capture_output=True,
        )
        handle.write(result.stdout or "")
        if result.returncode != 0:
            handle.write(f"\n(logs unavailable: {result.stderr.strip()})\n")

    stopped = compose(args, ["down", "--volumes", "--timeout", "10", "--remove-orphans"], ["after", "before"])
    log(f"compose down exited {stopped.returncode}")
    log(f"product log written to {log_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    resolve = sub.add_parser("resolve")
    resolve.add_argument("--config", required=True)
    resolve.add_argument("--compose", default="")
    resolve.add_argument("--after-image", default="")
    resolve.add_argument("--dry-run", action="store_true")
    resolve.set_defaults(func=cmd_resolve)

    up = sub.add_parser("up")
    up.add_argument("--config", default="")
    up.add_argument("--compose", required=True)
    up.add_argument("--after-image", required=True)
    up.add_argument("--before-image", default="")
    up.add_argument("--mode", default="single")
    up.add_argument("--project", required=True)
    up.add_argument("--urls", default="")
    up.add_argument("--evidence-dir", required=True)
    up.add_argument("--dry-run", action="store_true")
    up.set_defaults(func=cmd_up)

    environment = sub.add_parser("environment")
    environment.add_argument("--mode", default="single")
    environment.add_argument("--urls", default="")
    environment.add_argument("--accounts", default="[]")
    environment.add_argument("--evidence-dir", required=True)
    environment.set_defaults(func=cmd_environment)

    down = sub.add_parser("down")
    down.add_argument("--compose", required=True)
    down.add_argument("--project", required=True)
    down.add_argument("--log", required=True)
    down.set_defaults(func=cmd_down)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
