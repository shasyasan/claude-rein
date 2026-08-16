# shellcheck shell=bash
# The write target's shape contract. In addition to atomic writing (`rein_write_json_atomic`),
# this also measures **the writers that don't go through that primitive** -- append
# (`rein_log_line`) and the usage writer (`rein-statusline.sh`'s own tmp-then-`mv`) -- under the
# same contract. It doesn't start the watcher, the seat, or a fake CLI, so this layer is pure
# (only the usage writer gets started once, as a short-lived child).
# This exists because when the destination is a directory, `mv` moves the temp file **inside** it
# and returns 0 -- without checking the replacement target's shape, the payload can land at
# `<final>/<basename>.<nonce>` while every caller still reads it as success (a reader reads
# `<final>` as JSON, so nobody ever sees that nothing was actually written). Since a caller only
# looks at the return value, this failure never shows up in a caller-side check.
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

ST_AW_PAYLOAD='{"schema":"rein.probe.v0","n":1}'
ST_AW_PAYLOAD_NEXT='{"schema":"rein.probe.v0","n":2}'

# Folds whatever the target is into one string (shape, link target, and content, all in one
# look). A FIFO is checked before a regular file so a FIFO with no reader on the other end never
# blocks on `cat`.
st_aw_witness() {
  local path="$1"
  if [ -L "$path" ]; then
    printf 'symlink -> %s\n' "$(readlink "$path")"
  elif [ -p "$path" ]; then
    printf 'fifo\n'
  elif [ -d "$path" ]; then
    printf 'dir\n'
  elif [ -f "$path" ]; then
    printf 'file\n'
    cat "$path"
  elif [ -e "$path" ]; then
    printf 'other\n'
  else
    printf 'absent\n'
  fi
}

# A snapshot folding this check's whole location together. **Includes the structure (find)** --
# both a payload that got sucked into a directory and a leftover temp file are caught by this
# one comparison.
st_aw_snapshot() {
  local final="$1" outside="$2"
  find "$ST_AW_DIR" -print | LC_ALL=C sort
  printf -- '--- final ---\n'
  st_aw_witness "$final"
  printf -- '--- outside ---\n'
  st_aw_witness "$outside"
}

# The rejecting side's shared view: non-zero, the location unchanged in any way, and a reason
# printed. That nothing was written can't be shown by the return value alone (`mv` really does
# return 0 without writing), so this also checks that the before-and-after snapshots match.
st_aw_expect_reject() {
  local name="$1" final="$2" outside="$3" before after err rc
  before="$(st_aw_snapshot "$final" "$outside")"
  err="$(rein_write_json_atomic "$final" "$ST_AW_PAYLOAD" 2>&1 >/dev/null)"
  rc=$?
  after="$(st_aw_snapshot "$final" "$outside")"
  if [ "$rc" -eq 0 ]; then
    st_fail "$name" "exited 0 (nothing was written, yet the caller reads success)"
    return
  fi
  if [ "$after" != "$before" ]; then
    st_fail "$name" "the location changed: before [${before}] / after [${after}]"
    return
  fi
  case "$err" in
    *"the write target is not a regular file"*) st_ok ;;
    *) st_fail "$name" "rejected with no reason printed: [${err}]" ;;
  esac
}

st_section_atomic_write() {
  # shellcheck disable=SC2154  # this check's temp directory is the caller selftest()'s local
  ST_AW_DIR="$tmp/atomic-write"
  mkdir -p "$ST_AW_DIR"

  # Accepting side (1): final doesn't exist. Its parent gets created if missing (existing contract).
  aw_final="$ST_AW_DIR/nested/fresh.json"
  if rein_write_json_atomic "$aw_final" "$ST_AW_PAYLOAD" &&
    [ -f "$aw_final" ] && [ ! -L "$aw_final" ] &&
    [ "$(cat "$aw_final")" = "$ST_AW_PAYLOAD" ]; then
    st_ok
  else
    st_fail "can write to a final that doesn't exist yet (creates the parent too)" "$(st_aw_witness "$aw_final")"
  fi
  # Accepting side (2): an existing regular file gets replaced (replacement isn't blocked).
  if rein_write_json_atomic "$aw_final" "$ST_AW_PAYLOAD_NEXT" &&
    [ -f "$aw_final" ] && [ ! -L "$aw_final" ] &&
    [ "$(cat "$aw_final")" = "$ST_AW_PAYLOAD_NEXT" ]; then
    st_ok
  else
    st_fail "replaces an existing regular file" "$(st_aw_witness "$aw_final")"
  fi
  st_expect_true "leaves no temp file behind even on a successful write" \
    test -z "$(find "$ST_AW_DIR/nested" -name 'fresh.json.*' -print)"

  # Accepting side (3): the location is created by going through **the one function that prepares
  # it** (rein_ensure_records_dir). Creating it with a plain `mkdir -p` would skip placing the
  # `*`-only `.gitignore`, and a round that rewrites a deleted `.rein/` would grow an untracked
  # directory in the user's own working tree. The destination includes
  # `<cwd>/.rein/current.json` (a pointer replacement), so **a regression on this path turns
  # red right here**.
  aw_final="$ST_AW_DIR/aw-proj/$REIN_RECORDS_DIRNAME/current.json"
  if rein_write_json_atomic "$aw_final" "$ST_AW_PAYLOAD" && [ -f "$aw_final" ]; then
    st_ok
  else
    st_fail "can also write to the records location" "$(st_aw_witness "$aw_final")"
  fi
  st_expect_file "the location is created by going through the one function that prepares it" \
    "$ST_AW_DIR/aw-proj/$REIN_RECORDS_DIRNAME/.gitignore" "*"

  # Rejecting side: the cases where final isn't a regular file. Every one of them has `mv` return 0
  # (a directory sucks the file in, a symlink gets its target swapped), so from the caller's
  # point of view none are distinguishable from success.
  aw_final="$ST_AW_DIR/as-dir.json"
  mkdir -p "$aw_final"
  st_aw_expect_reject "doesn't write when final is a directory" "$aw_final" "$aw_final"

  # This also checks the outside target: following the link and writing through it (the outside
  # target changes) and swapping the link itself (final's own witness changes) both fail on the
  # same single comparison.
  mkdir -p "$ST_AW_DIR/outside-dir"
  printf 'sentinel\n' >"$ST_AW_DIR/outside-dir/keep"
  aw_final="$ST_AW_DIR/as-dir-link.json"
  ln -s "$ST_AW_DIR/outside-dir" "$aw_final"
  st_aw_expect_reject "doesn't write when final is a symlink to a directory" \
    "$aw_final" "$ST_AW_DIR/outside-dir"

  printf 'sentinel\n' >"$ST_AW_DIR/outside-file"
  aw_final="$ST_AW_DIR/as-file-link.json"
  ln -s "$ST_AW_DIR/outside-file" "$aw_final"
  st_aw_expect_reject "doesn't write when final is a symlink to a regular file" \
    "$aw_final" "$ST_AW_DIR/outside-file"

  aw_final="$ST_AW_DIR/as-dangling-link.json"
  ln -s "$ST_AW_DIR/nowhere" "$aw_final"
  st_aw_expect_reject "doesn't write when final is a broken symlink" "$aw_final" "$ST_AW_DIR/nowhere"

  aw_final="$ST_AW_DIR/as-fifo.json"
  mkfifo "$aw_final"
  st_aw_expect_reject "doesn't write when final is a FIFO" "$aw_final" "$aw_final"

  # Rejecting side: the case where the **parent** is a symlink. `mkdir -p` follows it and
  # succeeds (the target's contents become the location), so a check that only looks at the
  # destination's shape catches none of this -- only the predicate that prepares the location
  # does. The reason text differs from the 5 cases above (it's about the location, not
  # the destination), so this checks it directly here rather than through the shared
  # st_aw_expect_reject.
  mkdir -p "$ST_AW_DIR/parent-outside"
  ln -s "$ST_AW_DIR/parent-outside" "$ST_AW_DIR/parent-link"
  aw_final="$ST_AW_DIR/parent-link/current.json"
  aw_before="$(st_aw_snapshot "$aw_final" "$ST_AW_DIR/parent-outside")"
  aw_err="$(rein_write_json_atomic "$aw_final" "$ST_AW_PAYLOAD" 2>&1 >/dev/null)"
  aw_rc=$?
  st_expect_true "doesn't exit 0 when the location is a symlink" test "$aw_rc" -ne 0
  st_expect_true "doesn't change the target when the location is a symlink" \
    test "$(st_aw_snapshot "$aw_final" "$ST_AW_DIR/parent-outside")" = "$aw_before"
  case "$aw_err" in
    *"the records location is a symbolic link"*) st_ok ;;
    *) st_fail "prints a reason when the location is a symlink" "[${aw_err}]" ;;
  esac

  # Rejecting side (a round where the replacement itself fails): leaves no temp file behind at
  # the location. Unlike the 5 cases above that fail at the shape check, here **the check passes
  # entirely and only the `mv` fails** -- the temp file already exists, so if it's never claimed
  # back, `<dest>.XXXXXX` stays behind at the location. The destination can also sit directly
  # under the runtime directory (a handover request, a stop marker, a snooze), so if it's left
  # behind, `rein prune`'s final `rmdir` is guaranteed to fail, saying it won't remove the
  # directory because something rein doesn't know about is still there, and that lineage can
  # never be folded away until the user removes it by hand (this temp name is absent from the
  # listing of known runtime artifacts). Making only the `mv` fail needs the destination's
  # immutable flag (`chflags uchg`) -- there's no other way to build a case where the shape
  # check and `mktemp` both pass and only the replacement fails with `Operation not permitted`.
  aw_final="$ST_AW_DIR/immutable.json"
  printf '%s\n' "$ST_AW_PAYLOAD" >"$aw_final"
  if chflags uchg "$aw_final"; then
    rein_write_json_atomic "$aw_final" "$ST_AW_PAYLOAD_NEXT" 2>/dev/null
    st_expect_true "a round where the replacement fails doesn't exit 0" test "$?" -ne 0
    st_expect_true "a round where the replacement fails leaves no temp file behind either" \
      test -z "$(find "$ST_AW_DIR" -maxdepth 1 -name 'immutable.json.*' -print)"
    st_expect_file "a round where the replacement fails doesn't change the destination" "$aw_final" "$ST_AW_PAYLOAD"
    # Forgetting to clear this would fail this check's final `rm -rf` too, taking down "leaves no temp directory behind" with it.
    chflags nouchg "$aw_final" ||
      st_fail "clears the immutable flag this check set" "$aw_final"
  else
    st_fail "can set up a state where only the replacement fails" "chflags uchg had no effect: ${aw_final}"
  fi

  # Applies the same contract to the 2 writers that don't go through this primitive (writing a
  # separate check per interface would split this one discipline apart, once per writer).
  st_append_dest_cases
  st_statusline_dest_cases
}

# Append destinations (rein_log_line).
#
# The handover log, the watcher log, and the hooks log are all built by appending (`>>`), not
# replacing -- so they never go through the atomic-write primitive. `>>` follows a symlink and
# writes to **the outside target**, and for a broken symlink it creates whatever the target
# names. A caller only looks at the return value, so both read as success.
ST_APPEND_DIR=""

st_append_snapshot() {
  find "$ST_APPEND_DIR" -print | LC_ALL=C sort
  printf -- '--- log ---\n'
  st_aw_witness "$1"
  printf -- '--- outside ---\n'
  st_aw_witness "$2"
}

st_append_expect_reject() {
  local name="$1" log="$2" outside="$3" before after err rc
  before="$(st_append_snapshot "$log" "$outside")"
  err="$(rein_log_event "$log" probe "checking the append destination" 2>&1 >/dev/null)"
  rc=$?
  after="$(st_append_snapshot "$log" "$outside")"
  if [ "$rc" -eq 0 ]; then
    st_fail "$name" "exited 0 (nothing was appended, yet the caller reads success)"
    return
  fi
  if [ "$after" != "$before" ]; then
    st_fail "$name" "the location changed: before [${before}] / after [${after}]"
    return
  fi
  case "$err" in
    *"the write target is not a regular file"*) st_ok ;;
    *) st_fail "$name" "rejected with no reason printed: [${err}]" ;;
  esac
}

st_append_lines() {
  local file="$1"
  [ -f "$file" ] || {
    printf 'absent\n'
    return 0
  }
  grep -c "" "$file"
}

st_append_dest_cases() {
  local log outside
  ST_APPEND_DIR="$tmp/append-dest"
  mkdir -p "$ST_APPEND_DIR/outside"
  printf 'sentinel\n' >"$ST_APPEND_DIR/outside/victim.log"

  # Accepting side (1): an append destination that doesn't exist gets created with 1 line (the parent too -- existing contract).
  log="$ST_APPEND_DIR/nested/handover.log"
  if rein_log_event "$log" probe "accepting side" && [ "$(st_append_lines "$log")" = "1" ]; then
    st_ok
  else
    st_fail "can append to a destination that doesn't exist yet (creates the parent too)" "$(st_aw_witness "$log")"
  fi
  # Accepting side (2): an existing regular file gets more lines appended.
  if rein_log_event "$log" probe "accepting side, second line" && [ "$(st_append_lines "$log")" = "2" ]; then
    st_ok
  else
    st_fail "appends more to an existing regular file" "$(st_aw_witness "$log")"
  fi

  # Rejecting side: the cases where the append destination isn't a regular file. A symlink is
  # observed by checking that **the outside target** grows.
  outside="$ST_APPEND_DIR/outside/victim.log"
  log="$ST_APPEND_DIR/as-file-link.log"
  ln -s "$outside" "$log"
  st_append_expect_reject "doesn't write when the append destination is a symlink to a regular file" "$log" "$outside"

  log="$ST_APPEND_DIR/as-dangling-link.log"
  ln -s "$ST_APPEND_DIR/outside/nowhere.log" "$log"
  st_append_expect_reject "doesn't write when the append destination is a broken symlink" \
    "$log" "$ST_APPEND_DIR/outside/nowhere.log"

  log="$ST_APPEND_DIR/as-dir.log"
  mkdir -p "$log"
  st_append_expect_reject "doesn't write when the append destination is a directory" "$log" "$log"
}

# The usage writer (statusline).
#
# Has its own tmp-then-`mv` that doesn't go through the atomic-write primitive. When the
# destination is a directory, `mv` moves the temp file inside it and returns 0 -- the display
# still shows, but recording it silently fails, and a reader (hooks) can't tell that apart from
# no writer running at all.
ST_SL_DIR=""
ST_SL_OUT=""
ST_SL_STATUS=0

st_statusline_run() {
  local sid="$1" payload
  payload="$(jq -nc --arg sid "$sid" --arg cwd "$ST_SL_DIR/proj" \
    '{session_id: $sid, cwd: $cwd, model: {display_name: "probe"},
      context_window: {used_percentage: 42, total_tokens: 100}}')"
  ST_SL_OUT="$(printf '%s' "$payload" | env \
    "HOME=$ST_SL_DIR/home" \
    "XDG_CONFIG_HOME=$ST_SL_DIR/home/.config" \
    "XDG_STATE_HOME=$ST_SL_DIR/home/.local/state" \
    "REIN_CONFIG_FILE=$ST_SL_DIR/user-config" \
    "REIN_USAGE_STATE_DIR=$ST_SL_DIR/usage" \
    "$ST_BASH" "$REPO_ROOT/$REIN_STATUSLINE_RELPATH" 2>&1)"
  ST_SL_STATUS=$?
}

st_statusline_dest_cases() {
  ST_SL_DIR="$tmp/statusline-dest"
  mkdir -p "$ST_SL_DIR/proj" "$ST_SL_DIR/home" "$ST_SL_DIR/usage"
  : >"$ST_SL_DIR/user-config"

  # Accepting side: the ordinary path still records usage as before (stopping the writer would leave the statusline silent).
  st_statusline_run sess-plain
  if [ "$ST_SL_STATUS" -eq 0 ]; then
    st_ok
  else
    st_fail "can record usage on the ordinary path" "exit=${ST_SL_STATUS}: ${ST_SL_OUT}"
  fi
  st_expect_true "the usage record survives as a regular file" \
    test -f "$ST_SL_DIR/usage/sess-plain.json"
  if [ "$(jq -r '.context_window.used_percentage' "$ST_SL_DIR/usage/sess-plain.json" 2>/dev/null)" = "42" ]; then
    st_ok
  else
    st_fail "the usage record carries the used percentage" "$(cat "$ST_SL_DIR/usage/sess-plain.json" 2>&1)"
  fi

  # Rejecting side: the destination is a directory. `mv`'s success isn't read as success.
  mkdir -p "$ST_SL_DIR/usage/sess-dir.json"
  st_statusline_run sess-dir
  if [ "$ST_SL_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "doesn't exit 0 when the usage destination is a directory" "exit=0: ${ST_SL_OUT}"
  fi
  case "$ST_SL_OUT" in
    *"the write target is not a regular file"*) st_ok ;;
    *) st_fail "prints a reason it couldn't write usage" "[${ST_SL_OUT}]" ;;
  esac
  st_expect_true "writes nothing inside the destination directory" \
    test -z "$(find "$ST_SL_DIR/usage/sess-dir.json" -mindepth 1 -print)"
}
