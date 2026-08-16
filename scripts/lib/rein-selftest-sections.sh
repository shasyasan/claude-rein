# shellcheck shell=bash
# Entry point for selecting and running selftest sections by name (--selftest [section ...]
# and --selftest --list).
# Sourced by the executable scripts that have sections (bin/rein, rein-watcher.sh).
# Section names have the form <layer>:<name>. The layer says whether the section spawns real
# processes, and that lines up closely with how long it takes to run -- proc sections spawn
# child processes (watcher, seat, the fake CLI), pure sections don't (argument parsing,
# config-layer resolution, checking pure functions). Running only the layer under repair cuts
# the round trip from the full suite's running time down to that section's.
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest
# convention).

# The caller defines rein_st_section_table (one line per entry: "<layer>:<name> <function>").
# The table's **order is the run order** -- the argument order never changes it (sections build
# state across each other by design, so if the order shifted with how the caller typed the
# arguments, failures would stop reproducing).

REIN_ST_SECTION_MODE="run"
REIN_ST_SECTION_SELECTED=""

rein_st_section_names() {
  rein_st_section_table | awk 'NF { print $1 }'
}

rein_st_section_func() {
  rein_st_section_table | awk -v want="$1" '$1 == want { print $2 }'
}

# Interprets the arguments after --selftest as a section selection. An unknown section name
# is rejected outright instead of silently running 0 sections (even 0 sections would print a summary
# line of "0 pass / 0 fail", which looks the same as everything passing).
rein_st_sections_parse() {
  local arg name known
  REIN_ST_SECTION_MODE="run"
  REIN_ST_SECTION_SELECTED=""
  for arg in "$@"; do
    case "$arg" in
      --list)
        # shellcheck disable=SC2034  # read by each script's selftest side -- looks unused within this file
        REIN_ST_SECTION_MODE="list"
        ;;
      -*)
        printf '%s: unknown --selftest option: %s (list section names with --selftest --list)\n' \
          "$SCRIPT_NAME" "$arg" >&2
        return 2
        ;;
      *)
        known=0
        while IFS= read -r name; do
          [ "$name" = "$arg" ] && known=1
        done <<EOF
$(rein_st_section_names)
EOF
        if [ "$known" -eq 0 ]; then
          printf '%s: no section by that name: %s (list with --selftest --list)\n' \
            "$SCRIPT_NAME" "$arg" >&2
          return 2
        fi
        REIN_ST_SECTION_SELECTED="${REIN_ST_SECTION_SELECTED}${REIN_ST_SECTION_SELECTED:+ }${arg}"
        ;;
    esac
  done
  return 0
}

rein_st_sections_print_list() {
  rein_st_section_names
}

rein_st_section_wanted() {
  case " $REIN_ST_SECTION_SELECTED " in
    "  ") return 0 ;;
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Calls only the selected sections, in the table's order (all of them if the selection is empty).
# **Read the section list to completion before calling any section.** Calling sections while
# still reading the list (a "while read" loop that calls a section in its body) would let a
# section that reads stdin swallow the rest of the list along with its own input, and every
# section after it would **silently get skipped** -- no failure is reported, the count just
# shrinks, so nothing signals that the suite thinned out.
rein_st_sections_run() {
  local names name func
  names="$(rein_st_section_names)"
  for name in $names; do
    rein_st_section_wanted "$name" || continue
    func="$(rein_st_section_func "$name")"
    # Don't let a table entry with no matching function pass silently (if it did, no failure
    # would be reported and just that section's checks would disappear). Count it the way each
    # selftest's st_fail does.
    if [ -z "$func" ] || ! type "$func" >/dev/null 2>&1; then
      st_fail "the section table matches its implementations" "no implementation for ${name} (${func:-no function name in the table})"
      continue
    fi
    "$func"
  done
}
