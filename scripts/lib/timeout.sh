# shellcheck shell=bash
# Portable wall-clock guard. No dependency on timeout(1)/gtimeout.
# Usage: ens_run_timeout SECS -- CMD [ARGS...]   (returns CMD rc, or 124 if killed)
ens_run_timeout() {
  local secs="$1"; shift
  [ "${1:-}" = "--" ] && shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $s = shift @ARGV;
      my $pid = fork();
      defined $pid or do { warn "ens_run_timeout: fork failed\n"; exit 124 };
      if ($pid == 0) { exec @ARGV or exit 127; }
      local $SIG{ALRM} = sub { kill("TERM",$pid); sleep 1; kill("KILL",$pid); };
      alarm $s;
      waitpid($pid, 0);
      my $rc = $?;
      alarm 0;
      if ($rc & 127) { exit 124; }        # killed by our signal
      exit($rc >> 8);
    ' "$secs" "$@"
    return $?
  fi
  # python fallback
  python3 - "$secs" "$@" <<'PY'
import os,signal,subprocess,sys
secs=float(sys.argv[1]); cmd=sys.argv[2:]
p=subprocess.Popen(cmd)
try: sys.exit(p.wait(timeout=secs))
except subprocess.TimeoutExpired:
    p.terminate()
    try: p.wait(1)
    except subprocess.TimeoutExpired: p.kill()
    sys.exit(124)
PY
}
