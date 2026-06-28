# shellcheck shell=bash
# Portable wall-clock guard. Prefers GNU coreutils timeout(1)/gtimeout; falls back to perl/python.
# Usage: ens_run_timeout SECS -- CMD [ARGS...]   (returns CMD rc, or 124 if killed)
ens_run_timeout() {
  local secs="$1"; shift
  [ "${1:-}" = "--" ] && shift
  case "$secs" in ''|*[!0-9]*) echo "ens_run_timeout: invalid timeout '$secs'" >&2; return 2 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || { echo "ens_run_timeout: timeout must be > 0" >&2; return 2; }
  # Prefer GNU coreutils timeout(1) (gtimeout on macOS/Homebrew): battle-tested
  # signal/process-group handling + exit-code conventions (124 timeout, 127 missing,
  # 128+N signal). Fall back to a portable perl/python guard when it is absent.
  local to=""
  if   command -v timeout  >/dev/null 2>&1; then to=timeout
  elif command -v gtimeout >/dev/null 2>&1; then to=gtimeout
  fi
  if [ -n "$to" ]; then
    "$to" --kill-after=10 "$secs" "$@"
    local rc=$?
    [ "$rc" -eq 137 ] && rc=124   # SIGKILL after timeout -> normalize to our timeout code
    return $rc
  fi
  # --- portable fallback (no coreutils timeout available) ---
  if command -v perl >/dev/null 2>&1; then
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
  fi
  python3 - "$secs" "$@" <<'PY'
import os,signal,subprocess,sys
secs=float(sys.argv[1]); cmd=sys.argv[2:]
try:
    p=subprocess.Popen(cmd, start_new_session=True)
except FileNotFoundError:
    sys.exit(127)
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
}
