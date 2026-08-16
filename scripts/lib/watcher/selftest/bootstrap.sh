# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Cold start (--bootstrap): launching a first generation, the handoff document's acceptance
# conditions (absent, a directory, a symlink, explicitly disabled), and refusing to run when a
# primary session already exists.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_bootstrap() {
  # Cold start: launches a first generation from no pointer, and creates a generation-1 pointer.
  # Just put the handoff document at its default location (next to the records) and pass neither
  # `--handoff` nor config -- confirm bootstrap resolves the default itself, by way of the
  # absolute path that lands in kickoff.
  case_dir="$tmp/bootstrap"
  st_setup_case "$case_dir"
  st_default_handoff="$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  printf 'handoff fixture\n' >"$st_default_handoff"
  # --once is added alongside so that a mutant breaking bootstrap's own interface cannot fall into
  # the resident loop and hang selftest (the failure comes out fast and red instead).
  ST_MODE_ARGS=(--bootstrap --once)
  st_run_watcher
  if st_expect_status "bootstrap launches a first generation" 0; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 0 ]; then
      st_fail "bootstrap launches with --bg" "$(cat "$ST_LOG")"
    elif [ "$(jq -r '.generation' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" != "1" ]; then
      st_fail "bootstrap's pointer is generation 1" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    elif [ "$(jq -r '.predecessor_session_id' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" != "null" ]; then
      st_fail "bootstrap's predecessor is null" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    kickoff_line="$(rein_st_call_arg "$ST_LOG" "$bg_call" "$ST_BG_ARGC_BASE")"
    case "$kickoff_line" in
      *"$st_default_handoff"*)
        st_ok
        ;;
      *)
        st_fail "bootstrap's kickoff carries the default handoff document" "the default path is missing: ${kickoff_line}"
        ;;
    esac
    if [ "$(jq -r '.handoff_path' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "$st_default_handoff" ]; then
      st_ok
    else
      st_fail "the pointer carries the default handoff document" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    fi
  fi

  # A cold start where no handoff document exists yet at the default location fails without
  # launching a first generation (fail-loud). Without attaching how to fix it (the command that
  # creates a template) to the reason, a first-time user would be left to figure it out.
  case_dir="$tmp/bootstrap-no-handoff"
  st_setup_case "$case_dir"
  st_run_watcher
  if st_expect_status "fails bootstrap with no handoff document" 2; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation with no handoff document" "claude --bg was called: $(cat "$ST_LOG")"
    else
      # The instructions are runnable as-is **for this lineage** (with `--cwd` attached) -- typing
      # them without `--cwd` would create the template in whatever lineage that's run from,
      # leaving this lineage still empty and repeating the same failure.
      case "$ST_OUT" in
        *"$ST_RECORDS/$REIN_HANDOFF_BASENAME"*"$(rein_shell_quote "$REIN_BIN") --cwd $(rein_shell_quote "$ST_CWD") init --runtime-dir $(rein_shell_quote "$ST_RUNTIME")"*)
          st_ok
          ;;
        *)
          st_fail "attaches the default path and per-lineage template instructions to the missing handoff document" "$ST_OUT"
          ;;
      esac
    fi
  fi

  # The acceptance conditions are "a non-symlink regular file, non-empty", checked through the
  # same one function as cold start (`rein init`'s template) and a handover request. A shape that
  # let a directory pass by treating "it has a size" as good enough would launch a first
  # generation with an unreadable handoff document and only have the handover request fail later.
  case_dir="$tmp/bootstrap-dir-handoff"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RECORDS/$REIN_HANDOFF_BASENAME/inner"
  st_run_watcher
  if st_expect_status "fails bootstrap on a directory as the handoff document" 2; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation on a directory" "claude --bg was called: $(cat "$ST_LOG")"
    else
      case "$ST_OUT" in
        *"the handoff document is not a regular file"*"$ST_RECORDS/$REIN_HANDOFF_BASENAME"*)
          st_ok
          ;;
        *)
          st_fail "names the reason for an unacceptable shape" "$ST_OUT"
          ;;
      esac
    fi
  fi

  # A symlink is likewise refused (repointing it would swap out the existence, non-empty, and freshness checks).
  case_dir="$tmp/bootstrap-symlink-handoff"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_CWD/real-handoff.md"
  ln -s "$ST_CWD/real-handoff.md" "$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  st_run_watcher
  if st_expect_status "fails bootstrap on a symlinked handoff document" 2; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation on a symlink" "claude --bg was called: $(cat "$ST_LOG")"
    else
      case "$ST_OUT" in
        *"symlink"*) st_ok ;;
        *) st_fail "names the symlink as the reason" "$ST_OUT" ;;
      esac
    fi
  fi

  # A lineage whose config explicitly sets `handoff_path` to empty launches a first generation
  # with no handoff document (never falls back to the default -- honors the config layer's
  # "explicit empty = disabled" here too).
  case_dir="$tmp/bootstrap-handoff-disabled"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  printf 'handoff_path=\n' >"$ST_USER_CONFIG"
  st_run_watcher
  : >"$ST_USER_CONFIG"
  if st_expect_status "bootstrap goes through with the handoff document disabled" 0; then
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    kickoff_line="$(rein_st_call_arg "$ST_LOG" "$bg_call" "$ST_BG_ARGC_BASE")"
    case "$kickoff_line" in
      *"$ST_RECORDS/$REIN_HANDOFF_BASENAME"*)
        st_fail "never grabs the default handoff document for a lineage that disabled it" "${kickoff_line}"
        ;;
      *"Start work as this project's primary session."*"<absolute path to the handoff document>"*)
        st_ok
        ;;
      *)
        st_fail "builds kickoff with no handoff document" "${kickoff_line}"
        ;;
    esac
    if [ "$(jq -r '.handoff_path' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "null" ]; then
      st_ok
    else
      st_fail "a pointer with no handoff document has handoff_path null" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    fi
  fi

  # bootstrap with an already-live pointer refuses, to never create a second primary session.
  case_dir="$tmp/bootstrap-occupied"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 1
  st_run_watcher
  if st_expect_status "refuses bootstrap while a primary session is present" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation while one is present" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! st_expect_notify "notifies that bootstrap was aborted" \
      "rein: aborted bootstrap" "bootstrap is unnecessary"; then
      :
    else
      st_ok
    fi
  fi

  # Never launches when the pointer's target has exited but **the predecessor is still alive**
  # (only one side of a handover died). Letting the listing succeed **only on the first call**
  # (`ST_AGENTS_FAIL_AFTER=1`) is because an implementation that re-fetches the listing separately
  # for the liveness judgment and for "is the predecessor left behind" would let a one-off,
  # transient failure on the second call silently fall to the "no predecessor" side, launching a
  # first generation and ending up with **two primary sessions alongside the live predecessor**.
  # Fetching the listing once removes any room for that second call to fail at all.
  case_dir="$tmp/bootstrap-stranded"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "succ-gone" "successor" "$ST_CWD" 2 "pred-1"
  ST_AGENTS_FAIL_AFTER=1
  st_run_watcher
  unset ST_AGENTS_FAIL_AFTER
  if st_expect_status "refuses bootstrap while the predecessor is still alive" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation while the predecessor is alive" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! st_expect_notify "notifies that only one side of the handover died" \
      "rein: aborted bootstrap" "only one side of the handover died"; then
      :
    else
      st_ok
    fi
  fi

  # A cycle where the listing itself can't be read never falls to "the predecessor is absent" --
  # it aborts (silently defaulting an undetermined judgment could let bootstrap create a second
  # primary session in a lineage whose listing is broken).
  case_dir="$tmp/bootstrap-agents-unreadable"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "succ-gone" "successor" "$ST_CWD" 2 "pred-1"
  ST_AGENTS_FAIL=1
  st_run_watcher
  unset ST_AGENTS_FAIL
  if st_expect_status "refuses bootstrap when the listing can't be read" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation when the listing can't be read" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! st_expect_notify "notifies that it can't be judged" \
      "rein: aborted bootstrap" "cannot judge whether the existing pointer is live"; then
      :
    else
      st_ok
    fi
  fi

  # When the handover's mutual exclusion can't be claimed (the resident watcher is currently
  # advancing a handover for the same lineage), bootstrap defers instead of launching. Without
  # this, the watcher's first cycle after `rein up` started it and `up`'s own bootstrap would both
  # read the pointer, and **two successors of the same generation** would launch (the pointer is
  # only written after a successor's launch is confirmed, so a defense that just checks a live
  # target would let this window through untouched). Build the mutual exclusion's holder as a
  # "live process" -- the discipline of never seizing a lock whose pid is alive is what stops this.
  case_dir="$tmp/bootstrap-handover-locked"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  mkdir -p "$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME"
  printf '%s\n' "$$" >"$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME/pid"
  st_run_watcher
  if st_expect_status "refuses bootstrap when the handover's mutual exclusion can't be claimed" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation without the mutual exclusion" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! st_expect_notify "notifies that it aborted on the mutual exclusion" \
      "rein: aborted bootstrap" "cannot claim the handover lock"; then
      :
    else
      st_ok
    fi
  fi
  # The accepting side's counterpart: a mutual exclusion with no live owner (stale) is reclaimed
  # and it proceeds -- staying strictly "never seize it" would let a single run that died
  # mid-handover permanently block that lineage's bootstrap.
  printf '%s\n' 999999 >"$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME/pid"
  : >"$ST_LOG"
  st_run_watcher
  if st_expect_status "reclaims a mutual exclusion with no live owner" 0; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 0 ]; then
      st_fail "launches a first generation once reclaimed" "claude --bg was never called: $(cat "$ST_LOG")"
    else
      st_ok
    fi
  fi
  if [ ! -e "$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME" ]; then
    st_ok
  else
    st_fail "never leaves the mutual exclusion behind after exiting" \
      "$(ls -a "$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME" 2>&1)"
  fi
  # bootstrap has no marker to consume, so there's nowhere to leave a launch declaration
  # (launch_attempt) -- if it's killed from outside between `claude --bg` landing and the pointer
  # being written (the window is the launch-confirmation wait), the first generation it launched
  # is left pointed at by no one. The recovery side (recover_orphan_processing) only works from a
  # processing marker, so this launch is never picked up by it, and the next cold start sees only
  # "there's no pointer" and sails through, launching a second first generation -- since kickoff
  # tells it to "Start work as this project's primary session.", the two can end up editing the
  # same working tree.
  # At minimum, refuse to launch if a background session under the name about to be claimed is
  # already alive in the target cwd. The accepting side's counterpart is the case at the top of
  # this section (no session with that name means a first generation launches as usual).
  case_dir="$tmp/bootstrap-name-taken"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  # Place a background session under the default naming (<cwd's name>-rein-g1), with no pointer --
  # the shape a previous bootstrap left behind after launching but before it could record its target.
  jq -nc --arg cwd "$ST_CWD" --arg name "${ST_CWD##*/}-rein-g1" \
    --argjson started "$REIN_ST_STARTED_AT_MS" \
    '[{pid: 4242, cwd: $cwd, kind: "background", startedAt: $started,
       id: "job-orphan-1", sessionId: "orphan-1", name: $name, state: "working", status: "busy"}]' \
    >"$ST_AGENTS"
  st_run_watcher
  if st_expect_status "refuses a cold start with a same-named background session present" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "never launches a first generation when the name is taken" "claude --bg was called: $(cat "$ST_LOG")"
    elif [ -e "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "never writes a pointer on a refused round" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    elif ! st_expect_notify "names the leftover same-named session and aborts" \
      "rein: aborted bootstrap" "${ST_CWD##*/}-rein-g1"; then
      :
    else
      st_ok
    fi
  fi

  ST_MODE_ARGS=(--once)

}
