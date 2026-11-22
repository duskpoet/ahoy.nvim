#!/usr/bin/env bash
# Build the offline demo sandbox (fake $HOME, git repo, gh/curl shims). Idempotent: wipes $DEMO first.
#   demo/setup.sh [dir]   (default /tmp/ahoy-demo)
# Then `vhs demo/demo.tape` from the plugin root.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEMO="${1:-/tmp/ahoy-demo}"
case "$DEMO" in /tmp/*|/private/tmp/*) ;; *) echo "refusing to wipe $DEMO (not under /tmp)" >&2; exit 1 ;; esac
rm -rf "$DEMO"
mkdir -p "$DEMO/bin" "$DEMO/home/.config/nvim" "$DEMO/home/.config/ahoy"

# --- shims: gh and curl answer from demo/fake.lua -------------------------------------------
for tool in gh curl; do
  cat >"$DEMO/bin/$tool" <<EOF
#!/bin/sh
exec nvim --clean -l "$HERE/fake.lua" $tool "\$@"
EOF
  chmod +x "$DEMO/bin/$tool"
done

# --- shell env sourced by the tape ----------------------------------------------------------
cat >"$DEMO/env.sh" <<EOF
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME NVIM_APPNAME NVIM SSH_CONNECTION SSH_TTY
export HOME="$DEMO/home" PATH="$DEMO/bin:\$PATH" AHOY_PLUGIN="$(dirname "$HERE")" TZ="\${TZ:-}"
export GIT_CONFIG_GLOBAL="$DEMO/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export AHOY_DEMO_T0=$(date +%s)
export PS1='\$ ' PROMPT_COMMAND= BASH_SILENCE_DEPRECATION_WARNING=1
cd "\$HOME/rocket"
EOF

cat >"$DEMO/home/.config/nvim/init.lua" <<EOF
dofile("$HERE/init.lua")
EOF

# The calendar URL is never fetched (curl is the shim); it only has to look like one.
echo "https://calendar.example.com/sam/private.ics" >"$DEMO/home/.config/ahoy/ics_url"
chmod 600 "$DEMO/home/.config/ahoy/ics_url"

# --- the repo -------------------------------------------------------------------------------
export GIT_CONFIG_GLOBAL="$DEMO/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch main
git config --global advice.detachedHead false
R="$DEMO/home/rocket"
mkdir -p "$R"
cd "$R"
git init -q
git remote add origin git@github.com:acme/rocket.git

T0=$(( $(date +%s) - 5 * 86400 ))
commit() { # commit <who> <minutes-ago|abs:epoch> <message>
  local who="$1" when="$2" msg="$3" t
  case "$when" in abs:*) t="${when#abs:}" ;; *) t=$(( $(date +%s) - when * 60 )) ;; esac
  git add -A
  GIT_AUTHOR_NAME="$who" GIT_AUTHOR_EMAIL="$who@example.com" GIT_AUTHOR_DATE="@$t" \
    GIT_COMMITTER_NAME="$who" GIT_COMMITTER_EMAIL="$who@example.com" GIT_COMMITTER_DATE="@$t" \
    git commit -q -m "$msg"
}

mkdir -p src/rocket tests
cat >pyproject.toml <<'EOF'
[project]
name = "rocket"
version = "0.4.0"
description = "Fast, resumable uploads to object storage"
requires-python = ">=3.11"
dependencies = ["httpx>=0.27"]
EOF
cat >README.md <<'EOF'
# rocket

Fast, resumable uploads to object storage.
EOF
cat >src/rocket/__init__.py <<'EOF'
from rocket.upload import upload

__all__ = ["upload"]
EOF
cat >src/rocket/errors.py <<'EOF'
class RetryableError(Exception):
    """A transient failure worth another attempt (5xx, connection reset)."""


class TooManyRequests(RetryableError):
    def __init__(self, retry_after: float | None = None):
        super().__init__("429 Too Many Requests")
        self.retry_after = retry_after
EOF
cat >src/rocket/retry.py <<'EOF'
"""Retry helpers for the uploader."""

import time
from typing import Callable, TypeVar

from rocket.errors import RetryableError

T = TypeVar("T")


def retry(fn: Callable[[], T], attempts: int = 3, delay: float = 1.0) -> T:
    for attempt in range(attempts):
        try:
            return fn()
        except RetryableError:
            if attempt == attempts - 1:
                raise
            time.sleep(delay)
    raise AssertionError("unreachable")
EOF
cat >src/rocket/upload.py <<'EOF'
"""Upload a file in one request."""

from pathlib import Path

import httpx

from rocket.retry import retry


def upload(client: httpx.Client, path: Path, url: str) -> str:
    def put() -> str:
        r = client.put(url, content=path.read_bytes())
        r.raise_for_status()
        return r.headers["etag"]

    return retry(put)
EOF
cat >tests/test_retry.py <<'EOF'
import pytest

from rocket.errors import RetryableError
from rocket.retry import retry


def test_returns_first_success():
    assert retry(lambda: 42) == 42


def test_gives_up():
    def boom():
        raise RetryableError()

    with pytest.raises(RetryableError):
        retry(boom, attempts=2, delay=0)
EOF
commit theo abs:$T0 "Initial uploader"
echo "- Retries transient failures" >>README.md
commit sam abs:$(( T0 + 86400 )) "README: mention retries"
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git branch -q -u origin/main

# Mara's PR #42 branch (exists only as a remote ref until `gh pr checkout 42`).
git checkout -q -b mara/retry-backoff
cat >src/rocket/retry.py <<'EOF'
"""Retry helpers for the uploader."""

from __future__ import annotations

import random
import time
from dataclasses import dataclass
from typing import Callable, TypeVar

from rocket.errors import RetryableError, TooManyRequests

T = TypeVar("T")


@dataclass
class Backoff:
    base: float = 0.5
    factor: float = 2.0
    max_attempts: int = 8
    max_delay: float = 30.0

    def delay(self, attempt: int) -> float:
        raw = self.base * self.factor**attempt
        jitter = random.uniform(0, raw)
        return min(raw + jitter, self.max_delay)


def retry(fn: Callable[[], T], backoff: Backoff | None = None,
          sleep: Callable[[float], None] = time.sleep) -> T:
    backoff = backoff or Backoff()
    for attempt in range(backoff.max_attempts):
        try:
            return fn()
        except TooManyRequests:
            if attempt == backoff.max_attempts - 1:
                raise
            sleep(backoff.delay(attempt))
        except RetryableError:
            if attempt == backoff.max_attempts - 1:
                raise
            sleep(backoff.delay(attempt))
    raise AssertionError("unreachable")
EOF
commit mara $(( 27 * 60 + 5 )) "Add exponential backoff to the uploader"
cat >src/rocket/upload.py <<'EOF'
"""Upload a file in one request, retrying transient failures."""

from pathlib import Path

import httpx

from rocket.errors import RetryableError, TooManyRequests
from rocket.retry import Backoff, retry

RETRY_STATUS = {500, 502, 503, 504}


def upload(client: httpx.Client, path: Path, url: str, backoff: Backoff | None = None) -> str:
    def put() -> str:
        try:
            r = client.put(url, content=path.read_bytes())
        except (httpx.ConnectError, httpx.RemoteProtocolError) as e:
            raise RetryableError(str(e)) from e
        if r.status_code == 429:
            raise TooManyRequests(float(r.headers.get("retry-after", 0)) or None)
        if r.status_code in RETRY_STATUS:
            raise RetryableError(f"{r.status_code} from {url}")
        r.raise_for_status()
        return r.headers["etag"]

    return retry(put, backoff)
EOF
commit mara $(( 26 * 60 )) "Retry on 5xx and connection resets"
cat >tests/test_retry.py <<'EOF'
import pytest

from rocket.errors import RetryableError, TooManyRequests
from rocket.retry import Backoff, retry


def test_returns_first_success():
    assert retry(lambda: 42) == 42


def test_gives_up():
    def boom():
        raise RetryableError()

    with pytest.raises(RetryableError):
        retry(boom, Backoff(max_attempts=2), sleep=lambda s: None)


def test_delay_is_capped():
    b = Backoff(max_delay=30.0)
    assert all(b.delay(n) <= 30.0 for n in range(20))


def flaky(err, fails=1):
    calls = []

    def fn():
        calls.append(1)
        if len(calls) <= fails:
            raise err
        return "ok"

    return fn


def test_honours_retry_after():
    sleeps = []
    retry(flaky(TooManyRequests(retry_after=3.0)), sleep=sleeps.append)
    assert sleeps == [3.0]
EOF
commit mara 14 "Cap jitter at max_delay"
git update-ref refs/remotes/origin/mara/retry-backoff HEAD
git checkout -q main
git branch -q -D mara/retry-backoff

echo "demo sandbox ready: $DEMO"
