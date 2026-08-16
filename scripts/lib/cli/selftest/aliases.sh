# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for the short forms (aliases).
# Cross-checks the table (rein_cli_aliases) against the implementation in **both directions**.
# Checking only one direction misses two different failures: an entry added to the table with the
# case forgotten (typed but has no effect), and an entry added to the case with the table
# forgotten (missing from the collision check and from the usage listing).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_aliases() {
  alias_verb_shorts="$(rein_cli_aliases | awk -F: '$1 == "verb" { printf " %s", $2 }')"
  alias_all_shorts="$(rein_cli_aliases | awk -F: '{ printf " %s", $2 }')"
  alias_missing=""
  alias_dup=""
  alias_seen=""
  # Usage merges each short form into the same line as its long form (`-C, --cwd <path>`), so
  # there's no path that **generates** the listing from the table. This looks up each table entry
  # inside the actual output instead, so that an entry added to the table but forgotten in usage
  # can't pass silently (checking both instead of generating one from the other).
  st_run --help
  alias_help_out="$ST_OUT"
  alias_help_missing=""
  while IFS= read -r alias_line; do
    [ -n "$alias_line" ] || continue
    alias_scope="${alias_line%%:*}"
    alias_rest="${alias_line#*:}"
    alias_short="${alias_rest%%:*}"
    alias_long="${alias_rest##*:}"
    # The case arms are pinned to one line reading "long form | short form" (so a reader can see
    # the correspondence right there). This looks it up in the dispatcher and **each verb's own
    # implementation file** (common options live in the dispatcher, verb options live in each
    # verb under lib/cli/). selftest itself lives under lib/cli/selftest/, so it's excluded --
    # the fake CLI's own case arms inside the check are never read as the implementation.
    if ! grep -qE "^[[:space:]]*${alias_long} \| ${alias_short}\)\$" \
      "$REIN_BIN_PATH" "$SCRIPTS_DIR"/lib/cli/*.sh; then
      alias_missing="${alias_missing}${alias_missing:+ }${alias_scope}:${alias_short}"
    fi
    # Confirms the pairing can be read from usage by checking that **both words appear on the
    # same line**. Pinning the join formatting (the `, ` in `-C, --cwd`) as a literal string
    # would break the moment the separator changed, while the property this actually cares about
    # (which short form maps to which long form) wouldn't have changed at all. This checks by
    # word specifically to avoid the case where `-a` is a substring of `--all` (a substring
    # match would pass even on a line that only has the long form).
    if ! printf '%s\n' "$alias_help_out" | awk -v short="$alias_short" -v long="$alias_long" '
      {
        n = split($0, f, /[[:space:],|\/]+/)
        has_short = 0
        has_long = 0
        for (i = 1; i <= n; i++) {
          if (f[i] == short) has_short = 1
          if (f[i] == long) has_long = 1
        }
        if (has_short && has_long) found = 1
      }
      END { exit found ? 0 : 1 }'; then
      alias_help_missing="${alias_help_missing}${alias_help_missing:+ }${alias_scope}:${alias_short}"
    fi
    # No 1-character short form should carry two meanings in the same scope. A verb's own scope
    # is in effect at the same time as the verb scope (which several verbs share), so that
    # overlap counts as a collision too. common sits in a different resolution position, so it
    # never overlaps with either.
    case " $alias_seen " in
      *" ${alias_scope}${alias_short} "*)
        alias_dup="${alias_dup}${alias_dup:+ }${alias_scope}:${alias_short}"
        continue
        ;;
    esac
    if [ "$alias_scope" != "common" ] && [ "$alias_scope" != "verb" ]; then
      case "$alias_verb_shorts " in
        *" ${alias_short} "*)
          alias_dup="${alias_dup}${alias_dup:+ }${alias_scope}:${alias_short}"
          ;;
      esac
    fi
    alias_seen="${alias_seen}${alias_seen:+ }${alias_scope}${alias_short}"
  done <<EOF
$(rein_cli_aliases)
EOF
  if [ -z "$alias_missing" ]; then
    st_ok
  else
    st_fail "a short form in the table has no matching case arm" "$alias_missing"
  fi
  if [ -z "$alias_dup" ]; then
    st_ok
  else
    st_fail "a short form collides within the same scope" "$alias_dup"
  fi
  if [ -z "$alias_help_missing" ]; then
    st_ok
  else
    st_fail "a short form in the table doesn't appear in usage" "$alias_help_missing"
  fi
  # Implementation -> table. Every 1-character option that appears in a case arm must be listed
  # in the table. Whitespace is stripped with [:blank:] (space and TAB only) -- [:space:] would
  # also strip newlines, melting every line into one and yielding text like `-a--project`, where
  # only the last "1-character option" would survive (a form that was actually hit, leaving this
  # check a no-op). `-h` is needed because several files are passed at once: without it a
  # filename prefix gets attached, the final narrowing catches nothing, and this check spins
  # empty while still passing.
  alias_unlisted=""
  while IFS= read -r alias_short; do
    [ -n "$alias_short" ] || continue
    case "$alias_all_shorts " in
      *" ${alias_short} "*) ;;
      *) alias_unlisted="${alias_unlisted}${alias_unlisted:+ }${alias_short}" ;;
    esac
  done <<EOF
$(grep -hE '^[[:space:]]*-{1,2}[A-Za-z][A-Za-z-]*([[:space:]]*\|[[:space:]]*-{1,2}[A-Za-z][A-Za-z-]*)*\)$' \
  "$REIN_BIN_PATH" "$SCRIPTS_DIR"/lib/cli/*.sh |
    tr -d '[:blank:])' | tr '|' '\n' | grep -E '^-[A-Za-z]$' | sort -u)
EOF
  if [ -z "$alias_unlisted" ]; then
    st_ok
  else
    st_fail "a short form in the implementation is missing from the table" "$alias_unlisted"
  fi

  # The short and long forms produce the same result (a representative path). For an option
  # that takes a value, the resolution can also be seen through the reason given when the value
  # is missing -- it comes back naming **the long form** (landing on a different branch would
  # give a different reason).
  st_run -R "$root" -C "$proj" -F "$tmp/alias-config" config set -u notice_cooldown_sec 900
  if st_expect_status "config set can be driven entirely by short forms" 0; then
    st_expect_file "writes to what -F points at" "$tmp/alias-config" "notice_cooldown_sec=900"
  fi
  st_run -R "$root" -C "$proj" -F "$tmp/alias-config" config get notice_cooldown_sec
  st_expect_out "-R -C -F -u resolve the same way as the long forms" "900"
  st_run --root "$root" --cwd "$proj" --config "$tmp/alias-config" config get notice_cooldown_sec
  st_expect_out "the long forms read the same value" "900"
  # --project is the default scope, so its effect shows in the reason not being "config unset
  # takes exactly one key" (the shape where `-p` got read as a key).
  st_run -R "$root" -C "$proj" config unset -p snooze_max_sec
  st_expect_reject "-p falls onto the same branch as --project" 1 "is not set"
  st_run --version
  alias_version_out="$ST_OUT"
  st_run -V
  st_expect_out "-V produces the same output as --version" "$alias_version_out"
  st_run -C
  st_expect_reject "-C falls onto the same branch as --cwd" 2 "--cwd requires a value"
  st_run -R
  st_expect_reject "-R falls onto the same branch as --root" 2 "--root requires a value"
  st_run -F
  st_expect_reject "-F falls onto the same branch as --config" 2 "--config requires a value"
  st_run -x
  st_expect_reject "an unknown 1-character flag is rejected as an option" 2 "unknown option: -x"
  st_run -h
  if st_expect_status "-h exits 0" 0; then
    st_expect_out "-h produces the same output as --help" "$alias_help_out"
  fi
  st_run -R "$root" -C "$proj" status -D
  st_expect_reject "-D falls onto the same branch as --runtime-dir" 2 "--runtime-dir requires a value"
  st_run -R "$root" -C "$proj" up -d -B -H "$tmp/handoff.md"
  st_expect_reject "up's short forms hit the same combination check" 2 "cannot both be given"
  st_run -R "$root" -C "$proj" up -s ""
  st_expect_reject "-s falls onto the same branch as --settings" 2 "--settings cannot take an empty value"
}
