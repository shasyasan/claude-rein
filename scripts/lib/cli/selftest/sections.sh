# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for the entry point that selects and runs selftest sections itself
# (`--selftest [section name ...]` and `--selftest --list`). Without this, a broken entry point
# still shows "everything passed" (only the person selecting a section quietly loses coverage).
# Every section named here for a nested run starts no real process (`pure:`) -- so this section
# doesn't break the layer definition itself.
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

# Stand-in sections that act like a section reading stdin (called from the subshell below). A real
# section may one day use `read` or `cat` with no arguments, so this locks in the guarantee that
# the remaining sections still run when that happens.
st_probe_section_a() {
  printf 'a\n' >>"$ST_SECTION_PROBE_LOG"
}

st_probe_section_b() {
  cat >/dev/null
  printf 'b\n' >>"$ST_SECTION_PROBE_LOG"
}

st_probe_section_c() {
  printf 'c\n' >>"$ST_SECTION_PROBE_LOG"
}

st_section_sections() {
  local one_count two_count

  # The listing matches the section table word for word (the table is canonical -- don't build a
  # separate path that writes the listing out by hand).
  st_run --selftest --list
  if st_expect_status "--selftest --list exits 0" 0; then
    st_expect_out "the listing is exactly the section table" "$(rein_st_section_names)"
  fi

  # Naming a section still keeps the contract's final line (so check.sh's summary-line check
  # still passes as-is).
  st_run --selftest pure:aliases
  one_count=""
  if st_expect_status "--selftest with a named section exits 0" 0; then
    case "$(printf '%s\n' "$ST_OUT" | tail -1)" in
      "rein: selftest "[0-9]*" pass / 0 fail")
        st_ok
        one_count="$(printf '%s\n' "$ST_OUT" | tail -1 | awk '{ print $3 }')"
        ;;
      *) st_fail "naming a section still keeps the summary-line format" "$(printf '%s\n' "$ST_OUT" | tail -1)" ;;
    esac
  fi
  # Confirm the naming actually narrows the selection: adding one more section raises the count.
  # Pinning a literal count would break every time a case is added, so this checks the
  # relationship (**increases**) instead of pinning the count for one section.
  st_run --selftest pure:aliases pure:clock
  if st_expect_status "two sections can be named at once" 0; then
    two_count="$(printf '%s\n' "$ST_OUT" | tail -1 | awk '{ print $3 }')"
    if [ -n "$one_count" ] && [ -n "$two_count" ] && [ "$two_count" -gt "$one_count" ]; then
      st_ok
    else
      st_fail "only the named sections run" "1 section=${one_count} / 2 sections=${two_count}"
    fi
  fi

  # A section that reads stdin still lets the sections after it run. With a structure that reads
  # the section listing while it's also calling sections, a section that reads stdin would eat the
  # rest of the listing and **silently** skip sections (no failure appears -- only the count drops,
  # so nobody notices the coverage got thinner). This swaps out the table and the selection, so it
  # runs inside a subshell.
  ST_SECTION_PROBE_LOG="$tmp/section-probe.log"
  : >"$ST_SECTION_PROBE_LOG"
  (
    # shellcheck disable=SC2329  # called by rein_st_sections_run (reads the swapped-in table indirectly)
    rein_st_section_table() {
      cat <<'EOF'
pure:probe-a st_probe_section_a
pure:probe-b st_probe_section_b
pure:probe-c st_probe_section_c
EOF
    }
    REIN_ST_SECTION_SELECTED=""
    rein_st_sections_run
  ) <<'EOF'
line 1 fed to the section that reads stdin
line 2
line 3
EOF
  st_expect_true "the remaining sections still run even when one reads stdin" \
    test "$(tr '\n' ' ' <"$ST_SECTION_PROBE_LOG")" = "a b c "

  # The rejecting side: an unknown section name or an unknown option must not silently run 0
  # sections (0 sections still prints the summary line as `0 pass / 0 fail`, which looks the same
  # as everything passing).
  st_run --selftest no-such-section
  st_expect_reject "rejects an unknown section name" 2 "no section by that name"
  st_run --selftest --bogus
  st_expect_reject "rejects an unknown --selftest option" 2 "unknown --selftest option"
}
