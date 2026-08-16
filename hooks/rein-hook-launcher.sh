#!/usr/bin/env bash
# The minimal launcher the plugin's hooks call. **Write this file so that it never
# needs updating** -- the plugin gets copied via the marketplace into
# `~/.claude/plugins/cache/`, so putting real implementation here means some install
# shapes end up running an old copy after an update (observed).
# So the contents are limited to exactly these 3 things:
#   (1) Follow the symlink at the command placed on PATH ($HOME/.local/bin/rein) to
#       its real location
#   (2) Start the hook-only runner next to that real location, passing it the calling
#       protocol version, and fold only an out-of-spec exit code into a non-blocking
#       failure (1) before returning
#   (3) When the link can't be resolved, don't die silently -- leave one line in the
#       plugin's own data location and write to stderr
# Don't guess the lineage (rein's state) and write it into some other log -- this
# layer doesn't know the lineage.
#
# **A timeout lands on this launcher, not on the runner.** Now that (2) no longer
# starts the runner with exec, the registration's timeout (10 seconds in
# hooks/hooks.json) cuts this process off from outside, and the child runner can run
# on to completion. Running to completion doesn't corrupt state -- the
# stop-blocking response is written to stdout before the log layer (see hook_stop in
# scripts/rein-hook.sh), so anything a surviving runner writes afterward only goes to
# its own log layer, never a second time to a stdout nobody is reading anymore.
# **The child is never terminated.** Two structural reasons:
#   - A trap doesn't fire on a foreground child. While bash is waiting for a
#     foreground child, it **does not run a trap for a signal it caught until the
#     child exits** (bash(1), "If bash is waiting for a command to complete ...").
#     Making it fire would require backgrounding the child and waiting on it, which
#     defaults stdin to /dev/null (same manual, "If a command is followed by a & ...")
#     -- i.e. it would import into this layer the pitfall of silently dropping the
#     payload.
#     The same judgment, with measurements, is recorded next to the trap in
#     scripts/rein-seat.sh (no explicit trap = immediate; one set = wait for the
#     child to exit).
#   - Making it actually work would require kill, which runs into the invariant that
#     this code never issues an OS process-stop operation (kill / pkill / etc.) -- the
#     one exception is the final `claude stop` at the end of a handover (see the
#     watcher lock section of docs/spec/runtime.md). This layer runs on every event of
#     every project, so it's the heaviest place to carve out a second exception.
set -uo pipefail

# Normalize the entry environment. Force the character set to UTF-8 (bash can't parse
# this file's syntax under a multibyte non-UTF-8 locale), and unset `CDPATH` (it
# makes `$(cd ... && pwd -P)` print two lines). Placed **before loading the shared
# library**. The canonical explanation lives next to the same two lines in bin/rein.
unset LC_ALL CDPATH
export LC_CTYPE=UTF-8

REIN_LAUNCHER_NAME="rein-hook-launcher.sh"
# The calling protocol version. This file's --selftest reads the real value on the
# runner side (REIN_HOOK_PROTOCOL in scripts/lib/rein-common.sh) and checks they
# match -- the two copies of this literal aren't kept in sync by a comment agreement
# alone.
REIN_LAUNCHER_PROTOCOL="1"
# Where the command placed on PATH lives. **There's no environment-variable
# override** -- this file runs on every event of every session with the plugin
# installed, the most privileged path there is. Open a way here for anyone who can
# set env vars to redirect the exec target, and an arbitrary script runs on every
# hook. The selftest below exercises this by overriding the variable only inside a
# subshell (calling it as a function within the same process, so both branches --
# resolvable and not -- can actually be measured without leaving a switch on the
# production path).
# **Leave it empty when HOME isn't an absolute path** (writing out
# `${HOME:-}/.local/bin/rein` with an empty HOME collapses to `/.local/bin/rein`,
# which starts with `/` and so looks like a valid absolute path). Proceeding with
# that collapsed value would report the reason as "/.local/bin/rein doesn't exist"
# and **name a path under the filesystem root that was never real** -- the actual
# reason (this session has no HOME) never surfaces. This layer doesn't load the
# shared library, so it applies the same discipline with its own 3 lines
# (launcher_main is where the reason gets named).
REIN_LINK=""
case "${HOME:-}" in
  /*) REIN_LINK="$HOME/.local/bin/rein" ;;
esac

# Follow a symlink to get its real path. macOS readlink has no -f, so this rolls its own.
launcher_resolve() {
  local path="$1" target dir count=0
  while [ -L "$path" ]; do
    count=$((count + 1))
    if [ "$count" -gt 32 ]; then
      return 1
    fi
    target="$(readlink "$path")" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="${path%/*}/$target" ;;
    esac
  done
  [ -e "$path" ] || return 1
  dir="$(cd "${path%/*}" && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "${path##*/}"
}

# The log's size cap (past it, rotate one generation and no more). A broken state --
# the plugin enabled without the symlink installed -- hits this path on **every event
# of every session**, so with no cap one broken install could grow the log without
# bound. Rotation keeps the same "one generation only" shape as rein's own log
# (hook_fire_log_rotate). No lock is taken here: every write is a single appended
# line, so the most a race can lose is that one line (bringing in locking discipline
# would outgrow what a minimal file that never needs updating can hold).
REIN_LAUNCHER_LOG_MAX_BYTES=262144

# Never die silently. The only place this writes to is the plugin's own data
# location (${CLAUDE_PLUGIN_DATA}) -- writing to rein's own log would require
# resolving the lineage, and that's the very thing that just failed.
launcher_fail() {
  local reason="$1" data="${CLAUDE_PLUGIN_DATA:-}" log size
  printf '%s: %s\n' "$REIN_LAUNCHER_NAME" "$reason" >&2
  if [ -n "$data" ] && mkdir -p "$data" 2>/dev/null; then
    log="$data/rein-hook-launcher.log"
    size="$(stat -f%z "$log" 2>/dev/null)"
    case "$size" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$size" -ge "$REIN_LAUNCHER_LOG_MAX_BYTES" ]; then
          mv -f "$log" "$log.1" 2>/dev/null || :
        fi
        ;;
    esac
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-}" "$REIN_LINK" \
      >>"$log" 2>/dev/null || : # record-append-exempt: this layer is the minimal launcher that doesn't load the shared library (written so that it never needs updating); the destination is the plugin's own data location, not the lineage's log
  fi
  # Internal errors return **non-blocking failure** (1). 2 means something different
  # per event -- for Stop it's a stop-block itself -- so don't let launcher trouble
  # turn into control over the mechanism.
  exit 1
}

launcher_main() {
  local real runner status
  if [ $# -lt 1 ]; then
    launcher_fail "no hook event was passed (check the command in the hooks/hooks.json registry)"
  fi
  if [ -z "$REIN_LINK" ]; then
    launcher_fail "cannot build the location of the command on PATH (HOME is not set to an absolute path)"
  fi
  if [ ! -e "$REIN_LINK" ] && [ ! -L "$REIN_LINK" ]; then
    launcher_fail "the command on PATH doesn't exist: ${REIN_LINK} (run rein init to install it)" # lineage-cmd-exempt: this layer doesn't know the lineage (the minimal launcher doesn't load the shared library), and this message fires before rein is even on PATH, so there's no effective value to name the lineage with
  fi
  real="$(launcher_resolve "$REIN_LINK")" ||
    launcher_fail "cannot resolve the command on PATH to its real location: ${REIN_LINK}"
  # The real location is <repo>/bin/rein. The hook-only runner sits next to it, in <repo>/scripts/.
  runner="${real%/*}"
  runner="${runner%/*}/scripts/rein-hook.sh"
  if [ ! -x "$runner" ]; then
    launcher_fail "the hook runner is not executable: ${runner}"
  fi
  # **Don't start it with exec.** exec replaces this process with the runner's, so
  # any exit code the shell itself produced for the runner (unparseable = 2, not
  # executable = 126/127, signal = 128+n) becomes the hook's exit code as-is. 2 means
  # something different per event -- for Stop it's a stop-block itself -- so a broken
  # runner would turn into control over the mechanism (and it wouldn't even go
  # through launcher_fail, so not even one log line would survive). Start it as a
  # child instead, pass through **only the values the runner returns itself** (0 =
  # normal, 1 = non-blocking failure), and fold everything else into 1 per the rule
  # above. stdin, stdout, and stderr are inherited by the child as-is, so both the
  # payload and any injected content pass through untouched.
  "$runner" --protocol "$REIN_LAUNCHER_PROTOCOL" "$@"
  status=$?
  case "$status" in
    0 | 1) exit "$status" ;;
  esac
  launcher_fail "the hook runner exited with an out-of-spec code (${status}): ${runner}"
}

# Test-only entry point. **Called as a function within the same process** (the
# override is a shell variable scoped to the subshell) -- this measures both
# branches of resolution without leaving an env override on the production path. The
# runner runs as the subshell's child, so its stdout and stderr belong to that
# subshell, and capturing them this way shows the arguments and stdin that reached
# it exactly as they were. The exit code also reaches the caller through the
# subshell's exit.
launcher_probe() {
  local link="$1" data="$2"
  shift 2
  (
    REIN_LINK="$link"
    CLAUDE_PLUGIN_DATA="$data"
    launcher_main "$@"
  ) 2>&1
}

# --selftest is the convention for runnable scripts (check.sh's gate runs it for
# every one). Here it measures, without touching real state or the real
# ~/.local/bin:
# (a) matching the runner's protocol version (pins the two copies of the literal mechanically)
# (b) not dying silently when it can't resolve the link (log, stderr, exit code)
# (c) passing the version to the runner when it can resolve the link
selftest() {
  local pass=0 fail=0 tmp lib runner_protocol out status
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rein-launcher-selftest.XXXXXX")" || {
    printf '%s: selftest 0 pass / 1 fail\n' "$REIN_LAUNCHER_NAME"
    return 1
  }
  lib="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)/scripts/lib/rein-common.sh"
  runner_protocol=""
  if [ -f "$lib" ]; then
    # The canonical version lives on the library side. This only reads the value
    # back out to compare (sourcing it would make the launcher depend on the shared
    # library, which would defeat the point of being minimal).
    runner_protocol="$(sed -n 's/^REIN_HOOK_PROTOCOL="\([^"]*\)"$/\1/p' "$lib")"
  fi
  if [ -n "$runner_protocol" ] && [ "$runner_protocol" = "$REIN_LAUNCHER_PROTOCOL" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL protocol version matches the runner side: launcher %s / library %s\n' \
      "$REIN_LAUNCHER_PROTOCOL" "${runner_protocol:-(could not read it)}"
  fi

  # (b) no real location: reason to stderr, one line to the plugin's data location, exit code 1.
  out="$(launcher_probe "$tmp/missing-link" "$tmp/plugin-data" stop </dev/null)"
  status=$?
  if [ "$status" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL missing real location exits with non-blocking failure: exit=%s\n' "$status"
  fi
  case "$out" in
    *"the command on PATH doesn't exist"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL missing real location writes its reason to stderr: %s\n' "$out"
      ;;
  esac
  if [ -s "$tmp/plugin-data/rein-hook-launcher.log" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL missing real location leaves one line in the plugin data location\n'
  fi

  # (b') can't even build the location (HOME empty, unset, or relative): don't name
  # the collapsed `/.local/bin/rein`, name HOME instead. Fails the same way as (b)
  # (non-blocking failure).
  out="$(launcher_probe "" "$tmp/plugin-data" stop </dev/null)"
  status=$?
  if [ "$status" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL an unbuildable location also exits with non-blocking failure: exit=%s\n' "$status"
  fi
  case "$out" in
    *"HOME is not set to an absolute path"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL an unbuildable location names HOME as the reason: %s\n' "$out"
      ;;
  esac
  case "$out" in
    *"/.local/bin/rein"*)
      fail=$((fail + 1))
      printf '  FAIL does not name the collapsed root-level path: %s\n' "$out"
      ;;
    *) pass=$((pass + 1)) ;;
  esac

  # Doesn't rotate before the cap (rotating on every event would leave only one line of
  # the failure history that led up to it).
  if [ ! -e "$tmp/plugin-data/rein-hook-launcher.log.1" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL does not rotate before the cap\n'
  fi
  # Rotates one generation once past the cap (a broken state writes on every event
  # of every session, so with no cap one broken install would grow without bound).
  head -c "$REIN_LAUNCHER_LOG_MAX_BYTES" /dev/zero | tr '\0' 'x' \
    >"$tmp/plugin-data/rein-hook-launcher.log"
  out="$(launcher_probe "$tmp/missing-link" "$tmp/plugin-data" stop </dev/null)"
  if [ -s "$tmp/plugin-data/rein-hook-launcher.log.1" ] &&
    [ "$(stat -f%z "$tmp/plugin-data/rein-hook-launcher.log" 2>/dev/null)" -lt \
      "$REIN_LAUNCHER_LOG_MAX_BYTES" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL rotates exactly one generation past the cap: %s\n' \
      "$(ls -l "$tmp/plugin-data" 2>&1)"
  fi

  # (c) resolvable case: passes `--protocol <version> <event>` to the runner
  # (follows symlinks too).
  mkdir -p "$tmp/repo/bin" "$tmp/repo/scripts" "$tmp/link-dir"
  : >"$tmp/repo/bin/rein"
  chmod +x "$tmp/repo/bin/rein"
  cat >"$tmp/repo/scripts/rein-hook.sh" <<'RUNNER'
#!/bin/sh
printf 'runner-args:%s\n' "$*"
printf 'runner-stdin:%s\n' "$(cat)"
RUNNER
  chmod +x "$tmp/repo/scripts/rein-hook.sh"
  ln -s "$tmp/repo/bin/rein" "$tmp/link-dir/rein"
  out="$(printf 'PAYLOAD' | launcher_probe "$tmp/link-dir/rein" "" post-tool-batch)"
  case "$out" in
    *"runner-args:--protocol ${REIN_LAUNCHER_PROTOCOL} post-tool-batch"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL passes the event to the runner with the version: %s\n' "$out"
      ;;
  esac
  case "$out" in
    *"runner-stdin:PAYLOAD"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL passes stdin through to the runner unchanged: %s\n' "$out"
      ;;
  esac
  launcher_probe "$tmp/link-dir/rein" "$tmp/plugin-data-rc0" post-tool-batch </dev/null >/dev/null
  status=$?
  if [ "$status" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL passes through a 0 from a runner that finished normally: exit=%s\n' "$status"
  fi

  # How exit codes get folded (measure **both** sides). Back when this started the
  # runner with exec, a shell-produced exit code for the runner became the hook's
  # exit code as-is, breaking the rule that internal errors are 1 for every event --
  # for Stop, 2 was a stop-block itself, and since it never went through
  # launcher_fail not even one log line survived. Measure the folded side
  # (out-of-spec 2) and the pass-through side (a 1 the runner returns itself) as a
  # pair.
  cat >"$tmp/repo/scripts/rein-hook.sh" <<'RUNNER'
#!/bin/sh
exit 2
RUNNER
  chmod +x "$tmp/repo/scripts/rein-hook.sh"
  out="$(launcher_probe "$tmp/link-dir/rein" "$tmp/plugin-data-rc" stop </dev/null)"
  status=$?
  if [ "$status" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL folds an out-of-spec exit code into non-blocking failure: exit=%s\n' "$status"
  fi
  case "$out" in
    *"exited with an out-of-spec code (2)"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL the folded reason carries the actual exit code: %s\n' "$out"
      ;;
  esac
  if [ -s "$tmp/plugin-data-rc/rein-hook-launcher.log" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL a folded call leaves one line in the plugin data location\n'
  fi
  # Pass-through side: a 1 the runner returns itself (non-blocking failure) is not
  # folded. The exit code alone can't tell folding apart from pass-through, so this
  # checks it by **no new log entry appearing**.
  cat >"$tmp/repo/scripts/rein-hook.sh" <<'RUNNER'
#!/bin/sh
exit 1
RUNNER
  chmod +x "$tmp/repo/scripts/rein-hook.sh"
  launcher_probe "$tmp/link-dir/rein" "$tmp/plugin-data-rc1" stop </dev/null >/dev/null
  status=$?
  if [ "$status" -eq 1 ] && [ ! -e "$tmp/plugin-data-rc1/rein-hook-launcher.log" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL a 1 the runner returns passes through unfolded: exit=%s / log=%s\n' \
      "$status" "$(ls "$tmp/plugin-data-rc1" 2>&1)"
  fi
  # No environment variable can redirect the exec target (fails if the override ever
  # comes back on the production path). Point env at a fake repo that does have a
  # real location, and knock only HOME down to an empty temp directory -- if the
  # override works, the runner's output shows up; if it doesn't, it fails because the
  # location under HOME is missing. This is the one check that runs a real process,
  # because it needs to go through **the production entry point itself** (a direct
  # invocation).
  out="$(env HOME="$tmp/empty-home" REIN_HOOK_LINK="$tmp/link-dir/rein" \
    "$BASH" "${BASH_SOURCE[0]}" stop 2>&1 </dev/null)"
  case "$out" in
    *"runner-args:"*)
      fail=$((fail + 1))
      printf '  FAIL an environment variable cannot redirect the exec target: %s\n' "$out"
      ;;
    *"$tmp/empty-home/.local/bin/rein"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL ignores the environment variable and looks at the location under HOME: %s\n' "$out"
      ;;
  esac

  # A runner that isn't executable also doesn't die silently.
  chmod -x "$tmp/repo/scripts/rein-hook.sh"
  out="$(launcher_probe "$tmp/link-dir/rein" "$tmp/plugin-data" stop </dev/null)"
  case "$out" in
    *"the hook runner is not executable"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL gives a reason when the runner is not executable: %s\n' "$out"
      ;;
  esac
  # A call with no event (a broken registry) also fails with a reason.
  out="$(launcher_probe "$tmp/link-dir/rein" "" </dev/null)"
  case "$out" in
    *"no hook event was passed"*) pass=$((pass + 1)) ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL fails a call with no event with a reason: %s\n' "$out"
      ;;
  esac

  rm -rf "$tmp"
  printf '%s: selftest %d pass / %d fail\n' "$REIN_LAUNCHER_NAME" "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest)
    selftest # test-side-scope-exempt: the one line that invokes the selftest entry point (not a production writer)
    exit $?
    ;;
esac
launcher_main "$@"
