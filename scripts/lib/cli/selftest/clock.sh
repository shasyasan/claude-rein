# shellcheck shell=bash
# This section carries no variables shared across sections, so it skips the broad
# `disable=SC2154,SC2034` that other section files place at the top -- don't preemptively kill
# the one layer that would catch a spelling drift on the day a shared variable is added.
# selftest for converting contract timestamps (pure functions within this same process only).
# It doesn't start the watcher, the seat, or a fake CLI; the only child process it starts is the
# real `date`, used as the oracle -- so this layer is pure.
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_clock() {
  # Contract timestamp format -> epoch conversion (arithmetic only, no external command).
  # **Checked against the real `date -j -f`** (the arithmetic here is never confirmed against an
  # expected value written here).
  for iso in 1970-01-01T00:00:00Z 2000-02-29T00:00:00Z 2020-01-01T00:00:00Z \
    2024-02-29T12:34:56Z 2026-08-16T23:59:59Z 2038-01-19T03:14:08Z 2100-03-01T00:00:00Z; do
    oracle="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)"
    mine="$(rein_iso_to_epoch "$iso")"
    if [ -n "$oracle" ] && [ "$mine" = "$oracle" ]; then
      st_ok
    else
      st_fail "converts the timestamp the same way date does (${iso})" "computed=${mine} / date=${oracle}"
    fi
  done
  # Reject strings that aren't valid calendar dates (BSD date rolls these over and lets them
  # through instead of rejecting them -- observed).
  for iso in 2020-02-30T00:00:00Z 2021-02-29T00:00:00Z 2020-13-01T00:00:00Z \
    2020-01-32T00:00:00Z 2020-01-00T00:00:00Z 2020-00-01T00:00:00Z \
    2020-01-01T24:00:00Z 2020-01-01T00:60:00Z 2020-01-01T00:00:60Z \
    2020-01-01T00:00:00 2020-01-01T00:00:00Zx; do
    if rein_iso_to_epoch "$iso" >/dev/null 2>&1; then
      st_fail "rejects a timestamp that isn't a valid calendar date (${iso})" "let it through"
    else
      st_ok
    fi
  done
}
