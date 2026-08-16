# shellcheck shell=bash
# Implementation of `rein snooze` (postponing forced handover).
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# Turns the duration literal into seconds. No unit means seconds; also accepts `s` / `m` / `h`.
# Never silently falls back to a default (an unreadable literal is rejected outright).
# **The digit-count check comes before the multiplication.** `$((number * 3600))` wraps around
# 64-bit, so putting the check after it would apply the cap (snooze_max_sec) to a value that has
# already wrapped -- observed: `snooze 4611686018427387905m` (2^62+1 minutes) passed with rc=0,
# and **a 60-second postponement went through with no error or warning at all**
# (60*(2^62+1) mod 2^64 = 60). The digit-count check runs before `rein_is_pos_int` because that
# function's `[ "$1" -gt 0 ]` leaks an English shell diagnostic to stderr for a numeral longer
# than 64 bits.
# The digit cap uses the same single source as the config layer (REIN_CONFIG_INT_MAX_DIGITS) --
# the policy for "how large a value counts as an integer" isn't kept in two places.
# 0=read (seconds to stdout) / 1=unreadable literal / 2=too many digits
snooze_parse_duration() {
  local raw="$1" number unit
  case "$raw" in
    *[0-9]s | *[0-9]m | *[0-9]h)
      number="${raw%?}"
      unit="${raw#"$number"}"
      ;;
    *)
      number="$raw"
      unit="s"
      ;;
  esac
  rein_config_int_too_long "$number" && return 2
  rein_is_pos_int "$number" || return 1
  case "$unit" in
    s) printf '%s\n' "$number" ;;
    m) printf '%s\n' "$((number * 60))" ;;
    h) printf '%s\n' "$((number * 3600))" ;;
    *) return 1 ;;
  esac
  return 0
}

cmd_snooze() {
  local duration="" seconds until requested_at epoch content rc
  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        take_verb_opt "$@"
        rc=$?
        case "$rc" in
          0) shift "$VERB_SHIFT" ;;
          2) return 2 ;;
          *)
            fail_usage "unknown argument to snooze: $1"
            return 2
            ;;
        esac
        ;;
      *)
        if [ -n "$duration" ]; then
          fail_usage "snooze takes exactly one duration: $1"
          return 2
        fi
        duration="$1"
        shift
        ;;
    esac
  done
  if [ -z "$duration" ]; then
    fail_usage "snooze requires a duration (any positive integer plus unit s / m / h; no unit means seconds. Example: 30m)"
    return 2
  fi
  # The reason differs by cause -- lumping an overflow under "cannot read" would return a line
  # the caller can't act on for input that is otherwise perfectly readable as a literal.
  seconds="$(snooze_parse_duration "$duration")"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    fail_usage "duration is too large (integers are capped at ${REIN_CONFIG_INT_MAX_DIGITS} digits): ${duration}"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    fail_usage "cannot read the duration (any positive integer plus unit s / m / h; no unit means seconds. Example: 30m): ${duration}"
    return 2
  fi
  prepare_runtime || return 1
  require_prerequisites || return 1
  if [ "$seconds" -gt "$SNOOZE_MAX_SEC" ]; then
    fail "exceeds the snooze cap of ${SNOOZE_MAX_SEC} seconds (${seconds} seconds). The cap is config's snooze_max_sec"
    return 1
  fi
  ensure_runtime_or_fail || return 1
  # The request time and the deadline are built from **the same single read of the clock**.
  # Reading the clock twice separately can straddle a second boundary, leaving a record where
  # `until - requested_at` is off by one second from the requested duration (the marker then
  # disagrees with itself, and the duration check fails intermittently).
  requested_at="$(rein_iso_now)"
  epoch="$(rein_iso_to_epoch "$requested_at")" || epoch=""
  if [ -n "$epoch" ]; then
    until="$(TZ=UTC date -u -r "$((epoch + seconds))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  else
    until=""
  fi
  if [ -z "$until" ]; then
    fail "cannot build the deadline time"
    return 1
  fi
  content="$(jq -nc \
    --arg schema "$REIN_SNOOZE_SCHEMA" \
    --arg requested_at "$requested_at" \
    --arg until "$until" \
    --argjson duration_sec "$seconds" \
    '{schema: $schema, requested_at: $requested_at, until: $until, duration_sec: $duration_sec}')"
  if [ -z "$content" ] || ! rein_write_json_atomic "$SNOOZE_FILE" "$content"; then
    fail "cannot write the snooze marker: ${SNOOZE_FILE}"
    return 1
  fi
  printf 'postponing forced handover until %s (%s seconds): %s\n' "$until" "$seconds" "$SNOOZE_FILE"
  return 0
}
