# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest's config layer (the known-keys table, layer priority, writing, and `--root`
# isolation) and the common options.
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

# Parses usage's **structure** from output and returns it (never looks at the wording). Given
# `rein help`'s output on standard input and a command name as the argument, prints the
# structural violations one per line, ending with `count <lines with a description>`.
# Why this doesn't pin the wording: making the check fail every time explanatory text is
# touched would add nothing but wording pins while never actually guarding the structural
# property (adding one command verb would break unrelated pins).
#   align: a section's description column starts at two or more different positions (no
#          alignment is required across sections).
#   desc:  a listing line has no description (reverted to a bare verb-name listing). The
#          leading call-form line (one starting with the command name) and a heading line
#          that has more-indented lines under it are exempt from needing a description.
# Columns are counted by display width (counting by character count would miss the alignment
# breaking only on lines with full-width characters mixed in).
# Written in perl because display width needs to be measured on top of bash 3.2 (the
# dependency is already checked by doctor).
st_help_layout() {
  perl -CSD -e '
    sub wid {
      my $n = 0;
      for my $c (split //, shift) {
        my $o = ord $c;
        my $wide = ($o >= 0x1100) && (
          $o <= 0x115F || ($o >= 0x2E80 && $o <= 0xA4CF) || ($o >= 0xAC00 && $o <= 0xD7A3) ||
          ($o >= 0xF900 && $o <= 0xFAFF) || ($o >= 0xFE30 && $o <= 0xFE6F) ||
          ($o >= 0xFF00 && $o <= 0xFF60) || ($o >= 0xFFE0 && $o <= 0xFFE6) ||
          ($o >= 0x20000 && $o <= 0x3FFFD));
        $n += $wide ? 2 : 1;
      }
      return $n;
    }
    my $prog = shift @ARGV;
    my $section = "";
    my @items;
    while (my $line = <STDIN>) {
      chomp $line;
      next if $line =~ /^\s*$/;
      if ($line =~ /^\S.*:$/) { $section = $line; next; }
      next unless $line =~ /^(\s+)(\S.*?)\s*$/;
      my ($indent, $rest) = (wid($1), $2);
      my $col = -1;
      if ($rest =~ /^(.*?\S)(\s\s+)\S/) { $col = $indent + wid($1) + wid($2); }
      my ($first) = ($rest =~ /^(\S+)/);
      push @items, [$section, $indent, $col, $first];
    }
    my (%cols, @order, $described);
    $described = 0;
    for my $i (0 .. $#items) {
      my ($sec, $indent, $col, $first) = @{ $items[$i] };
      if ($col >= 0) {
        push @order, $sec unless exists $cols{$sec};
        $cols{$sec}{$col} = 1;
        $described++;
        next;
      }
      next if $first eq $prog;
      next if $i < $#items && $items[$i + 1][1] > $indent;
      print "desc [$sec] item=$first\n";
    }
    for my $sec (@order) {
      my @c = sort { $a <=> $b } keys %{ $cols{$sec} };
      next if @c <= 1;
      print "align [$sec] cols=" . join(",", @c) . "\n";
    }
    print "count $described\n";
  ' "$1"
}

# The **value and origin lines** that `config list` should print for a lineage with nothing
# configured (in the same order as the known-keys table). The description lines (the indented
# "type and unit -- meaning") are never copied here -- their one canonical source is the
# known-keys table, and having the check hold the same wording would mean fixing one word in
# two places every time (forgetting one shows up as "the implementation is right but the
# check is red"). The description is pinned by **shape**, not wording (st_config_list_desc) --
# the same judgment as not pinning `rein help`'s wording.
# The point of holding the expected values as **literals** in this table: looking them up from
# the known-keys table instead would make this check follow the default and stay green any
# time a default is changed (turning the check that guards against default drift into no check
# at all).
# Conversely, adding one key means this table also needs updating (writing it here as an
# intended change).
# The only 2 defaults that can't be written as literals in this table: the handoff document
# following cwd ($1) and the usage location following HOME. Each is pinned by its own separate
# check for how it's resolved.
st_config_default_list() {
  printf '%s\t(default)\n' \
    'poll_interval_sec=5' \
    'cmd_timeout_sec=60' \
    'final_output_timeout_sec=120' \
    'final_output_wait_sec=10' \
    'launch_timeout_sec=120' \
    'exit_grace_sec=15' \
    'stop_timeout_sec=60' \
    'watcher_log_max_bytes=1048576' \
    'marker_max_age_sec=900' \
    'max_clock_skew_sec=60' \
    'handoff_fresh_window_sec=600' \
    'seat_wait_timeout_sec=0' \
    'seat_attach_retry_max=3' \
    'seat_heartbeat_max_age_sec=60' \
    'threshold_notice=30' \
    'threshold_handover=40' \
    'notice_cooldown_sec=1800' \
    'usage_stale_sec=1800' \
    'snooze_max_sec=3600' \
    'archive_days=30' \
    'model=' \
    'settings=' \
    'runtime_dir=' \
    "handoff_path=$1" \
    'kickoff_note_path=' \
    "usage_state_dir=${HOME:-}/.claude/state/context-usage" # home-base-exempt: the expected value for a default the implementation returns, built on the check side (not a location being resolved)
}

# Parses the **structure** of the description lines from `config list`'s output (standard
# input) and returns it. Prints the structural violations one per line, ending with
# `count <description lines successfully parsed>` (the same shape as st_help_layout, which
# doesn't pin `rein help`'s wording either).
# A shape with an empty label or an empty meaning is also caught here -- there's no separate
# check that peeks directly at the known-keys table's variables for blank fields (having two
# checks for the same property would let one get fixed while the other doesn't).
#   missing: a value-and-origin line isn't followed right after by a description line (the
#            2-line pairing broke).
#   stray:   an indented line appears with no value-and-origin line ahead of it (a description
#            line showed up outside a pair).
#   shape:   a description line isn't shaped like "<non-empty text> -- <non-empty text>" (no
#            separator, or the type-and-unit label or the meaning is empty).
st_config_list_desc() {
  local line prev="" want=0 desc ok found=0
  while IFS= read -r line; do
    case "$line" in
      '    '*)
        if [ "$want" -eq 0 ]; then
          printf 'stray [%s]\n' "$line"
          continue
        fi
        want=0
        desc="${line#    }"
        ok=1
        case "$desc" in
          *' -- '*)
            [ -n "${desc%% -- *}" ] || ok=0
            [ -n "${desc#* -- }" ] || ok=0
            ;;
          *) ok=0 ;;
        esac
        if [ "$ok" -eq 1 ]; then
          found=$((found + 1))
        else
          printf 'shape [%s] description=[%s]\n' "$prev" "$desc"
        fi
        ;;
      *)
        [ "$want" -eq 0 ] || printf 'missing [%s]\n' "$prev"
        prev="$line"
        want=1
        ;;
    esac
  done
  [ "$want" -eq 0 ] || printf 'missing [%s]\n' "$prev"
  printf 'count %s\n' "$found"
}

st_section_config() {
  # Cross-check the environment variable name mapping for every key. It can be derived from a
  # generation rule, but the table's second column is canonical -- a spelling drift on the
  # reading side becomes a silent no-op (a setting that was set but has no effect).
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    rein_config_lookup "$key" || {
      st_fail "can look up a known key" "$key"
      continue
    }
    env_name="REIN_${REIN_CFG_KEY_UPPER}"
    expected_env="REIN_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    if [ "$env_name" = "$expected_env" ]; then
      st_ok
    else
      st_fail "environment variable name mapping for ${key}" "table has ${env_name} / rule gives ${expected_env}"
    fi
  done <<EOF
$(rein_config_keys)
EOF

  # Mechanically pin the premise that only string-typed keys can hold a secret.
  # A type-violation reason includes the value (a string type never fails for a reason other
  # than a newline, and that reason text never includes the value). If a secret-capable key of
  # another type is ever added, that type's reason text has to withhold the value too.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    rein_config_lookup "$key" || continue
    if [ "$REIN_CFG_KEY_SECRET" = "1" ] && [ "$REIN_CFG_KEY_TYPE" != "string" ]; then
      st_fail "a secret-capable key must be of type string" \
        "${key} is ${REIN_CFG_KEY_TYPE} (that type's reason text needs a fix to withhold the value)"
    fi
  done <<EOF
$(rein_config_keys)
EOF
  st_ok

  # Pin the key set itself. A change in count means an intended edit to this file too.
  # **The literal lives only in this one place** -- writing the same count into a second check
  # would give a pin that breaks in 2 places when a key is added, and one of them ends up
  # unfixed. Every check after this one cross-checks against key_count instead.
  key_count="$(rein_config_keys | wc -l | tr -d ' ')"
  if [ "$key_count" = "26" ]; then
    st_ok
  else
    st_fail "pin the known-key count" "count isn't 26: ${key_count}"
  fi
  # The known-keys table is expanded exactly once, at source time. Structurally confirms a
  # function that reruns the heredoc on every lookup hasn't come back (a performance
  # regression never shows up in the output).
  if type rein_config_spec >/dev/null 2>&1; then
    st_fail "don't fork to read the known-keys table on every lookup" "rein_config_spec is back"
  else
    st_ok
  fi
  st_expect_true "the known-key list is expanded at source time" test -n "$REIN_CFG_KEYS"

  # The default the shared library uses before the config layer runs (the external-command
  # cap) must match the known-keys table's default. A mismatch means "two different caps take
  # effect when nothing is configured."
  rein_config_lookup cmd_timeout_sec
  if [ "$REIN_CFG_KEY_DEFAULT" = "$REIN_CMD_TIMEOUT_SEC" ]; then
    st_ok
  else
    st_fail "the shared library's default matches config's" \
      "config=${REIN_CFG_KEY_DEFAULT} / shared library=${REIN_CMD_TIMEOUT_SEC}"
  fi
  # The effective value lands in a separate variable that doesn't carry the REIN_ prefix.
  # If the caller had exported that environment variable, folding the effective value into a
  # REIN_-named variable would keep the export attribute through `printf -v`, and the folded
  # value would leak into the successor session `claude --bg` launches (the environment layer
  # beating the file layer).
  if [ "$CMD_TIMEOUT_SEC" = "$REIN_CFG_KEY_DEFAULT" ]; then
    st_ok
  else
    st_fail "the effective-value slot matches the default" \
      "config=${REIN_CFG_KEY_DEFAULT} / effective-value slot=${CMD_TIMEOUT_SEC}"
  fi

  # --version prints 3 lines: version, contract schema version, real file path.
  # **Never copy the version literal here** -- its one canonical source is the plugin manifest
  # (the `version` in `.claude-plugin/plugin.json`), and both the implementation and the
  # expected value are drawn from it. Copying it would make bumping the version itself turn
  # this check red (implementation correct, check wrong). Where it can't be read at all,
  # the expected value thins down to `rein `, which passes on anything -- so a separate check
  # measures **non-emptiness** first.
  st_expect_true "can read a version from the plugin manifest" test -n "$(rein_plugin_version)"
  st_run --version
  if st_expect_status "--version exits 0" 0; then
    st_expect_contains "--version prints the version" "rein $(rein_plugin_version)"
    st_expect_contains "--version prints the contract schema version" "contract-schema $REIN_MARKER_SCHEMA"
    st_expect_contains "--version prints the real file path" "path $REIN_BIN_PATH"
  fi

  # With nothing configured, every key is at its default.
  st_run --root "$root" --cwd "$proj" config get threshold_notice
  if st_expect_status "can read the default value" 0; then
    st_expect_out "can read the default value" "30"
  fi
  st_run --root "$root" --cwd "$proj" config list
  if st_expect_status "list exits 0" 0; then
    count="$(printf '%s\n' "$ST_OUT" | grep -c '=')"
    if [ "$count" = "$key_count" ]; then
      st_ok
    else
      st_fail "list prints every key" "line count ${count} (known keys: ${key_count})"
    fi
    st_expect_contains "unset shows origin default" "threshold_notice=30"$'\t'"(default)"
    # The shared library's own default, held in a **shell variable**, must never be read as
    # "specified by the environment." Misreading it would silently ignore the config file's
    # value (the config layer stops doing anything).
    st_expect_contains "the common default isn't read as the environment layer" "cmd_timeout_sec=60"$'\t'"(default)"
  fi
  mkdir -p "$proj/.rein"
  printf 'cmd_timeout_sec=15\n' >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config get cmd_timeout_sec
  st_expect_out "config still takes effect for a key common also has a default for" "15"
  rm -f "$project_config"

  # The default that follows cwd (the handoff document, next to the records). Since this
  # default can't be written into the known-keys table, check that get / list / --root all
  # resolve through one single resolution rather than re-deriving it per code path (a drift here
  # would mean a handover request and bootstrap read a different file as canonical).
  default_handoff="$proj/$REIN_RECORDS_DIRNAME/$REIN_HANDOFF_BASENAME"
  root_handoff="$root/$REIN_ROOT_RECORDS_RELDIR/$(rein_cwd_key "$proj")/$REIN_HANDOFF_BASENAME"
  st_run --config "$tmp/empty-user-config" --cwd "$proj" config get handoff_path
  if st_expect_status "can read the default lineage handoff document" 0; then
    st_expect_out "the default handoff document is next to the records" "$default_handoff"
  fi
  st_run --root "$root" --cwd "$proj" config get handoff_path
  if st_expect_status "can read the handoff document for a root-relocated lineage" 0; then
    st_expect_out "a root-relocated lineage's handoff document is next to that side's records" "$root_handoff"
  fi
  st_run --root "$root" --cwd "$proj" config list
  st_expect_contains "the cwd-following default also has origin default" "handoff_path=${root_handoff}"$'\t'"(default)"
  # Cross-check the default **value itself** for every key. The "list prints every key" check
  # above only looks at the line count, so no check ever failed when a default was changed
  # (drift only ever showed up in production). `--root` makes runtime_dir's origin the
  # environment layer, so this one check alone skips going through the root.
  st_run --config "$tmp/empty-user-config" --cwd "$proj" config list
  if st_expect_status "the defaults-only list exits 0" 0; then
    # Only cross-check the value-and-origin lines (drop the description lines first).
    list_values="$(printf '%s\n' "$ST_OUT" | grep -v '^    ')"
    list_defaults="$(st_config_default_list "$default_handoff")"
    if [ "$list_values" = "$list_defaults" ]; then
      st_ok
    else
      st_fail "cross-check the default value for every key" \
        "value-and-origin lines differ: expected [${list_defaults}] / actual [${list_values}]"
    fi
    # The description lines are checked by **shape**, not by wording (what this guards is
    # explained at the top of st_config_list_desc).
    list_desc="$(printf '%s\n' "$ST_OUT" | st_config_list_desc)"
    list_desc_pair="$(printf '%s\n' "$list_desc" | grep -e '^missing ' -e '^stray ')"
    if [ -z "$list_desc_pair" ]; then
      st_ok
    else
      st_fail "each key's value line is followed by exactly one description line" "$list_desc_pair"
    fi
    list_desc_shape="$(printf '%s\n' "$list_desc" | grep '^shape ')"
    if [ -z "$list_desc_shape" ]; then
      st_ok
    else
      st_fail "the description lines are shaped as \"type and unit -- meaning\"" "$list_desc_shape"
    fi
    # Distinguish "the parse ran on nothing yet passed" (the output shape changed wholesale)
    # from the 2 checks above.
    list_desc_count="$(printf '%s\n' "$list_desc" | sed -n 's/^count //p')"
    if [ "$list_desc_count" = "$key_count" ]; then
      st_ok
    else
      st_fail "description lines are parsed for every key" \
        "the parsed description line count isn't ${key_count}: [${list_desc_count}]"
    fi
  fi
  # Reading alone never creates a location (never spawns a records location just to print a
  # default).
  mkdir -p "$tmp/fresh-proj"
  st_run --config "$tmp/empty-user-config" --cwd "$tmp/fresh-proj" config get handoff_path
  if st_expect_status "can print a default even for a cwd with no records yet" 0; then
    st_expect_true "reading a default never creates a records location" \
      test ! -e "$tmp/fresh-proj/$REIN_RECORDS_DIRNAME"
  fi

  # The project scope is the default write target.
  st_run --root "$root" --cwd "$proj" config set threshold_notice 25
  if st_expect_status "config set exits 0" 0; then
    st_expect_file "set's default scope is project" "$project_config" "threshold_notice=25"
  fi
  st_expect_file ".rein never goes into VCS" "$proj/.rein/.gitignore" "*"
  if [ -z "$(find "$proj/.rein" -name 'config.*' -print 2>/dev/null)" ]; then
    st_ok
  else
    st_fail "no leftover temp files from the rewrite" "$(find "$proj/.rein" -name 'config.*')"
  fi
  # A newly created config isn't readable by anyone else (it can hold a secret in plaintext).
  st_expect_true "a new config's mode is 0600" test "$(stat -f '%Lp' "$project_config")" = "600"

  # The project scope outranks the user scope.
  st_run --root "$root" --cwd "$proj" config set --user threshold_notice 12
  if st_expect_status "can write to the user scope" 0; then
    st_expect_file "--user writes under --root" "$user_config" "threshold_notice=12"
  fi
  st_run --root "$root" --cwd "$proj" config get threshold_notice
  st_expect_out "project outranks user" "25"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_contains "origin shows the project's real path" "threshold_notice=25"$'\t'"(project:${project_config})"

  # An environment variable outranks a file.
  st_run_with "REIN_THRESHOLD_NOTICE=22" --root "$root" --cwd "$proj" config get threshold_notice
  st_expect_out "an environment variable outranks a file" "22"

  # A REIN_* that isn't a config target is silently ignored (the selftest override channel
  # actually exists).
  st_run_with "REIN_NOT_A_CONFIG_KEY=1" --root "$root" --cwd "$proj" config get threshold_notice
  if st_expect_status "an unknown-key REIN_* is ignored" 0; then
    st_expect_out "an unknown-key REIN_* is ignored" "25"
  fi

  # The "unset -- default" vs. "explicitly empty -- disabled" distinction.
  st_run --root "$root" --cwd "$proj" config set --user model opus
  st_expect_status "write model to user" 0 && st_ok
  st_run --root "$root" --cwd "$proj" config get model
  st_expect_out "an unset project falls back to the user's value" "opus"
  st_run --root "$root" --cwd "$proj" config set model ""
  st_expect_status "can write an empty value" 0 && st_ok
  st_run --root "$root" --cwd "$proj" config get model
  st_expect_out "explicitly empty doesn't revive the user's value" ""
  st_run --root "$root" --cwd "$proj" config list
  st_expect_contains "explicitly empty can be told apart by origin" "model="$'\t'"(project:${project_config})"

  # Even a key whose default isn't empty stays explicitly-empty rather than reverting to the
  # default (model's default is also empty, so model alone can't catch the broken
  # "treat explicitly-empty as unset" shape).
  st_run --root "$root" --cwd "$proj" config set usage_state_dir ""
  st_expect_status "can write an empty value to a key whose default isn't empty" 0 && st_ok
  st_run --root "$root" --cwd "$proj" config get usage_state_dir
  st_expect_out "explicitly empty doesn't revive the default" ""
  st_run --root "$root" --cwd "$proj" config unset usage_state_dir
  st_expect_status "cleanup unset" 0 && st_ok
  st_run --root "$root" --cwd "$proj" config get usage_state_dir
  st_expect_out "unset reverts to the default" "${HOME:-}/.claude/state/context-usage" # home-base-exempt: the expected value for a default the implementation returns (not a location being resolved)

  # unset revives the layer below.
  st_run --root "$root" --cwd "$proj" config unset model
  st_expect_status "unset exits 0" 0 && st_ok
  st_run --root "$root" --cwd "$proj" config get model
  st_expect_out "unset revives the layer below" "opus"

  # Other keys, comments, ordering, and a trailing blank line are all left untouched.
  printf '# leading comment\nthreshold_notice=25\n# comment in the middle\nsnooze_max_sec=1200\n\n\n' >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  line_count="$(wc -l <"$project_config" | tr -d ' ')"
  st_run --root "$root" --cwd "$proj" config set threshold_notice 26
  if st_expect_status "can rewrite an existing file" 0; then
    st_expect_true "keeps comments and ordering" \
      test "$(st_file_content "$project_config")" = "$(printf '# leading comment\nthreshold_notice=26\n# comment in the middle\nsnooze_max_sec=1200')"
    # The total line count doesn't change across the rewrite (the trailing blank lines aren't
    # eaten). Putting the fixture's line count in as a literal would make touching the fixture
    # break an unrelated pin.
    st_expect_true "keeps the trailing blank line" \
      test "$(wc -l <"$project_config" | tr -d ' ')" = "$line_count"
  fi

  # Carries forward an existing config's mode (a rewrite never discards permissions the user
  # tightened).
  chmod 640 "$project_config"
  st_run --root "$root" --cwd "$proj" config set threshold_notice 27
  st_expect_true "carries forward an existing config's mode" test "$(stat -f '%Lp' "$project_config")" = "640"
  chmod 600 "$project_config"

  # A symlinked config is written through to the real file (a symlink never gets replaced with
  # a regular file).
  mkdir -p "$tmp/linked"
  printf 'threshold_notice=25\n' >"$tmp/linked/real-config"
  rm -f "$user_config"
  ln -s "$tmp/linked/real-config" "$user_config"
  st_run --root "$root" --cwd "$proj" config set --user threshold_notice 21
  if st_expect_status "can write to a symlinked config" 0; then
    st_expect_true "stays a symlink" test -L "$user_config"
    st_expect_file "writes through to the symlink's real file" "$tmp/linked/real-config" "threshold_notice=21"
  fi
  rm -f "$user_config"
  printf 'threshold_notice=12\nmodel=opus\n' >"$user_config"

  # When the project-scope config is a symlink, `.gitignore` is never created on the real
  # side's directory (that can be the user's own separate repository -- putting a `*` there
  # would hide everything under it from git). Same for the project-scope decision ledger.
  mkdir -p "$tmp/linked-project"
  printf 'threshold_notice=25\n' >"$tmp/linked-project/real-config"
  rm -f "$project_config"
  ln -s "$tmp/linked-project/real-config" "$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config set threshold_notice 24
  if st_expect_status "can write to a symlinked project config" 0; then
    st_expect_file "writes through to the symlink's real file (project)" "$tmp/linked-project/real-config" "threshold_notice=24"
    st_expect_true "never creates a .gitignore at the symlink's target" test ! -e "$tmp/linked-project/.gitignore"
    st_expect_true "the records location's .gitignore is left alone" test -e "$proj/.rein/.gitignore"
  fi
  rm -f "$project_config"

  # An existing .gitignore is never touched. Never creates a dangling symlink's target either.
  printf 'keep me\n' >"$proj/.rein/.gitignore"
  st_run --root "$root" --cwd "$proj" config set threshold_notice 28
  st_expect_file "never overwrites an existing .gitignore" "$proj/.rein/.gitignore" "keep me"
  rm -f "$proj/.rein/.gitignore"
  ln -s "$tmp/never-created" "$proj/.rein/.gitignore"
  st_run --root "$root" --cwd "$proj" config set threshold_notice 29
  st_expect_true "never creates a dangling .gitignore symlink's target" test ! -e "$tmp/never-created"
  st_expect_true "leaves the .gitignore symlink as it is" test -L "$proj/.rein/.gitignore"
  rm -f "$proj/.rein/.gitignore"
  printf '*\n' >"$proj/.rein/.gitignore"

  # A value is taken verbatim (never shell-expanded). Written with single quotes since the
  # point is to pass a literal that could be expanded.
  # shellcheck disable=SC2016
  st_run --root "$root" --cwd "$proj" config set settings '${HOME}/x $(date) *'
  if st_expect_status "can write text that could be expanded" 0; then
    st_run --root "$root" --cwd "$proj" config get settings
    # shellcheck disable=SC2016
    st_expect_out "reads the value back verbatim" '${HOME}/x $(date) *'
  fi

  # A secret-capable key is masked in the listing (config is plaintext, and can hold JSON that
  # includes credentials).
  secret='{"env":{"TOKEN":"s3cr3t-value"}}'
  st_run --root "$root" --cwd "$proj" config set settings "$secret"
  st_expect_status "can write a secret-capable value" 0 && st_ok
  st_run --root "$root" --cwd "$proj" config list
  if st_expect_status "list exits 0 even with a secret in config" 0; then
    st_expect_not_contains "list never prints the secret in full" "s3cr3t-value"
    st_expect_contains "list prints the masking marker" "settings=***"
  fi
  st_run --root "$root" --cwd "$proj" config get settings
  st_expect_out "get, naming the key explicitly, prints the value in full" "$secret"
  st_run --root "$root" --cwd "$proj" config unset settings
  st_expect_status "cleanup unset" 0 && st_ok

  # --config names the user-scope file explicitly.
  # The allow record lives next to the user config, so a lineage whose user config was
  # relocated needs to be allowed again (an allow decision belongs to a single lineage -- a
  # decision made under a different root never takes effect as-is).
  st_allow_project --root "$root" --cwd "$proj" --config "$tmp/alt/config"
  st_run --root "$root" --cwd "$proj" --config "$tmp/alt/config" config set --user notice_cooldown_sec 900
  if st_expect_status "can write to where --config points" 0; then
    st_expect_file "writes to where --config points" "$tmp/alt/config" "notice_cooldown_sec=900"
  fi
  st_run --root "$root" --cwd "$proj" --config "$tmp/alt/config" config get notice_cooldown_sec
  st_expect_out "reads from where --config points" "900"
  st_run --root "$root" --cwd "$proj" config get notice_cooldown_sec
  st_expect_out "without --config, that location is never read" "1800"

  # --root isolation. Even with a different path present in the environment, a run through
  # --root never touches outside it.
  st_run_with "REIN_CONFIG_FILE=$outside_config" \
    --root "$root" --cwd "$proj" config set --user seat_attach_retry_max 5
  if st_expect_status "--root outranks the environment's REIN_CONFIG_FILE" 0; then
    st_expect_file "never rewrites the outside config" "$outside_config" "threshold_notice=7"
    if grep -q 'seat_attach_retry_max=5' "$user_config"; then
      st_ok
    else
      st_fail "writes to the config under root" "$(st_file_content "$user_config")"
    fi
  fi
  st_run --root "$root" --cwd "$proj" config unset --user seat_attach_retry_max
  st_expect_status "cleanup unset" 0 && st_ok

  # A read-only command never creates a location. Measured on a cwd with no project settings,
  # since the allow record's location is also under root (next to the user config) -- measuring
  # on a cwd that requires an allow decision would end up measuring "an allow decision is
  # required," not "a read never creates root."
  st_run --root "$tmp/never-root" --cwd "$tmp/fresh-proj" config get threshold_notice
  if st_expect_status "can read even with a --root that doesn't exist" 0; then
    st_expect_true "a read never creates --root" test ! -e "$tmp/never-root"
  fi

  # From here down, the rejecting side.
  st_run --root "$root" --cwd "$proj" config get bogus_key
  st_expect_reject "get rejects an unknown key" 2 "unknown key"
  st_run --root "$root" --cwd "$proj" config set bogus_key 1
  st_expect_reject "set rejects an unknown key" 2 "unknown key"
  case "$(st_file_content "$project_config")" in
    *bogus_key*)
      st_fail "never writes an unknown key" "$(st_file_content "$project_config")"
      ;;
    *)
      st_ok
      ;;
  esac

  st_run --root "$root" --cwd "$proj" config set threshold_notice 150
  st_expect_reject "rejects a percent out of range" 2 "between 0 and 100"
  st_run --root "$root" --cwd "$proj" config set threshold_notice abc
  st_expect_reject "rejects a non-numeric value" 2 "between 0 and 100"
  # The other percent key is rejected the same way. The cross-field check (notice > handover)
  # only gets easier to satisfy the higher handover goes -- so it papers right over a
  # value-domain break: if the type column were confused with percent, 500 could be written,
  # and the gate that forces a handover would never fire again.
  st_run --root "$root" --cwd "$proj" config set threshold_handover 500
  st_expect_reject "rejects an out-of-range handover threshold" 2 "between 0 and 100"
  st_run --root "$root" --cwd "$proj" config set threshold_handover abc
  st_expect_reject "rejects a non-numeric handover threshold" 2 "between 0 and 100"
  st_run --root "$root" --cwd "$proj" config set cmd_timeout_sec 0
  st_expect_reject "a positive-integer key doesn't allow 0" 2 "the setting value is invalid"
  # A leading zero passes the type check (`[`'s integer comparison, base 10), but arithmetic
  # evaluation reads it as octal -- if it were allowed through, a later stage (rein up's
  # deadline arithmetic) would fail **for a reason unrelated to the configured value**. Reject
  # it at write time instead.
  st_run --root "$root" --cwd "$proj" config set cmd_timeout_sec 08
  st_expect_reject "rejects a leading-zero positive integer" 2 "the setting value is invalid"
  st_run --root "$root" --cwd "$proj" config set launch_timeout_sec 007
  st_expect_reject "rejects a leading-zero nonnegative integer too" 2 "the setting value is invalid"
  # The accepting side's counterpart: a single-digit `0` (the floor of a nonnegative integer) and `0.2`
  # for a type that allows a fraction stay untouched -- if the leading-zero rejection widened
  # to "reject anything starting with 0," these two would get caught in it.
  st_run --root "$root" --cwd "$proj" config set seat_wait_timeout_sec 0
  st_expect_status "a nonnegative 0 passes" 0
  st_run --root "$root" --cwd "$proj" config set poll_interval_sec 0.2
  st_expect_status "a fractional poll interval passes" 0
  st_run --root "$root" --cwd "$proj" config unset seat_wait_timeout_sec
  st_expect_status "revert the value this check set" 0
  st_run --root "$root" --cwd "$proj" config unset poll_interval_sec
  st_expect_status "revert the interval this check set" 0
  # A type that doesn't accept empty is pointed at unset (the operation that falls back to the
  # default).
  st_run --root "$root" --cwd "$proj" config set cmd_timeout_sec ""
  st_expect_reject "a type that doesn't accept empty is pointed at a layer-named unset" 2 "config unset --user cmd_timeout_sec or config unset --project cmd_timeout_sec"
  st_run --root "$root" --cwd "$proj" config set handoff_path relative/path.md
  st_expect_reject "rejects a relative path" 2 "absolute path"
  # The point of this check is to pass `~` verbatim, without expansion.
  # shellcheck disable=SC2088
  st_run --root "$root" --cwd "$proj" config set handoff_path '~/handoff.md'
  st_expect_reject "rejects it since ~ isn't expanded" 2 "absolute path"

  # A value containing a newline is rejected regardless of layer (breaking the one-setting-
  # per-line premise lets a value inject a different key).
  printf 'threshold_notice=26\n' >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config set settings "$(printf 'a\nthreshold_handover=1')"
  st_expect_reject "rejects a value containing a newline" 2 "newline"
  st_expect_file "a value containing a newline never changes the file" "$project_config" "threshold_notice=26"

  # A newline coming from an environment variable is the same (never silently truncated at the
  # first line).
  st_run_with "$(printf 'REIN_SETTINGS=a\nthreshold_handover=1')" \
    --root "$root" --cwd "$proj" config get settings
  st_expect_reject "rejects a newline from an environment variable rather than truncating it" 1 "newline"
  # A newline in an unrelated environment variable's value can't inject a key from there.
  st_run_with "$(printf 'UNRELATED=x\nREIN_THRESHOLD_NOTICE=99')" \
    --root "$root" --cwd "$proj" config get threshold_notice
  if st_expect_status "an unrelated environment variable's newline doesn't fail this" 0; then
    st_expect_out "an environment variable's value can't inject a key" "26"
  fi

  # A cross-field violation (each value valid on its own, but the combination is meaningless).
  printf 'threshold_notice=26\nthreshold_handover=40\n' >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config set threshold_handover 20
  if st_expect_reject "rejects a cross-field violation" 1 "threshold_handover"; then
    st_expect_contains "the violation's reason names an origin" "from project:${project_config}"
  fi
  st_expect_true "a cross-field violation never changes the file" \
    test "$(st_file_content "$project_config")" = "$(printf 'threshold_notice=26\nthreshold_handover=40')"

  # Even when an environment variable is hiding a violation, it's still rejected as a violation
  # in the file layer (letting it write while hidden would leave behind a config that "wrote
  # fine, but every other reader fails").
  printf 'threshold_handover=20\n' >"$user_config"
  : >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run_with "REIN_THRESHOLD_HANDOVER=90" --root "$root" --cwd "$proj" config set threshold_notice 50
  st_expect_reject "rejects a violation an environment variable was hiding" 1 "threshold_handover"
  st_expect_file "a hidden violation never changes the file" "$project_config" ""

  # Conversely, a violation only an environment variable brought in is downgraded to a warning
  # rather than rejected (the file itself is correct).
  printf 'threshold_handover=40\n' >"$user_config"
  st_run_with "REIN_THRESHOLD_NOTICE=90" --root "$root" --cwd "$proj" config set snooze_max_sec 1200
  if st_expect_status "a violation only from an environment variable isn't rejected" 0; then
    st_expect_contains "a violation only from an environment variable is reported as a warning" "warning:"
    st_expect_file "still saved even with the warning" "$project_config" "snooze_max_sec=1200"
  fi

  # A config whose combination is broken can still be fixed from the CLI (stuck with no way to
  # diagnose or repair would be a dead end).
  printf 'threshold_notice=45\nthreshold_handover=40\n' >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config list
  if st_expect_reject "list exits non-zero for a config with a violation" 1 "threshold_notice"; then
    line_count="$(printf '%s\n' "$ST_OUT" | grep -c '=')"
    if [ "$line_count" = "$key_count" ]; then
      st_ok
    else
      st_fail "the listing still prints everything even with a violation" "line count ${line_count} (known keys: ${key_count})"
    fi
  fi
  st_run --root "$root" --cwd "$proj" config set threshold_handover 90
  if st_expect_status "can fix a config with a violation using set" 0; then
    st_expect_true "the fixed result reads back correctly" \
      test "$(st_file_content "$project_config")" = "$(printf 'threshold_notice=45\nthreshold_handover=90')"
  fi
  printf 'threshold_notice=45\nthreshold_handover=40\n' >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config unset threshold_notice
  st_expect_status "can fix a config with a violation using unset" 0 && st_ok

  # **A violation in a single value is repairable from the CLI too, not just a combination.**
  # The combination check was already kept out of the write verbs' way, but reading the layers
  # sat right next to it and fails on one bad value -- so `set` and `unset`, the two verbs that
  # exist to repair it, were the two that stopped working. The fixture goes in the user layer,
  # which has no allow gate: a project file that doesn't validate can't be allowed in the first
  # place, so measuring there would measure the gate instead of the load.
  printf 'threshold_handover=abc\n' >"$user_config"
  : >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config list
  # **The read side stays strict.** Widening the load's failure to every verb is what this must
  # not turn into, so the reading verbs are measured on the same fixture, in the same breath.
  st_expect_reject "list still exits non-zero for a single type violation" 1 "threshold_handover"
  st_run --root "$root" --cwd "$proj" config get threshold_notice
  st_expect_reject "get still exits non-zero for a single type violation" 1 "threshold_handover"
  st_run --root "$root" --cwd "$proj" config set --user threshold_handover 90
  if st_expect_status "can repair a single type violation using set" 0; then
    st_expect_file "the repaired value is what the file now holds" "$user_config" "threshold_handover=90"
    # The load failure is reported, not swallowed -- proceeding past it in silence would leave
    # the user unaware their settings were unreadable for the whole run leading up to this.
    # Pinned on this run's own wording, not on the bare word "warning" (the cross-field warning
    # prints under the same prefix, so matching that alone would pass on the wrong line).
    st_expect_contains "the run that repaired it still says the settings could not be read" \
      "the settings cannot be read as they stand"
  fi
  # A key the table doesn't know cannot be repaired by `set` (every write re-reads the layers,
  # and the stray line fails that read), so **the repair for a typo is removing the line** --
  # which means `unset` has to accept a key that is on a line of the file but not in the table.
  # Its counterpart, a key that is neither known nor in the file, is still a usage error.
  printf 'thresold_handover=40\n' >"$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "list still exits non-zero for a mistyped key" 1 "unknown key"
  st_run --root "$root" --cwd "$proj" config set --user threshold_handover 90
  st_expect_reject "set cannot repair a mistyped key (the stray line still fails the re-read)" 1 "unknown key"
  st_expect_file "a rejected repair leaves the file exactly as it was" "$user_config" "thresold_handover=40"
  st_run --root "$root" --cwd "$proj" config unset --user thresold_handover
  if st_expect_status "unset removes a mistyped key that is really in the file" 0; then
    st_expect_file "removing the mistyped key empties the file" "$user_config" ""
  fi
  st_run --root "$root" --cwd "$proj" config unset --user thresold_handover
  st_expect_reject "a key neither known nor in the file is still a usage error" 2 "unknown key"
  : >"$user_config"

  # **`config unset` names the layer the value is actually in.** The scope defaults to project,
  # so a value living in the user layer makes the instruction the user was handed remove
  # nothing -- and with no pointer at where it does live, there is no next step to take.
  printf 'threshold_handover=40\n' >"$user_config"
  : >"$project_config"
  st_allow_project --root "$root" --cwd "$proj"
  st_run --root "$root" --cwd "$proj" config unset threshold_handover
  if st_expect_reject "unset fails when the key is not in the scope it was aimed at" 1 "is not set in"; then
    st_expect_contains "the failure names the layer the value is in" "comes from the user layer"
    st_expect_contains "the failure hands over the line that would clear it" \
      "config unset --user threshold_handover"
  fi
  # The counterpart: a layer `config` cannot clear at all says why, and hands over no command
  # line (a line that cannot work is worse than none). The file layers are emptied first, so the
  # environment variable is the only place the value can be coming from.
  : >"$user_config"
  st_run_with "REIN_THRESHOLD_HANDOVER=40" --root "$root" --cwd "$proj" config unset --user threshold_handover
  if st_expect_reject "unset says why an environment-variable value cannot be named" 1 "is not set in"; then
    st_expect_contains "the failure names the environment variable" "REIN_THRESHOLD_HANDOVER"
    st_expect_not_contains "and hands over no unset line it could not honour" "config unset --"
  fi
  : >"$user_config"

  # A format violation in a hand-written config is also rejected on the reading side. The
  # reason never includes the line's content.
  printf 'unknown_key=1\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "rejects an unknown key in a file" 1 "unknown key"

  printf 'this-line-holds-s3cr3t\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  if st_expect_reject "rejects a line not in key=value form" 1 "not in key=value form"; then
    st_expect_not_contains "the format-violation reason never includes the line's content" "s3cr3t"
  fi

  printf 'source /etc/passwd\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "rejects a source line" 1 "not in key=value form"

  printf '  # indented comment\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "rejects an indented comment" 1 "not in key=value form"

  printf '  # threshold_notice=25\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "never reads an indented comment as a setting" 1 "invalid key name"

  printf ' threshold_notice=25\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "rejects a key with leading whitespace" 1 "invalid key name"

  printf 'THRESHOLD_NOTICE=25\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "rejects an uppercase key" 1 "invalid key name"

  printf 'threshold_notice=25\nthreshold_notice=26\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "rejects a duplicate key within the same file" 1 "duplicate key"

  printf 'threshold_notice=200\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "rejects an out-of-range value in a file" 1 "between 0 and 100"

  printf 'threshold_handover=200\n' >"$project_config"
  st_allow_project_file "$project_config" "$user_config"
  st_run --root "$root" --cwd "$proj" config list
  st_expect_reject "also rejects an out-of-range handover threshold in a file" 1 "between 0 and 100"

  rm -f "$project_config"
  st_run_with "REIN_THRESHOLD_NOTICE=abc" --root "$root" --cwd "$proj" config get threshold_notice
  st_expect_reject "rejects an invalid value from an environment variable" 1 "environment variable REIN_THRESHOLD_NOTICE"

  st_run --root "$root" --cwd "$proj" config unset snooze_max_sec
  st_expect_reject "rejects unset on a key that was never set" 1 "is not set"

  st_run --root "$root" --cwd "$proj" config
  st_expect_reject "rejects a missing config subcommand" 2 "get / set / unset / list"
  st_run --root "$root" --cwd "$proj" config bogus
  st_expect_reject "rejects an unknown config subcommand" 2 "unknown config subcommand"
  st_run --root "$root" --cwd "$proj" config set threshold_notice
  st_expect_reject "rejects a set with no value" 2 "a key and a value"
  st_run --root "$root" --cwd "$proj" config list extra
  st_expect_reject "rejects extra arguments to list" 2 "takes no arguments"

  # A common option's missing value gets a reason (a silent exit 2 would leave a typo
  # unnoticed).
  st_run --cwd
  st_expect_reject "explains --cwd's missing value" 2 "--cwd requires a value"
  st_run --root
  st_expect_reject "explains --root's missing value" 2 "--root requires a value"
  st_run --config
  st_expect_reject "explains --config's missing value" 2 "--config requires a value"
  # An explicitly empty value is rejected too (the same discipline as a verb's options).
  # Silently falling back to unspecified would run the **default lineage instead of the
  # intended target** when a script's value assembly failed, and it would proceed all the way
  # to up.
  st_run --cwd "" config list
  st_expect_reject "rejects an empty --cwd" 2 "--cwd cannot take an empty value"
  st_run --root "" --cwd "$proj" config list
  st_expect_reject "rejects an empty --root" 2 "--root cannot take an empty value"
  st_run --config "" --cwd "$proj" config list
  st_expect_reject "rejects an empty --config" 2 "--config cannot take an empty value"

  # A user config location that resolves to a relative path is fail-loud. Silently passing it
  # through as "no user config" would mean every reader sees a different cwd (the CLI is the
  # user's own shell, the watcher is wherever nohup was started, hooks are wherever the
  # launcher sits), so the files read within the same lineage wouldn't line up, and
  # `config set -u` would create a new file relative to wherever it was invoked from. Config
  # follows the same discipline the runtime-directory resolution already applies when it
  # restricts XDG to an absolute path.
  mkdir -p "$tmp/xdgproj"
  ST_OUT="$(env -u REIN_CONFIG_FILE "XDG_CONFIG_HOME=relative-config" \
    "$ST_BASH" "$REIN_BIN_PATH" --cwd "$tmp/xdgproj" config list 2>&1 </dev/null)"
  ST_STATUS=$?
  # The reason is named by the shared predicate (rein_xdg_base) -- "specified but unusable" is
  # different from having no material at all (which reads as "absent") -- so it **never
  # proceeds by guessing**.
  st_expect_reject "rejects a relative XDG_CONFIG_HOME" 1 "is not an absolute path"
  st_expect_contains "the rejection reason names where it came from" "XDG_CONFIG_HOME holds a relative path"
  st_expect_true "a relative XDG_CONFIG_HOME never creates a location" test ! -e "relative-config"
  # The accepting side's counterpart: an absolute path passes (even if that file doesn't exist yet).
  ST_OUT="$(env -u REIN_CONFIG_FILE "XDG_CONFIG_HOME=$tmp/xdg-abs" \
    "$ST_BASH" "$REIN_BIN_PATH" --cwd "$tmp/xdgproj" config list 2>&1 </dev/null)"
  ST_STATUS=$?
  st_expect_status "an absolute XDG_CONFIG_HOME passes" 0

  st_run --root "$root" --cwd "$tmp/absent" config list
  st_expect_reject "rejects a --cwd that doesn't exist" 2 "the target directory doesn't exist"

  st_run --root "$root" --cwd "$proj" bogus-sub
  st_expect_reject "rejects an unknown subcommand" 2 "unknown subcommand"
  st_run --root "$root" --cwd "$proj" status --bogus
  st_expect_reject "rejects an unknown argument to a verb" 2 "unknown argument to status"
  st_run --bogus-option
  st_expect_reject "rejects an unknown common option" 2 "unknown option"
  st_run --help
  if st_expect_status "--help exits 0" 0; then
    # Usage is checked by **shape**, not wording (what this guards is explained at the top of
    # st_help_layout).
    help_layout="$(printf '%s\n' "$ST_OUT" | st_help_layout "$SCRIPT_NAME")"
    help_layout_align="$(printf '%s\n' "$help_layout" | grep '^align ')"
    if [ -z "$help_layout_align" ]; then
      st_ok
    else
      st_fail "a section's description column starts at one position" "$help_layout_align"
    fi
    help_layout_desc="$(printf '%s\n' "$help_layout" | grep '^desc ')"
    if [ -z "$help_layout_desc" ]; then
      st_ok
    else
      st_fail "every listing line has a description" "$help_layout_desc"
    fi
    # Distinguish "the parse ran on nothing yet passed" (perl is absent, or the output shape
    # changed wholesale) from the 2 checks above.
    help_layout_count="$(printf '%s\n' "$help_layout" | sed -n 's/^count //p')"
    case "$help_layout_count" in
      "" | 0 | *[!0-9]*)
        st_fail "lines with a description were parsed" "count=[${help_layout_count}]"
        ;;
      *) st_ok ;;
    esac
  fi
  help_usage_out="$ST_OUT"
  # help finishes before resolving a location, so it still prints usage even given a --cwd that
  # doesn't exist (the same --cwd makes other verbs fail on the "rejects a --cwd that doesn't
  # exist" check above -- both sides are checked).
  st_run --cwd "$tmp/absent" help
  if st_expect_status "help exits 0" 0; then
    st_expect_out "help prints the same thing as --help" "$help_usage_out"
  fi
  st_run help status
  st_expect_reject "rejects extra arguments to help" 2 "takes no arguments"

  # The project settings' allow gate.
  #
  # `<cwd>/.rein/config` can be bundled inside a cloned repository -- **its mere presence never
  # makes it take effect**. The CLI's verbs reject an undecided setting with an explicit error
  # (the passive-context side -- hooks, statusLine -- has each script's own selftest measure
  # "proceeds without applying it" instead).
  allow_proj="$tmp/allow-proj"
  allow_config="$allow_proj/$REIN_RECORDS_DIRNAME/config"
  allow_ledger="$root/config/rein/$REIN_PROJECT_ALLOW_BASENAME"
  mkdir -p "$allow_proj/$REIN_RECORDS_DIRNAME"
  printf 'threshold_notice=11\n' >"$allow_config"
  # The **display name** filled into the instructions changes with what is on PATH (`rein` if
  # PATH's `rein` is this implementation, the real file path if not installed) -- so this is
  # measured with **PATH fixed to not-installed**. Without fixing it, an implementation that
  # writes a bare `rein` would print the same text on an installed machine and pass -- this
  # check would never measure the display name at all (observed: mutating it back to a bare
  # name still passed 297/0).
  # The installed side is measured by the paired check in doctor's own section
  # (st_section_doctor).
  st_config_saved_path="$PATH"
  PATH="$(st_path_without_rein)"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  if st_expect_reject "the CLI rejects an unallowed project setting" 1 "not allowed"; then
    # The decision instructions are measured **verbatim, in full**. Just checking that
    # `config allow` is present would let a line missing the lineage naming pass -- for a
    # lineage relocated to this root, typing exactly what's shown records the allow to
    # **the default lineage's ledger instead**, leaving this lineage rejected while showing
    # the same instructions forever (reproduced by observation). The deny side is measured the
    # same way, as one full line (abbreviating just one side to `config deny` would leave that
    # side with a bare instruction).
    st_expect_contains "both decision lines name the lineage explicitly" \
      "to review the content and allow it, run $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root") --cwd $(rein_shell_quote "$allow_proj") config allow; to decide against applying it, run $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root") --cwd $(rein_shell_quote "$allow_proj") config deny"
    st_expect_not_contains "never instructs a bare line with the lineage naming dropped" "$(rein_shell_quote "$REIN_BIN_PATH") --cwd"
    st_expect_contains "names the allow target explicitly" "$allow_config"
  fi
  PATH="$st_config_saved_path"
  # The allow verb **shows what it's about to allow before recording it**.
  st_run --root "$root" --cwd "$allow_proj" config allow
  if st_expect_status "the allow verb exits 0" 0; then
    st_expect_contains "prints the allow target" "$allow_config"
    st_expect_contains "prints what's being allowed" "threshold_notice=11"
  fi
  st_expect_true "the allow record isn't placed inside the project" \
    test ! -e "$allow_proj/$REIN_RECORDS_DIRNAME/$REIN_PROJECT_ALLOW_BASENAME"
  st_expect_true "the allow record lives next to the user config" test -f "$allow_ledger"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_out "an allowed project setting takes effect" "11"
  # Allowing the same content again passes silently, and doesn't grow the record either
  # (typing it again never grows the ledger).
  st_run --root "$root" --cwd "$allow_proj" config allow
  if st_expect_status "allowing the same content again also exits 0" 0; then
    st_expect_contains "says it's already allowed" "already allowed"
  fi
  st_expect_true "allowing the same content again doesn't add a line" \
    test "$(grep -c " ${allow_config}\$" "$allow_ledger")" = "1"
  # The allow decision is judged by **content** (going by path or mtime alone couldn't catch
  # the content at the same location being swapped out).
  printf 'threshold_notice=12\n' >"$allow_config"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_reject "reverts to unallowed once the content changes" 1 "the content changed"
  # rein's own rewrite through its own verb updates the allow record on the spot (never gets
  # stuck on its own rewrite).
  st_run --root "$root" --cwd "$allow_proj" config allow
  st_expect_status "allow before rewriting" 0 && st_ok
  st_run --root "$root" --cwd "$allow_proj" config set threshold_notice 13
  st_expect_status "set passes once already allowed" 0 && st_ok
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_out "a setting written by rein itself takes effect without a re-allow" "13"
  st_expect_true "rein's own rewrite still leaves exactly one record" \
    test "$(grep -c " ${allow_config}\$" "$allow_ledger")" = "1"
  # The rejecting side.
  st_run --root "$root" --cwd "$allow_proj" config allow extra
  st_expect_reject "rejects extra arguments to allow" 2 "takes no arguments"
  rm -f "$allow_config"
  st_run --root "$root" --cwd "$allow_proj" config allow
  st_expect_reject "rejects allow with nothing to allow" 1 "there are no project settings"
  # A cwd with no project settings can be read with no allow required (the gate only fires
  # when there's something present).
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_status "no allow is required when there are no project settings" 0 && st_ok

  # Deciding "don't apply this" (deny).
  #
  # A clone bundling an untrusted project setting shouldn't have "allow it" or "delete the file
  # git is tracking" as its only 2 ways out. Once decided, it **silently** proceeds without
  # the project layer.
  printf 'threshold_notice=17\n' >"$allow_config"
  st_run --root "$root" --cwd "$allow_proj" config deny
  if st_expect_status "can decide against applying it" 0; then
    st_expect_contains "prints the decision target" "$allow_config"
    st_expect_contains "prints what's being decided" "threshold_notice=17"
  fi
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  if st_expect_status "the CLI's verbs pass once decided" 0; then
    st_expect_not_contains "the project layer's value doesn't take effect" "17"
  fi
  st_expect_true "the decision stays one line" \
    test "$(grep -c " ${allow_config}\$" "$allow_ledger")" = "1"
  st_expect_true "the ledger holds the decision verbatim" \
    test -n "$(grep "^deny .* ${allow_config}\$" "$allow_ledger")"
  # A second time with the same content passes silently.
  st_run --root "$root" --cwd "$allow_proj" config deny
  if st_expect_status "denying the same content again also exits 0" 0; then
    st_expect_contains "says it's already decided" "already decided against applying"
  fi
  # A setting decided against applying is never even a target for a rewrite either (the
  # rewrite's own cleanup would override the decision, and every other line bundled in the
  # same file would take effect too).
  # This re-decide instruction also names the lineage, so it's measured with PATH fixed to
  # not-installed, the same as above.
  st_config_saved_path="$PATH"
  PATH="$(st_path_without_rein)"
  st_run --root "$root" --cwd "$allow_proj" config set threshold_notice 18
  if st_expect_reject "never rewrites a setting decided against applying" 1 "already decided against applying"; then
    st_expect_file "never changes the file of a denied setting" "$allow_config" "threshold_notice=17"
    # The re-decide instruction is also measured verbatim in full (this instruction moves the
    # same ledger, so dropping the naming would attach the allow to a different lineage).
    st_expect_contains "the re-decide instruction also names the lineage" \
      "to rewrite it, run $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root") --cwd $(rein_shell_quote "$allow_proj") config allow"
    st_expect_not_contains "the re-decide instruction is never a bare line either" "$(rein_shell_quote "$REIN_BIN_PATH") --cwd"
  fi
  PATH="$st_config_saved_path"
  # A decision is tied to content -- once the content changes after a deny, it reverts to
  # undecided (fail-loud).
  printf 'threshold_notice=19\n' >"$allow_config"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_reject "a deny also expires once the content changes" 1 "the content changed after it was denied"
  # The reverse (a denied setting can later be allowed -- a decision can be redone).
  st_run --root "$root" --cwd "$allow_proj" config allow
  st_expect_status "can allow after a deny" 0 && st_ok
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_out "re-allowing makes the project layer take effect" "19"
  # The rejecting side.
  st_run --root "$root" --cwd "$allow_proj" config deny extra
  st_expect_reject "rejects extra arguments to deny" 2 "takes no arguments"
  rm -f "$allow_config"
  st_run --root "$root" --cwd "$allow_proj" config deny
  st_expect_reject "rejects deny with nothing to decide" 1 "there are no project settings"

  # An allow confirms the content is valid before recording it.
  #
  # Closes off the shape "the allow succeeded, but the very next verb fails on an unknown key."
  # The deny side never confirms this -- using a clone with a broken config bundled in, without
  # applying it, is exactly what this verb is for.
  printf 'unknown_key=1\n' >"$allow_config"
  st_run --root "$root" --cwd "$allow_proj" config allow
  if st_expect_reject "never allows content that isn't valid" 1 "unknown key"; then
    st_expect_contains "says why it wasn't allowed" "not allowing this, since it is not valid as a setting"
  fi
  # Not being recorded is checked by **that content's digest** (the line itself is still there
  # from the earlier decision).
  st_expect_true "never records content that wasn't allowed" \
    test -z "$(grep " $(shasum -a 256 "$allow_config" | cut -d' ' -f1) " "$allow_ledger")"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_reject "stays not allowed" 1 "not allowed"
  # Even the same invalid content can still be denied (the validity check only runs on the
  # allow side).
  st_run --root "$root" --cwd "$allow_proj" config deny
  st_expect_status "can still deny broken content" 0 && st_ok
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_status "the verb passes once denied, even with broken content" 0 && st_ok
  # A value-type violation is never allowed either (this isn't just a known-key-presence
  # check).
  printf 'threshold_notice=200\n' >"$allow_config"
  st_run --root "$root" --cwd "$allow_proj" config allow
  st_expect_reject "never allows a value that violates its type" 1 "between 0 and 100"

  # Boundaries between lines in the decision ledger (a path with a newline, a malformed
  # line).
  # The ledger carries `<decision> <64-hex digest> <absolute path>` LF-delimited, one record
  # per line. **A macOS path can hold an LF**, so if a decision were recordable for a project
  # whose path holds one, one record would be read as 2 logical lines, injecting the literal
  # `allow <digest> <path>` for a different path into the ledger. The ledger is a record
  # that guards whether clone-bundled settings may take effect, so this is rejected at the
  # entry point.
  local lf_nl=$'\n' lf_cr=$'\r'
  local lf_proj lf_config cr_proj ledger_before ledger_backup broken_digest
  lf_proj="$tmp/lf${lf_nl}proj"
  lf_config="$lf_proj/$REIN_RECORDS_DIRNAME/config"
  mkdir -p "$lf_proj/$REIN_RECORDS_DIRNAME"
  printf 'threshold_notice=21\n' >"$lf_config"
  ledger_before="$(st_file_content "$allow_ledger")"
  st_run --root "$root" --cwd "$lf_proj" config allow
  st_expect_reject "can't decide for a target directory containing a newline" 1 "newline"
  st_expect_file "never writes a decision for a path with a newline to the ledger" "$allow_ledger" "$ledger_before"
  # That the injection never took hold is also checked by **the line's literal content**: no
  # line is readable as one record up to just before the newline.
  st_expect_true "no line is readable as one record up to just before the newline" \
    test -z "$(grep -n "${tmp}/lf\$" "$allow_ledger")"
  st_run --root "$root" --cwd "$lf_proj" config get threshold_notice
  st_expect_reject "loading also fails for a target directory containing a newline" 1 "newline"
  # A CR is the same (`read -r` splits on LF, but a CR trailing a line skews the literal
  # comparison).
  cr_proj="$tmp/cr${lf_cr}proj"
  mkdir -p "$cr_proj/$REIN_RECORDS_DIRNAME"
  printf 'threshold_notice=22\n' >"$cr_proj/$REIN_RECORDS_DIRNAME/config"
  st_run --root "$root" --cwd "$cr_proj" config allow
  st_expect_reject "can't decide for a target directory containing a CR" 1 "newline"
  st_expect_file "never writes a decision for a path with a CR to the ledger" "$allow_ledger" "$ledger_before"
  # The same applies to the user config's location (the ledger lives right next to it, so a
  # newline in that location moves the ledger's own location outside line boundaries too).
  # It's still an absolute path, so this shows it's rejected for a newline, not for the
  # absolute-path check.
  ST_OUT="$(env -u REIN_CONFIG_FILE "XDG_CONFIG_HOME=$tmp/xdg-lf${lf_nl}x" \
    "$ST_BASH" "$REIN_BIN_PATH" --cwd "$proj" config list 2>&1 </dev/null)"
  ST_STATUS=$?
  st_expect_reject "rejects an XDG_CONFIG_HOME containing a newline" 1 "newline"
  st_run --config "$tmp/cfg-lf${lf_nl}x" --cwd "$proj" config list
  st_expect_reject "rejects a --config containing a newline" 1 "newline"

  # A malformed line is **never silently skipped**. Skipping would let an injected line pass
  # through undistinguished from a legitimate one. A ledger holding even one unreadable
  # line reverts as a whole to undecided.
  printf 'threshold_notice=23\n' >"$allow_config"
  st_allow_project --root "$root" --cwd "$allow_proj"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_status "passes as already allowed before adding a broken line (control)" 0 && st_ok
  ledger_backup="$tmp/ledger.bak"
  cp "$allow_ledger" "$ledger_backup"
  broken_digest="0000000000000000000000000000000000000000000000000000000000000000"
  # The decision word is neither allow nor deny.
  printf 'bogus %s /nowhere/.rein/config\n' "$broken_digest" >>"$allow_ledger"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_reject "reverts to undecided on an unreadable decision word" 1 "unreadable line"
  # The writer doesn't add to a broken ledger either (doing so would repeat "allowed, but
  # still undecided" over and over).
  st_run --root "$root" --cwd "$allow_proj" config allow
  st_expect_reject "never adds a decision to a broken ledger" 1 "unreadable line"
  # The digest isn't 64 hex digits.
  cp "$ledger_backup" "$allow_ledger"
  printf 'allow not-a-digest /nowhere/.rein/config\n' >>"$allow_ledger"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_reject "reverts to undecided on an unreadable digest" 1 "unreadable line"
  # The path isn't absolute.
  cp "$ledger_backup" "$allow_ledger"
  printf 'allow %s relative/.rein/config\n' "$broken_digest" >>"$allow_ledger"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_reject "reverts to undecided on a relative-path line" 1 "unreadable line"
  # The accepting side's counterpart: restoring the ledger restores the prior allowed state (not
  # everything becomes undecided).
  cp "$ledger_backup" "$allow_ledger"
  st_run --root "$root" --cwd "$allow_proj" config get threshold_notice
  st_expect_status "restoring the ledger restores the allowed state" 0 && st_ok

  st_project_config_shape_cases
  st_allow_ledger_shape_cases
  st_allow_ledger_blank_line_cases
  st_allow_ledger_unreadable_cases
  st_ledger_lock_cases
  st_config_identity_cases
  st_config_control_char_display_cases
  st_lib_path_resolution_cases
  st_xdg_base_cases
  st_int_digit_bound_cases
  st_config_origin_path_cases
  st_target_cwd_resolution_cases
  st_snooze_duration_cases
  st_status_json_shape_cases
}

# Resolving the location of the bundled shared library.
#
# The config layer is read by a hook on every tool call, and that read happens before payload
# validation. Delegating location resolution to an external
# command (`dirname`) means that, wherever `dirname` returns empty (PATH has no /usr/bin, or
# a direnv / npm machine where the repo's bundled bin sits at the front of PATH),
# `cd "" && pwd` returns **the hook process's own cwd**, and rein-common.sh bundled there gets
# sourced and run (arbitrary code execution reproduced under an isolated environment).
# This checks that **the location resolves even with not one external command reachable via
# PATH** (checked by behavior rather than wording -- still fails even if rewritten to a
# different external command).
st_lib_path_resolution_cases() {
  local resolved relative
  # shellcheck disable=SC2016  # text meant to be expanded inside the child shell (expanding it here would defeat the point)
  resolved="$(env -i PATH= "$ST_BASH" -c \
    '. "$1" >/dev/null 2>&1 || exit 1; printf "%s" "$REIN_CONFIG_LIB_DIR"' \
    _ "$SCRIPTS_DIR/lib/rein-config.sh" 2>/dev/null)"
  st_expect_true "resolves the config layer's location even with an empty PATH" \
    test "$resolved" = "$SCRIPTS_DIR/lib"
  # A form sourced by relative path is **rejected right there, with no correction**.
  # Correcting it from the current directory would rebuild the very "reads a cwd-bundled
  # copy" shape closed off just above (the same discipline rein-common.sh follows).
  relative="$(cd "$SCRIPTS_DIR/lib" && "$ST_BASH" -c '. ./rein-config.sh' 2>&1)"
  case "$relative" in
    *"relative path"*) st_ok ;;
    *) st_fail "rejects the config layer right there when loaded by relative path" "$relative" ;;
  esac
}

# A machine where the foundation for a default location can't be assembled.
#
# Writing out `${XDG_CONFIG_HOME:-${HOME:-}/.config}` / `${HOME:-}/.claude/...` folds to
# `/.config` / `/.claude` on a machine where HOME is empty or unset (via launchd, an ssh session
# with a stripped environment, a hook process that inherits the environment), and since it
# starts with `/`, it slides right past the absolute-path check.
# **The read side and the write side point in opposite directions**, so both are measured:
#   read = proceeds as "there's no user config" (the hook's silent no-op path rides on this
#          judgment -- rejecting here would fire on every event even for a project that never
#          set up a lineage).
#   write = on that machine, **only the write side** fails, for the reason that the foundation
#           itself failed (never failing with the distant-cause reason "cannot create it"
#           after going to write under the folded root).
st_xdg_base_cases() {
  local xd_proj xd_home out rc
  xd_proj="$tmp/xdgless-proj"
  xd_home="$tmp/xdgless-home"
  mkdir -p "$xd_proj"
  out="$(env -i PATH=/usr/bin:/bin "$ST_BASH" "$REIN_BIN_PATH" \
    --cwd "$xd_proj" config get model 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    st_ok
  else
    st_fail "reading still proceeds even where the foundation can't be assembled" "rc=${rc}: ${out}"
  fi
  out="$(env -i PATH=/usr/bin:/bin "$ST_BASH" "$REIN_BIN_PATH" \
    --cwd "$xd_proj" config set --user model opus 2>&1)"
  rc=$?
  case "$out" in
    *"neither HOME nor XDG_CONFIG_HOME is set"*) st_ok ;;
    *) st_fail "writing where the foundation can't be assembled fails for the foundation's reason" "rc=${rc}: ${out}" ;;
  esac
  # The decision ledger (the other write path) fails for the same reason too.
  mkdir -p "$xd_proj/$REIN_RECORDS_DIRNAME"
  printf 'model=a\n' >"$xd_proj/$REIN_RECORDS_DIRNAME/config"
  out="$(env -i PATH=/usr/bin:/bin "$ST_BASH" "$REIN_BIN_PATH" \
    --cwd "$xd_proj" config allow 2>&1)"
  case "$out" in
    *"neither HOME nor XDG_CONFIG_HOME is set"*) st_ok ;;
    *) st_fail "where the foundation can't be assembled, the ledger isn't written to either" "$out" ;;
  esac
  rm -rf "${xd_proj:?}/${REIN_RECORDS_DIRNAME:?}"
  st_expect_true "never writes under the folded root" test ! -e /.config/rein

  # The usage record's default location follows the same rule (baking it into the table would
  # ship it folded to `/.claude/...`, failing not with "the location couldn't be decided" but
  # with "that location can't be read or written").
  out="$(env -i PATH=/usr/bin:/bin "$ST_BASH" "$REIN_BIN_PATH" \
    --cwd "$xd_proj" config get usage_state_dir 2>&1)"
  case "$out" in
    *"cannot build the usage record's default location"*) st_ok ;;
    *) st_fail "never hands out the usage record's default on a machine with no HOME" "$out" ;;
  esac
  st_expect_true "never hands out a folded default" \
    test "$out" != "/.claude/state/context-usage"
  # The accepting side's counterpart: with HOME present, the same default as before is handed out (the
  # default's destination hasn't changed).
  out="$(env -i PATH=/usr/bin:/bin HOME="$xd_home" "$ST_BASH" "$REIN_BIN_PATH" \
    --cwd "$xd_proj" config get usage_state_dir 2>&1)"
  st_expect_true "with HOME present, the usage record's default is as before" \
    test "$out" = "$xd_home/.claude/state/context-usage"
}

# The digit cap on values received as integers.
#
# The type check (rein_is_nonneg_int), which only looks at the literal, lets a digit string
# straight through to `[`'s integer comparison and to `$(( ))`. Past 64 bits, (1) `[` leaks an
# English diagnostic that isn't rein's own to standard error (hooks and statusLine put that
# standard error straight in front of the user), and (2) arithmetic wraps silently into
# behavior unrelated to the configured value (putting 19 digits into max_clock_skew_sec wraps
# `$((now + MAX_CLOCK_SKEW_SEC))` negative, and the watcher rejects every handover request).
# Checks **both the cap's value, and where the cap takes effect** (whether it's before the
# comparison that leaks an English diagnostic).
# The boundary is fixed as a literal (deriving it by formula from the cap constant would move
# the check right along with the constant, and the boundary itself would stop being guarded).
st_int_digit_bound_cases() {
  local err key rc
  err="$tmp/int-digits.err"
  st_expect_true "the integer digit cap is 10 digits" test "$REIN_CONFIG_INT_MAX_DIGITS" = "10"
  st_expect_true "exactly at the cap (10 digits) passes" \
    rein_config_validate_value max_clock_skew_sec 9999999999
  rein_config_validate_value max_clock_skew_sec 10000000000
  rc=$?
  if [ "$rc" -eq 1 ]; then
    st_ok
  else
    st_fail "rejects an integer one digit over the cap" "rc=${rc}"
  fi
  case "$REIN_CONFIG_ERROR" in
    *"too large"*) st_ok ;;
    *) st_fail "names the reason for a too-many-digits integer" "$REIN_CONFIG_ERROR" ;;
  esac
  # For every type, the digit check takes effect **before the comparison that leaks an English
  # diagnostic**. This also checks that standard error is empty -- even with the right reason
  # and exit code, a mixed-in shell diagnostic means it wasn't actually closed off.
  for key in threshold_notice cmd_timeout_sec max_clock_skew_sec; do
    : >"$err"
    { rein_config_validate_value "$key" 99999999999999999999; rc=$?; } 2>"$err"
    if [ "$rc" -eq 1 ] && [ ! -s "$err" ]; then
      st_ok
    else
      st_fail "no shell diagnostic leaks for a many-digit integer (${key})" \
        "rc=${rc}: $(st_file_content "$err")"
    fi
  done
  # The accepting side's counterpart: a normal value of the right type still passes through (not
  # everything gets rejected as "too large").
  st_expect_true "a normal percent value passes" rein_config_validate_value threshold_notice 30
  st_expect_true "an out-of-range percent is rejected for the range reason" \
    test "$(rein_config_validate_value threshold_notice 101 || printf '%s' "$REIN_CONFIG_ERROR")" \
    = "threshold_notice must be an integer between 0 and 100: 101"
  st_expect_true "a normal pos-int value passes" rein_config_validate_value cmd_timeout_sec 60
  # A value that isn't a digit string is out of scope for the digit check -- the reason comes
  # from the type check instead (never bucketed under "too large").
  rein_config_validate_value cmd_timeout_sec abcdefghijklmnopqrst
  case "$REIN_CONFIG_ERROR" in
    *"too large"*)
      st_fail "never rejects a non-digit-string value for the digit reason" "$REIN_CONFIG_ERROR"
      ;;
    *) st_ok ;;
  esac
}

# A round where the ledger itself can't be read.
#
# When an input redirect fails, bash skips the loop body and moves on, so a bare
# `done <"$file"` makes a ledger that couldn't be read look exactly like an **empty
# ledger**. Observed: with the ledger chmod'd to 000, `config allow` exited 0,
# announced "allowed," and replaced every other project's decisions with that one line
# (readers also reverted to "not yet allowed").
st_allow_ledger_unreadable_cases() {
  local un_root un_a un_b un_ledger before
  un_root="$tmp/ledger-unreadable-root"
  un_a="$tmp/ledger-unreadable-a"
  un_b="$tmp/ledger-unreadable-b"
  un_ledger="$un_root/config/rein/$REIN_PROJECT_ALLOW_BASENAME"
  mkdir -p "$un_a/$REIN_RECORDS_DIRNAME" "$un_b/$REIN_RECORDS_DIRNAME"
  printf 'threshold_notice=11\n' >"$un_a/$REIN_RECORDS_DIRNAME/config"
  printf 'threshold_notice=12\n' >"$un_b/$REIN_RECORDS_DIRNAME/config"
  st_allow_project --root "$un_root" --cwd "$un_a"
  before="$(st_file_content "$un_ledger")"

  chmod 000 "$un_ledger"
  # First confirm the unreadable state was actually created (if a machine can't create it, the
  # rest passing isn't an observation of "closed off" -- a round that couldn't be measured
  # isn't counted as a pass).
  if [ -r "$un_ledger" ]; then
    st_fail "can create a state where the ledger can't be read" "readable even with chmod 000 (running as root?)"
  else
    st_run --root "$un_root" --cwd "$un_b" config allow
    st_expect_reject "an unreadable ledger never turns a decision into a success" 1 "cannot read the decision ledger"
    st_run --root "$un_root" --cwd "$un_a" config get threshold_notice
    st_expect_reject "an unreadable ledger also tells the reader it can't judge" 1 "cannot read the decision ledger"
  fi
  chmod 600 "$un_ledger"
  st_expect_file "an unreadable round never replaces the ledger" "$un_ledger" "$before"

  # The accepting side's counterpart: once it's readable again, a decision can be made -- and
  # **another lineage's earlier decision survives too** (backing up the claim that the
  # write-back is built from the full read).
  st_run --root "$un_root" --cwd "$un_b" config allow
  st_expect_status "once readable again, a decision can be made" 0 && st_ok
  st_expect_true "another lineage's decision isn't dropped" \
    test -n "$(grep "^allow .* ${un_a}/${REIN_RECORDS_DIRNAME}/config\$" "$un_ledger")"
}

# Mutual exclusion for concurrent writes to the ledger.
#
# The ledger is one file next to the user config, holding decisions for every project that
# shares that user config -- so if another rein writes during the window "from read to mv"
# (the whole span the command runs), whichever side does the later `mv` overwrites the earlier
# decision. Before the fix, out of 25 simultaneous attempts, 7 lost a decision, and 16 had
# **a deny disappear while a stale allow survived** (a clone-bundled setting decided against
# stayed in effect as a layer -- the unsafe direction).
# Rather than the race itself, this measures **that mutual exclusion actually takes effect**,
# deterministically -- with the lock claimed ahead of time, it checks whether the writer
# silently overwrites, or fails with a reason (measuring against the race would come out
# intermittent).
st_ledger_lock_cases() {
  local lk_root lk_proj lk_config lk_ledger lk_lock before saved_user saved_wait rc
  lk_root="$tmp/ledger-lock-root"
  lk_proj="$tmp/ledger-lock-proj"
  lk_config="$lk_proj/$REIN_RECORDS_DIRNAME/config"
  lk_ledger="$lk_root/config/rein/$REIN_PROJECT_ALLOW_BASENAME"
  lk_lock="${lk_ledger}.lock"
  mkdir -p "$lk_proj/$REIN_RECORDS_DIRNAME"
  printf 'threshold_notice=13\n' >"$lk_config"
  st_allow_project --root "$lk_root" --cwd "$lk_proj"
  before="$(st_file_content "$lk_ledger")"

  # Place a lock with a live owner (declaring its own pid and start time -- the shared
  # library's "never seize" discipline means this is never a candidate for reclaiming).
  mkdir -p "$lk_lock"
  printf '%s\n' "$$" >"$lk_lock/pid"
  rein_process_start_identity "$$" >"$lk_lock/start"
  saved_user="$REIN_CONFIG_USER_FILE"
  saved_wait="$REIN_CONFIG_LEDGER_LOCK_WAIT_SEC"
  REIN_CONFIG_USER_FILE="$lk_root/config/rein/config"
  # Set the wait to 0 to fail deterministically (never wait 5 seconds in a check).
  REIN_CONFIG_LEDGER_LOCK_WAIT_SEC=0
  rein_config_allow_record "$lk_config"
  rc=$?
  REIN_CONFIG_USER_FILE="$saved_user"
  REIN_CONFIG_LEDGER_LOCK_WAIT_SEC="$saved_wait"
  if [ "$rc" -ne 0 ]; then
    st_ok
  else
    st_fail "never writes to the ledger during a round that can't get the lock" "the write reported success"
  fi
  case "$REIN_PROJECT_ALLOW_ERROR" in
    *"lock"*) st_ok ;;
    *) st_fail "names the reason it couldn't get the lock" "$REIN_PROJECT_ALLOW_ERROR" ;;
  esac
  st_expect_file "never replaces the ledger during a round that can't get the lock" "$lk_ledger" "$before"

  # The accepting side's counterpart: with no lock present, the same decision goes through, and
  # **never leaves the lock behind** (leaving it would permanently block the next decision).
  rm -rf "${lk_lock:?}"
  st_run --root "$lk_root" --cwd "$lk_proj" config deny
  st_expect_status "the decision passes once there's no lock" 0 && st_ok
  st_expect_true "never leaves the lock behind after a decision" test ! -e "$lk_lock"
}

# The origin of a round that failed the validity check.
#
# `config set` / `config unset` confirm validity before writing by placing a candidate in a
# temp file in the same directory and re-reading it with that layer's path swapped in. Leaving
# the swap in place while building the reason text would give an origin of
# `.../config.XXXXXX` -- **a nonexistent path that vanishes right after the check runs** --
# which the user can't even open ("when a value's layer is visible, name that layer in one
# line" in docs/spec/config.md would then be satisfied in form only).
st_config_origin_path_cases() {
  local og_root og_proj og_user og_project
  og_root="$tmp/origin-root"
  og_proj="$tmp/origin-proj"
  og_user="$og_root/config/rein/config"
  og_project="$og_proj/$REIN_RECORDS_DIRNAME/config"
  mkdir -p "$og_proj/$REIN_RECORDS_DIRNAME" "$og_root/config/rein"

  st_run --root "$og_root" --cwd "$og_proj" config set --user threshold_notice 90
  if st_expect_reject "rejects a set that breaks the combination (user)" 1 "threshold_handover"; then
    st_expect_contains "a failed round's origin is the real save target (user)" "from user:${og_user})"
    # The temp file's name is `<save target>.XXXXXX`, so a `.` right after the origin is the
    # tell for "it named the temp file."
    st_expect_not_contains "never names the temp file as the origin (user)" "from user:${og_user}."
  fi
  st_expect_true "a failed set never creates the save target" test ! -e "$og_user"

  st_run --root "$og_root" --cwd "$og_proj" config set --project threshold_notice 90
  if st_expect_reject "rejects a set that breaks the combination (project)" 1 "threshold_handover"; then
    st_expect_contains "a failed round's origin is the real save target (project)" "from project:${og_project})"
    st_expect_not_contains "never names the temp file as the origin (project)" "from project:${og_project}."
  fi

  # The accepting side's counterpart: a set that succeeds passes, and origins after that also name that
  # real path.
  st_run --root "$og_root" --cwd "$og_proj" config set --user threshold_notice 20
  st_expect_status "a set that succeeds passes" 0 && st_ok
  st_run --root "$og_root" --cwd "$og_proj" config list
  st_expect_contains "a written value's origin is also the real path" "threshold_notice=20	(user:${og_user})"
}

# Failure to resolve the target directory.
#
# With the shape `TARGET_CWD="$(cd ... )" || { ... }`, the assignment already completes as
# soon as the command substitution returns empty, so the `||` side reads `$TARGET_CWD` as
# empty -- the one-line reason never names a path. It also doesn't capture cd's own standard
# error, so bash's raw line (`bin/rein: line N: cd: ...: Permission denied`) mixes into
# user-facing output. **Both** are measured (measuring only one leaves the other regression
# invisible).
st_target_cwd_resolution_cases() {
  local blocked
  blocked="$tmp/cwd-blocked"
  mkdir -p "$blocked"
  chmod 000 "$blocked"
  if [ -x "$blocked" ]; then
    st_fail "can create a directory that can't be traversed" "traversable even with chmod 000 (running as root?)"
  else
    st_run --cwd "$blocked" status
    if st_expect_reject "rejects a target directory that can't be traversed" 2 "cannot resolve the target directory"; then
      st_expect_contains "the failure reason names the path" "cannot resolve the target directory: ${blocked}"
      st_expect_not_contains "never leaks the shell's raw error" ": cd: "
    fi
  fi
  chmod 700 "$blocked"
  # The accepting side's counterpart: a nonexistent directory keeps its own reason (never bucketed
  # under "resolution failed").
  st_run --cwd "$tmp/cwd-absent" status
  st_expect_reject "a nonexistent target directory says it doesn't exist" 2 "the target directory doesn't exist"
}

# The digit cap on a snooze duration.
#
# The duration-to-seconds conversion is `$((number * 3600))`, and without a digit guard, the
# value warps **before it ever reaches the upper-bound check (snooze_max_sec)**. Observed:
# `snooze 4611686018427387905m` (2^62+1 minutes) passed with rc=0, with no error and no
# warning, resulting in a 60-second snooze (60*(2^62+1) mod 2^64 = 60).
# Where this belongs: the per-verb section (`snooze`) is the natural home, but the section
# table (lib/cli/selftest/selftest.sh) is out of scope for this delegation, so a section can't
# be added there. It's placed here since it measures the same digit-cap policy
# (REIN_CONFIG_INT_MAX_DIGITS) as the config layer.
st_snooze_duration_cases() {
  local err out rc spec expect_rc raw
  err="$tmp/snooze-duration.err"
  # `<input> <expected rc> <expected seconds>` (when rc isn't 0, seconds is `-`).
  while read -r raw expect_rc out; do
    [ -n "$raw" ] || continue
    : >"$err"
    spec="$(snooze_parse_duration "$raw" 2>"$err")"
    rc=$?
    if [ "$rc" -ne "$expect_rc" ]; then
      st_fail "parsing the duration (${raw})" "rc=${rc} (expected ${expect_rc})"
      continue
    fi
    if [ -s "$err" ]; then
      st_fail "no shell diagnostic leaks while parsing the duration (${raw})" "$(st_file_content "$err")"
      continue
    fi
    if [ "$out" != "-" ] && [ "$spec" != "$out" ]; then
      st_fail "converting the duration to seconds (${raw})" "${spec} (expected ${out})"
      continue
    fi
    st_ok
  done <<'EOF'
30m 0 1800
2h 0 7200
45 0 45
3600s 0 3600
9999999999m 0 599999999940
10000000000m 2 -
4611686018427387905m 2 -
9999999999999999h 2 -
99999999999999999999s 2 -
5123372036854775807 2 -
0 1 -
5x 1 -
EOF
}

# Machine-readable output that doesn't go silent on a broken record.
#
# `jq -c .` prints 2 lines when a file holds 2 JSON values. Those 2 lines slip past the
# emptiness check and only fail the final assembly with `jq: invalid JSON text passed to
# --argjson` -- so **exactly on the round where diagnosing a broken record matters**, stdout
# comes back empty with rc=2 (the same code as an argument error).
# Where this belongs: the per-verb section (`status`) is the natural home, but the section
# table is out of scope, so it's placed here.
st_status_json_shape_cases() {
  local two saved
  saved="$STATUS_UNREADABLE_JSON"
  STATUS_UNREADABLE_JSON="[]"
  status_take_json_text pointer /nowhere/current.json '{"a":1}' unreadable
  st_expect_true "a single JSON value passes through as-is" test "$STATUS_JSON_VALUE" = '{"a":1}'
  st_expect_true "an unbroken round leaves the named list empty" test "$STATUS_UNREADABLE_JSON" = "[]"

  # **The most ordinary way a record breaks**: `jq` prints nothing at all when it gives up on its
  # input, so a half-written record arrives here as an empty string -- the same empty string a
  # file that was never there produces. Folding both into a silent null answered "there is no
  # stop request" for a stop request sitting right there unreadable, and only in the one form a
  # script reads (the human-readable view calls that same file present).
  STATUS_UNREADABLE_JSON="[]"
  status_take_json_text stop_request /nowhere/stop.json '' unreadable
  st_expect_true "a record that could not be read becomes null" test "$STATUS_JSON_VALUE" = "null"
  st_expect_true "a record that could not be read is named, not passed over silently" \
    test "$(printf '%s' "$STATUS_UNREADABLE_JSON" | jq -r '.[0].field')" = "stop_request"
  st_expect_true "the unreadable record's file is named too" \
    test "$(printf '%s' "$STATUS_UNREADABLE_JSON" | jq -r '.[0].path')" = "/nowhere/stop.json"

  # The other side of the same decision: for a log's last event, empty means "nothing recorded
  # yet" -- a lineage that has not handed over, a seat not yet sat in -- and naming it would put
  # a permanent entry in the list for a lineage with nothing wrong with it.
  STATUS_UNREADABLE_JSON="[]"
  status_take_json_text last_event /nowhere/handovers.jsonl '' absent
  st_expect_true "nothing recorded yet becomes null" test "$STATUS_JSON_VALUE" = "null"
  st_expect_true "nothing recorded yet names nothing" test "$STATUS_UNREADABLE_JSON" = "[]"

  # A call site added without deciding which of the two it is doesn't get a meaning picked for it.
  STATUS_UNREADABLE_JSON="[]"
  status_take_json_text pointer /nowhere/current.json '' whatever
  st_expect_true "an undeclared empty-read meaning is null" test "$STATUS_JSON_VALUE" = "null"
  st_expect_true "an undeclared empty-read meaning is named rather than resolved" \
    test "$(printf '%s' "$STATUS_UNREADABLE_JSON" | jq -r '.[0].field')" = "pointer"

  STATUS_UNREADABLE_JSON="[]"
  two='{"a":1}'$'\n''{"b":2}'
  status_take_json_text pointer /nowhere/current.json "$two" unreadable
  st_expect_true "2 JSON values in one file fall back to null" test "$STATUS_JSON_VALUE" = "null"
  st_expect_true "a fallback round names the field" \
    test "$(printf '%s' "$STATUS_UNREADABLE_JSON" | jq -r '.[0].field')" = "pointer"
  st_expect_true "a fallback round names the file" \
    test "$(printf '%s' "$STATUS_UNREADABLE_JSON" | jq -r '.[0].path')" = "/nowhere/current.json"
  STATUS_UNREADABLE_JSON="$saved"
}

# When the ledger's unreadable line is a **blank line**, say so in a way that makes that
# clear. The instructions say "delete the whole ledger and decide again," and a user following
# that -- **emptying the content** in an editor -- can be left with a trailing newline,
# producing a 1-byte ledger. Looking empty while being told "line 1 is unreadable" leaves
# no way out but to repeat the same action (a 0-byte ledger can be re-decided normally).
st_allow_ledger_blank_line_cases() {
  local blank_proj blank_root blank_config blank_ledger blank_digest
  blank_proj="$tmp/blank-ledger-proj"
  blank_root="$tmp/blank-ledger-root"
  blank_config="$blank_proj/$REIN_RECORDS_DIRNAME/config"
  blank_ledger="$blank_root/config/rein/$REIN_PROJECT_ALLOW_BASENAME"
  blank_digest="0000000000000000000000000000000000000000000000000000000000000000"
  mkdir -p "$blank_proj/$REIN_RECORDS_DIRNAME" "$blank_root/config/rein"
  printf 'threshold_notice=18\n' >"$blank_config"

  # The accepting side's counterpart: a 0-byte ledger can be re-decided (not everything reverts to
  # undecided).
  : >"$blank_ledger"
  st_run --root "$blank_root" --cwd "$blank_proj" config allow
  st_expect_status "a 0-byte ledger can be re-decided" 0 && st_ok

  # The rejecting side: a ledger holding just one newline is a blank first line. **Named
  # explicitly as a blank line.**
  printf '\n' >"$blank_ledger"
  st_run --root "$blank_root" --cwd "$blank_proj" config allow
  st_expect_reject "names a ledger holding just a newline as a blank line" 1 "has a blank line"
  st_run --root "$blank_root" --cwd "$blank_proj" config get threshold_notice
  st_expect_reject "the reader also names it a blank line" 1 "has a blank line"

  # This naming never becomes "call everything a blank line" (an unreadable line that isn't
  # blank is still called that as before).
  printf 'bogus %s /nowhere/.rein/config\n' "$blank_digest" >"$blank_ledger"
  st_run --root "$blank_root" --cwd "$blank_proj" config get threshold_notice
  if st_expect_reject "a non-blank unreadable line is still called an unreadable line" 1 "unreadable line"; then
    st_expect_not_contains "never calls a non-blank line a blank line" "has a blank line"
  fi
}

# Content identity under a replacement in progress.
#
# A replacement at `<cwd>/.rein/config` happens through a rename (an editor's save, `git
# checkout`). Unless the allow judgment (the content digest), what's shown on screen, the
# validity check, and the summary recorded to the ledger all see the **exact same bytes**,
# (1) content that was never once allowed gets applied as the project layer, and (2)
# `config allow` records, as what was allowed, content different from what it just showed on
# screen. Both happen through a blind replacement loop that observes nothing about rein's
# own runs, and **need no attacker timing them deliberately**.
#
# **Only probabilistic, so this is judged by counts over a number of trials** (one pass proves
# nothing). The loss direction is one-sided: for applying, the only loss is "content that was
# never allowed took effect" -- reverting to undecided is the safe side. For deciding, the
# only loss is the direction where **content that was never shown** ends up as what got
# recorded (the reverse direction reverts to undecided on the next read anyway). A check that
# rejects both directions equally would end up rejecting the safe-side behavior too.
#
# Also checks that the replacement kept running for the whole measurement window -- if the
# replacement stalled, this check would pass having measured nothing (the counterpart to never
# taking a 0 count as proof "it doesn't happen").
st_config_identity_cases() {
  local id_proj id_root id_config id_ledger id_flip id_stop id_pid
  local id_digest_a id_digest_b id_trials id_i id_record id_shown id_recorded
  local id_applied_a=0 id_applied_b=0 id_undecided=0 id_apply_other=0 id_apply_last=""
  local id_aa=0 id_bb=0 id_safe=0 id_loss=0 id_record_other=0 id_record_last=""

  id_proj="$tmp/identity-proj"
  id_root="$tmp/identity-root"
  id_config="$id_proj/$REIN_RECORDS_DIRNAME/config"
  id_ledger="$id_root/config/rein/$REIN_PROJECT_ALLOW_BASENAME"
  id_flip="$tmp/identity-flip.sh"
  id_stop="$tmp/identity-stop"
  mkdir -p "$id_proj/$REIN_RECORDS_DIRNAME" "$id_root/config/rein"
  # A = the allowed content / B = content never allowed. **Both are values valid on their
  # own** (an invalid value would mix "rejected by the validity check" together with
  # "rejected as unallowed," muddling which direction was measured).
  printf 'threshold_notice=25\n' >"$tmp/identity-a"
  printf 'threshold_notice=39\n' >"$tmp/identity-b"
  id_digest_a="$(shasum -a 256 "$tmp/identity-a")"
  id_digest_a="${id_digest_a%% *}"
  id_digest_b="$(shasum -a 256 "$tmp/identity-b")"
  id_digest_b="${id_digest_b%% *}"
  cp "$tmp/identity-a" "$id_config"
  st_allow_project --root "$id_root" --cwd "$id_proj"

  # A blind replacement (writing into the same directory then renaming -- the same shape as an
  # editor's save or `git checkout`). Observes nothing of rein's own run. Also caps the
  # duration -- so it doesn't keep spinning past a round that never got the stop signal.
  rm -f "$id_stop"
  cat >"$id_flip" <<FLIP
while [ ! -e "$id_stop" ] && [ "\$SECONDS" -lt 300 ]; do
  printf 'threshold_notice=25\n' >"${id_config}.new" && mv "${id_config}.new" "$id_config"
  printf 'threshold_notice=39\n' >"${id_config}.new" && mv "${id_config}.new" "$id_config"
done
FLIP
  "$ST_BASH" "$id_flip" &
  id_pid=$!

  # (1) An application split. That a value other than allowed A never takes effect as the
  # project layer.
  id_trials=120
  id_i=0
  while [ "$id_i" -lt "$id_trials" ]; do
    id_i=$((id_i + 1))
    st_run --root "$id_root" --cwd "$id_proj" config get threshold_notice
    if [ "$ST_STATUS" -eq 0 ] && [ "$ST_OUT" = "25" ]; then
      id_applied_a=$((id_applied_a + 1))
    elif [ "$ST_STATUS" -eq 0 ] && [ "$ST_OUT" = "39" ]; then
      id_applied_b=$((id_applied_b + 1))
    else
      case "$ST_OUT" in
        *"not allowed"*) id_undecided=$((id_undecided + 1)) ;;
        *)
          id_apply_other=$((id_apply_other + 1))
          id_apply_last="exit=${ST_STATUS}: ${ST_OUT}"
          ;;
      esac
    fi
  done
  if [ "$id_applied_b" -eq 0 ]; then
    st_ok
  else
    st_fail "content that was never allowed still doesn't apply under a replacement in progress" \
      "${id_applied_b} of ${id_trials} rounds had unallowed content take effect as the project layer (allowed content ${id_applied_a} times / undecided ${id_undecided} times)"
  fi
  st_expect_true "the replacement kept running for the whole application measurement" test "$id_undecided" -gt 0
  if [ "$id_apply_other" -eq 0 ]; then
    st_ok
  else
    st_fail "no unexplained result mixes into the application measurement" "$id_apply_last"
  fi

  # (2) A display/record split. Deletes the ledger and re-decides every round, then
  # cross-checks what was shown on screen against the summary recorded (`config allow` doesn't
  # wait for confirmation input, so the window is part of the command's own run time).
  id_trials=50
  id_i=0
  while [ "$id_i" -lt "$id_trials" ]; do
    id_i=$((id_i + 1))
    rm -f "$id_ledger"
    st_run --root "$id_root" --cwd "$id_proj" config allow
    id_record="$(st_file_content "$id_ledger")"
    id_shown=""
    case "$ST_OUT" in *"  threshold_notice=25"*) id_shown="A" ;; esac
    case "$ST_OUT" in *"  threshold_notice=39"*) id_shown="${id_shown}B" ;; esac
    id_recorded=""
    case "$id_record" in *"$id_digest_a"*) id_recorded="A" ;; esac
    case "$id_record" in *"$id_digest_b"*) id_recorded="${id_recorded}B" ;; esac
    case "${ST_STATUS}/${id_shown}/${id_recorded}" in
      0/A/A) id_aa=$((id_aa + 1)) ;;
      0/B/B) id_bb=$((id_bb + 1)) ;;
      0/B/A) id_safe=$((id_safe + 1)) ;;
      0/A/B) id_loss=$((id_loss + 1)) ;;
      *)
        id_record_other=$((id_record_other + 1))
        id_record_last="exit=${ST_STATUS} shown=[${id_shown}] recorded=[${id_recorded}]"
        ;;
    esac
  done
  if [ "$id_loss" -eq 0 ]; then
    st_ok
  else
    st_fail "a decision records only a summary of the content shown on screen" \
      "${id_loss} of ${id_trials} rounds recorded, as the allow, a summary of content that was never shown (matched ${id_aa}+${id_bb} times / safe-side split ${id_safe} times)"
  fi
  st_expect_true "the replacement kept running for the whole decision measurement (saw A)" test "$id_aa" -gt 0
  st_expect_true "the replacement kept running for the whole decision measurement (saw B)" test "$id_bb" -gt 0
  if [ "$id_record_other" -eq 0 ]; then
    st_ok
  else
    st_fail "no unexplained result mixes into the decision measurement" "$id_record_last"
  fi

  : >"$id_stop"
  wait "$id_pid"
  rm -f "${id_config}.new"
}

# The decision display never passes control characters through unfiltered.
#
# `.rein/config` can be bundled inside a clone, so it isn't necessarily the user's own writing
# -- the `config allow` gate is the only defense there is. That gate's consent rests entirely
# on "show the target's content on screen, then record it," so planting ESC cursor-move and
# erase sequences in a value or a comment line can **erase the just-printed `settings=` line
# from the screen** and still get the user to type an allow (`settings` can hold the
# successor's launch settings -- hooks -- so this reaches arbitrary command execution).
# **A type check on the value can't close this off** -- `settings` is of type string, and that
# type unconditionally passes anything but a newline. Only the **screen copy** is visualized --
# what the validity check reads and what gets recorded to the ledger both stay the raw bytes
# (never breaking the discipline the "content identity under a replacement" check above
# protects).
st_config_control_char_display_cases() {
  local ctrl_proj ctrl_root ctrl_config ctrl_ledger ctrl_digest
  local link_proj link_config link_target
  local bulk_proj bulk_config bulk_line bulk_digest bulk_long
  ctrl_proj="$tmp/ctrl-proj"
  ctrl_root="$tmp/ctrl-root"
  ctrl_config="$ctrl_proj/$REIN_RECORDS_DIRNAME/config"
  ctrl_ledger="$ctrl_root/config/rein/$REIN_PROJECT_ALLOW_BASENAME"
  mkdir -p "$ctrl_proj/$REIN_RECORDS_DIRNAME" "$ctrl_root/config/rein"
  # Plants it in both a value and a comment line. A CR gets rejected as a format violation in
  # a value, but a comment line never goes through the format check, so returning to the start
  # of the line and overwriting can be built there (so the reject side can't live in the type
  # check).
  # DEL (0x7F) is the literal byte that "erases the character right before it" -- exactly the
  # heart of the threat this fix targets -- so this also drives the branch that prints the
  # alternate notation (`^?`) (ESC and CR alone never trigger the 0x7F branch even once).
  {
    printf '#\033[2A\033[0J a comment that rewinds the screen\r\n'
    printf 'settings={"env":{"A":"1"}}\033[2A\033[0J\177\n'
    printf 'threshold_notice=25\n'
  } >"$ctrl_config"
  ctrl_digest="$(shasum -a 256 "$ctrl_config")"
  ctrl_digest="${ctrl_digest%% *}"

  st_run --root "$ctrl_root" --cwd "$ctrl_proj" config allow
  if st_expect_status "project settings containing control characters can still be decided" 0; then
    st_expect_not_contains "never leaves a raw ESC in the display" $'\033'
    st_expect_not_contains "never leaves a raw CR in the display" $'\r'
    st_expect_not_contains "never leaves a raw DEL in the display" $'\177'
    # Also checks it was **replaced**, not just removed (an implementation that strips it
    # would still pass the 2 checks above).
    st_expect_contains "shows ESC as ^[ notation" '^['
    st_expect_contains "shows CR as ^M notation" '^M'
    st_expect_contains "shows DEL as ^? notation" '^?'
    st_expect_contains "never stays quiet about a substitution" "this contained control characters"
  fi
  # The record target stays the raw bytes -- the ledger's summary matches summarizing that
  # file as-is.
  st_expect_true "the summary recorded to the ledger is of the raw content" \
    test "$(st_file_content "$ctrl_ledger")" = "allow ${ctrl_digest} ${ctrl_config}"
  # The judged target hasn't changed either -- the allowed content takes effect as-is.
  st_run --root "$ctrl_root" --cwd "$ctrl_proj" config get threshold_notice
  st_expect_out "the allowed content still takes effect even after being made visible" "25"

  # The accepting side's counterpart: content with no control characters isn't changed by a single
  # character, and doesn't print the notice line either (printing it for everything would
  # stop its presence from signaling "this setting isn't ordinary").
  printf 'threshold_notice=26\n' >"$ctrl_config"
  st_run --root "$ctrl_root" --cwd "$ctrl_proj" config allow
  if st_expect_status "content with no control characters can still be decided" 0; then
    st_expect_contains "prints the content as-is" "  threshold_notice=26"
    st_expect_not_contains "no control characters means no notice" "this contained control characters"
  fi

  # **TAB (0x09) is deliberately excluded from the substitution set** -- this one case pins
  # that choice. TAB has no "erase what was already printed, rewind the screen" power (it only
  # advances the column), and `cat -v` passes it through unfiltered too. Including it would
  # make the notice fire even for a harmless setting merely formatted with TABs, and **the
  # notice's presence would stop being a signal**. A mutation that adds TAB back to the set is
  # caught here by seeing `^I`.
  printf 'settings={"env":\t{"A":"1"}}\n' >"$ctrl_config"
  st_run --root "$ctrl_root" --cwd "$ctrl_proj" config allow
  if st_expect_status "content containing TAB can still be decided" 0; then
    st_expect_contains "prints TAB as-is" $'{"env":\t{"A":"1"}}'
    st_expect_not_contains "never substitutes TAB with ^I" '^I'
    st_expect_not_contains "TAB alone never triggers the notice" "this contained control characters"
  fi

  # A path line that appears **before** the content lines is also visibility-substituted.
  # `resolves to:` prints a symlink's target, and whoever bundled it gets to choose that
  # file's name -- passing it through unfiltered would erase from the screen every line printed
  # after it: the content lines, the notice line, the completion line (`\033[8m` makes
  # everything after it invisible).
  link_proj="$tmp/ctrl-link-proj"
  link_target="$link_proj/$(printf 'evil\033[8m.conf')"
  link_config="$link_proj/$REIN_RECORDS_DIRNAME/config"
  mkdir -p "$link_proj/$REIN_RECORDS_DIRNAME"
  printf 'threshold_notice=27\n' >"$link_target"
  ln -s "$link_target" "$link_config"
  st_run --root "$ctrl_root" --cwd "$link_proj" config allow
  if st_expect_status "even with control characters in the target's name, it can still be decided" 0; then
    st_expect_not_contains "never leaves a raw ESC in the resolves-to line either" $'\033'
    st_expect_contains "the resolves-to line is also shown in ^[ notation" 'resolves to: '
    st_expect_contains "prints the resolved name substituted" 'evil^[[8m.conf'
    st_expect_contains "never stays quiet about the path substitution either" "this contained control characters"
  fi

  # The rejecting side is checked the same way. `allow` runs the validity check after showing
  # the content, and when content is invalid, **the key or value literally** lands in the
  # reason text printed to the terminal -- if that path isn't filtered, the same spoof
  # passes through this one line even with content visualization in place.
  printf 'threshold_notice=25\nbogus\033[2J=1\n' >"$ctrl_config"
  st_run --root "$ctrl_root" --cwd "$ctrl_proj" config allow
  if st_expect_status "invalid content isn't allowed" 1; then
    st_expect_not_contains "never leaves a raw ESC in the rejecting side's reason text either" $'\033'
    st_expect_contains "the config key inside the reason text is also shown in ^[ notation" 'bogus^[[2J'
  fi

  # The cap on how much the consent screen shows.
  #
  # Even without a single control character, bundling thousands of lines of comments can push
  # the `settings=` line up above the scrollback -- **the same result as erasing a line from
  # the display**. Neither the visualization nor the notice above reacts to that, so this caps
  # both the line count and the length of a single line, and loudly announces the cutoff.
  # **The cap itself is pinned as a literal** (deriving the fixture's size from the
  # implementation's constant would move the fixture right along with a mutation to the
  # constant -- any value would pass green). The value's rationale is written next to the
  # constant in scripts/lib/rein-config.sh.
  st_expect_true "the line cap is 100 lines" test "$REIN_CONFIG_PRINT_MAX_LINES" -eq 100
  st_expect_true "the per-line length cap is 500 characters" test "$REIN_CONFIG_PRINT_MAX_COLS" -eq 500
  bulk_proj="$tmp/ctrl-bulk-proj"
  bulk_config="$bulk_proj/$REIN_RECORDS_DIRNAME/config"
  mkdir -p "$bulk_proj/$REIN_RECORDS_DIRNAME"
  bulk_line=0
  : >"$bulk_config"
  while [ "$bulk_line" -lt 100 ]; do
    printf '# padding %s\n' "$bulk_line" >>"$bulk_config"
    bulk_line=$((bulk_line + 1))
  done
  # Plants both a line pushed past the cap and a line longer than the cap at the same time
  # (neither happens within the cap alone). The long line goes into `settings`'s value -- a
  # string type unconditionally passes anything but a newline.
  bulk_long="$(printf '%*s' 550 '')"
  bulk_long="${bulk_long// /x}"
  printf 'settings=%s\n' "$bulk_long" >>"$bulk_config"
  bulk_digest="$(shasum -a 256 "$bulk_config")"
  bulk_digest="${bulk_digest%% *}"
  st_run --root "$ctrl_root" --cwd "$bulk_proj" config allow
  if st_expect_status "content over the cap can still be decided" 0; then
    st_expect_contains "says how many of how many lines it printed" "the content has 101 lines, so only the first 100 are shown"
    st_expect_not_contains "a line past the cap never gets printed" "settings="
  fi
  # The record target isn't truncated -- the ledger's summary matches summarizing that
  # whole file (the ledger holds the lines from every case up to here, so this is checked
  # by that one line being present).
  st_expect_true "the summary recorded even after truncating is of the whole thing" \
    grep -qxF "allow ${bulk_digest} ${bulk_config}" "$ctrl_ledger"

  # The length cap takes effect independently of the line cap (an implementation that only
  # trims the line count would let a shape packed onto one line straight through unfiltered).
  printf 'settings=%s\n' "$bulk_long" >"$bulk_config"
  st_run --root "$ctrl_root" --cwd "$bulk_proj" config allow
  if st_expect_status "content containing a too-long single line can still be decided" 0; then
    st_expect_contains "never stays quiet about clipping it" "were too long and got cut off partway"
    st_expect_contains "leaves a mark at the clip point" "$REIN_CONFIG_PRINT_CLIP_MARK"
    # Also checks it's **actually shorter**, not just announced (an implementation that only
    # adds the notice while still printing the whole thing would still pass the 2 checks
    # above).
    st_expect_not_contains "never prints a length over the cap as-is" "${bulk_long:0:501}"
    st_expect_contains "still prints up to inside the cap" "${bulk_long:0:480}"
  fi

  # The accepting side's counterpart: content inside the cap loses not one line, and prints no
  # truncation notice either. Measured at exactly the cap's line count (a `-gt` mutated to
  # `-ge` would silently drop the one boundary line).
  bulk_line=0
  : >"$bulk_config"
  while [ "$bulk_line" -lt 99 ]; do
    printf '# padding %s\n' "$bulk_line" >>"$bulk_config"
    bulk_line=$((bulk_line + 1))
  done
  printf 'threshold_notice=28\n' >>"$bulk_config"
  st_run --root "$ctrl_root" --cwd "$bulk_proj" config allow
  if st_expect_status "content exactly at the cap can still be decided" 0; then
    st_expect_contains "at exactly the cap, prints through to the last line" "  threshold_notice=28"
    st_expect_not_contains "no line-count notice within the cap" ", so only the first"
    st_expect_not_contains "no length notice within the cap" "cut off partway"
  fi
}

# The shape of the project settings location. **"Absent" and "a broken symlink" are
# different** -- absent is a genuinely normal state (no project settings placed), but a broken
# symlink means "there's no content to decide on" -- treating them as the same branch would
# let a `config set` writer create a real file at the symlink's target (which can be outside
# the project) without ever going through consent even once. **The symlink itself stays
# supported** (a symlink whose target exists still requires consent as before, and takes
# effect once allowed).
st_project_config_shape_cases() {
  local proj outside link before
  proj="$tmp/cfg-link-proj"
  outside="$tmp/cfg-link-outside"
  link="$proj/$REIN_RECORDS_DIRNAME/config"
  mkdir -p "$proj/$REIN_RECORDS_DIRNAME" "$outside"
  printf 'sentinel\n' >"$outside/SENTINEL"
  before="$(find "$outside" | LC_ALL=C sort)"
  ln -s "$outside/config" "$link"

  st_run --root "$root" --cwd "$proj" config set threshold_notice 25
  st_expect_reject "never writes to a broken-symlink project setting" 1 "symbolic link"
  st_expect_true "never creates the broken symlink's target" \
    test "$(find "$outside" | LC_ALL=C sort)" = "$before"
  st_expect_true "leaves the broken symlink as it is" test -L "$link"
  st_run --root "$root" --cwd "$proj" config get threshold_notice
  st_expect_reject "a broken symlink isn't read by the reader as \"no setting\" either" 1 "symbolic link"

  # Non-regression: a symlink whose target exists. Stays blocked until allowed, takes effect
  # once allowed, and a write goes to the real file.
  printf 'threshold_notice=14\n' >"$outside/config"
  st_run --root "$root" --cwd "$proj" config get threshold_notice
  st_expect_reject "a symlink with a real target stays blocked as unallowed, as before" 1 "not allowed"
  st_run --root "$root" --cwd "$proj" config allow
  if st_expect_status "can allow a symlink with a real target" 0; then
    st_expect_contains "the allow display shows the resolved target" "$outside/config"
  fi
  st_run --root "$root" --cwd "$proj" config get threshold_notice
  st_expect_out "an allowed symlinked project setting takes effect" "14"
  st_run --root "$root" --cwd "$proj" config set threshold_notice 15
  st_expect_status "a symlinked project setting is written through to the real file" 0 && st_ok
  st_expect_file "the write target is the symlink's real file" "$outside/config" "threshold_notice=15"
  st_expect_true "never replaces the symlink with a regular file" test -L "$link"
}

# The shape of the decision ledger's location. The ledger isn't JSON (it's the
# `allow <digest> <path>` line format), so it doesn't go through the atomic-write primitive --
# it does its own tmp-then-`mv` swap, and if the destination is a directory, `mv` moves it
# inside and returns 0, so it would say "allowed" while not one decision actually gets saved.
st_allow_ledger_shape_cases() {
  local proj ledger_root ledger
  proj="$tmp/ledger-shape-proj"
  ledger_root="$tmp/ledger-shape-root"
  ledger="$ledger_root/config/rein/$REIN_PROJECT_ALLOW_BASENAME"
  mkdir -p "$proj/$REIN_RECORDS_DIRNAME" "$ledger"
  printf 'threshold_notice=16\n' >"$proj/$REIN_RECORDS_DIRNAME/config"
  st_run --root "$ledger_root" --cwd "$proj" config allow
  st_expect_reject "never turns an allow into a success when the ledger's location is a directory" 1 "is not a regular file"
  st_expect_not_contains "never says an unrecorded allow was allowed" "now allowed"
  st_expect_true "never writes inside the ledger's location" \
    test -z "$(find "$ledger" -mindepth 1 -print)"
}
