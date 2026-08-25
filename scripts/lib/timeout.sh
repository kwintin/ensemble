# shellcheck shell=bash
# Portable wall-clock guard.
# Usage: ens_run_timeout SECS -- CMD [ARGS...]   (returns CMD rc, or 124 if killed)
#
# Backends, in preference order: GNU coreutils timeout(1)/gtimeout, a perl guard,
# then a python3 guard. The first two are PROBED before use.
#
# Why probe: both are driven by alarm(2)/interval timers, and on a host where those
# timers do not fire they do not fail loudly -- they run the child to completion and
# return ITS exit status, so the guard silently does nothing. That is worse than
# having no guard at all, since every caller believes it is protected. Observed in
# practice with coreutils 9.11, where `timeout 2 sleep 10` returned 0 after the full
# 10s while a manually delivered SIGALRM still worked. A backend that fails to
# interrupt a live child is therefore skipped. The python3 backend waits on the child
# directly and needs no timer, so it is the dependable last resort (python3 is already
# a hard requirement of this project).
#
# The probe runs at most once per process and costs ~20ms on a healthy host.
# Set ENS_TIMEOUT_FORCE_BACKEND=coreutils|perl|python3 to bypass selection (tests).

_ENS_TIMEOUT_BACKEND=""   # cached for the life of this process; deliberately not exported

_ens_timeout_probe_coreutils() { # BIN -> 0 only if it really interrupts a live child
  local rc=0
  "$1" --kill-after=1 0.02 sleep 0.2 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 124 ]
}

_ens_timeout_probe_perl() { # -> 0 only if alarm(2) actually fires
  local rc=0
  perl -MTime::HiRes=alarm -e \
    '$SIG{ALRM} = sub { exit 124 }; alarm(0.02); select(undef, undef, undef, 0.2); exit 0' \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 124 ]
}

_ens_timeout_backend() { # -> coreutils:<bin> | perl | python3 | none
  if [ -n "${ENS_TIMEOUT_FORCE_BACKEND:-}" ]; then
    case "$ENS_TIMEOUT_FORCE_BACKEND" in
      coreutils) command -v timeout >/dev/null 2>&1 && { printf 'coreutils:timeout'; return 0; }
                 command -v gtimeout >/dev/null 2>&1 && { printf 'coreutils:gtimeout'; return 0; } ;;
      perl|python3) printf '%s' "$ENS_TIMEOUT_FORCE_BACKEND"; return 0 ;;
    esac
  fi
  [ -n "$_ENS_TIMEOUT_BACKEND" ] && { printf '%s' "$_ENS_TIMEOUT_BACKEND"; return 0; }

  local to=""
  if   command -v timeout  >/dev/null 2>&1; then to=timeout
  elif command -v gtimeout >/dev/null 2>&1; then to=gtimeout
  fi
  if [ -n "$to" ] && "$to" --help 2>/dev/null | grep -q -- '--kill-after' \
     && _ens_timeout_probe_coreutils "$to"; then
    _ENS_TIMEOUT_BACKEND="coreutils:$to"
  elif command -v perl >/dev/null 2>&1 && _ens_timeout_probe_perl; then
    _ENS_TIMEOUT_BACKEND="perl"
  elif command -v python3 >/dev/null 2>&1; then
    _ENS_TIMEOUT_BACKEND="python3"
  else
    _ENS_TIMEOUT_BACKEND="none"
  fi
  printf '%s' "$_ENS_TIMEOUT_BACKEND"
}

ens_run_timeout() {
  local secs="$1"; shift
  [ "${1:-}" = "--" ] && shift
  case "$secs" in ''|*[!0-9]*) echo "ens_run_timeout: invalid timeout '$secs'" >&2; return 2 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || { echo "ens_run_timeout: timeout must be > 0" >&2; return 2; }

  local backend; backend="$(_ens_timeout_backend)"
  case "$backend" in
    coreutils:*)
      # HARD guard: TERM, then KILL after --kill-after.
      "${backend#coreutils:}" --kill-after=10 "$secs" "$@"
      local rc=$?
      [ "$rc" -eq 137 ] && rc=124   # SIGKILL after timeout -> our timeout code
      return $rc
      ;;
    perl)
      perl -e '
        my $s = shift @ARGV;
        my $pid = fork();
        defined $pid or do { warn "ens_run_timeout: fork failed\n"; exit 125 };
        if ($pid == 0) { setpgrp(0,0); exec @ARGV or exit 127; }
        my $timed_out = 0;
        local $SIG{ALRM} = sub { $timed_out = 1; kill("TERM", -$pid); sleep 1; kill("KILL", -$pid); };
        alarm $s;
        waitpid($pid, 0);
        my $rc = $?;
        alarm 0;
        exit 124 if $timed_out;
        exit(128 + ($rc & 127)) if ($rc & 127);
        exit($rc >> 8);
      ' "$secs" "$@"
      return $?
      ;;
    python3)
      python3 - "$secs" "$@" <<'PY'
import os,signal,subprocess,sys
secs=float(sys.argv[1]); cmd=sys.argv[2:]
try:
    p=subprocess.Popen(cmd, start_new_session=True)
except FileNotFoundError:
    sys.exit(127)
except OSError:
    sys.exit(125)
try:
    rc=p.wait(timeout=secs)
except subprocess.TimeoutExpired:
    try: os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError: pass
    try: p.wait(1)
    except subprocess.TimeoutExpired:
        try: os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError: pass
    sys.exit(124)
sys.exit(128 + (-rc) if rc < 0 else rc)
PY
      return $?
      ;;
    *)
      # No usable guard. Run unguarded, but say so loudly -- never pretend to guard.
      echo "ens_run_timeout: no working timeout backend (need coreutils timeout, perl, or python3); running UNGUARDED" >&2
      "$@"
      return $?
      ;;
  esac
}
