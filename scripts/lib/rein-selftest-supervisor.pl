#!/usr/bin/env perl
# A minimal supervisor for running a single selftest with a time bound.
# Usage: rein-selftest-supervisor.pl <deadline seconds> <output file> <command> [args...]
# Output (stdout/stderr) is appended to the output file. The caller tails that file to display
# it as it comes in, and treats this process's exit code as the selftest's exit code, unchanged.
use strict;
use warnings;

use POSIX qw(setpgid WNOHANG WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $DEADLINE_RC = 142;
my $POLL_SEC = 0.02;
my $TERM_GRACE_SEC = 0.5;

# Measures the deadline against the monotonic clock rather than the wall clock, so a clock
# adjustment or a DST change never stretches or shrinks it.
sub now_monotonic { return clock_gettime(CLOCK_MONOTONIC); }

my ($deadline_sec, $output_file, @command) = @ARGV;
die "usage: $0 <deadline seconds> <output file> <command> [args...]\n"
  unless defined $deadline_sec
  && $deadline_sec =~ /\A[1-9][0-9]*\z/
  && defined $output_file
  && length $output_file
  && @command;

my $pid = fork();
die "fork failed: $!\n" unless defined $pid;
if ($pid == 0) {
  # Makes itself the leader of its own process group, so that if it hangs, every descendant in
  # the group is stopped too, not just the leader (the parent signals the group).
  defined setpgid(0, 0) or exit 125;
  open STDIN, '<', '/dev/null' or exit 125;
  open STDOUT, '>>', $output_file or exit 125;
  open STDERR, '>&', \*STDOUT or exit 125;
  { no warnings 'exec'; exec @command; }
  print STDERR "exec failed: $command[0]: $!\n";
  exit 127;
}

# Sets the same group on the parent side too (closes a race: if the deadline or an interrupt
# arrives before the child finishes its own setpgid, there'd be no group yet for the signal to
# reach). This call fails when the child has already exec'd or already exited, but by then the
# child has either set the group itself or there is nothing left to signal, so the failure can
# be ignored.
setpgid($pid, $pid);

# An interrupt the caller receives is passed on to the child's whole group, not only to this
# supervisor. The child sits in its own group and never receives the terminal's Ctrl-C directly,
# so without this forwarding, only the caller and this supervisor would die and the selftest
# would keep running as an orphan. The watch loop keeps going after the signal -- reaping the
# child and passing its exit code through happens the same way as in the deadline branch, so
# $stopped stays unset (setting it would make an interrupt read as a deadline and return 142).
# The leader is signaled directly as well, in case the group was never formed (the child's
# setpgid failed and it exits with 125).
for my $name (qw(INT TERM HUP QUIT)) {
  $SIG{$name} = sub { kill($_[0], -$pid); kill($_[0], $pid) };
}

my $deadline = now_monotonic() + $deadline_sec;
my $stopped = 0;
while (1) {
  my $waited = waitpid($pid, WNOHANG);
  if ($waited == $pid) {
    my $status = $?;
    if ($stopped) {
      # Even if the leader exits first, make sure any descendants still left in the same group
      # are also stopped (a child that ignores TERM doesn't go away just because the leader
      # exited).
      kill 'KILL', -$pid;
      exit $DEADLINE_RC;
    }
    exit WEXITSTATUS($status) if WIFEXITED($status);
    exit 128 + WTERMSIG($status) if WIFSIGNALED($status);
    exit 125;
  }
  die "waitpid failed: $!\n" if $waited < 0;
  if (now_monotonic() >= $deadline) {
    if ($stopped) {
      kill 'KILL', -$pid;
    } else {
      kill 'TERM', -$pid;
      $stopped = 1;
      $deadline = now_monotonic() + $TERM_GRACE_SEC;
    }
  }
  sleep $POLL_SEC;
}
