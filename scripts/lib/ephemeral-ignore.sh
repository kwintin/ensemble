# shellcheck shell=bash
# Single source of truth for the "ephemeral artifact" denylist: paths a reviewer or
# executor legitimately produces by RUNNING the code (bytecode, tool caches, venvs,
# coverage), which are NEVER a meaningful source change. Shared by:
#   - ens-review.sh   (read-only guard: keep these out of the porcelain delta so a
#                       reviewer that runs the code doesn't false-trip a violation)
#   - ens-delegate.sh (merge: keep these out of `git add -A` so a delegated commit
#                       never carries bytecode/cache junk)
# Writes gitignore-style patterns (no leading slash -> match at any depth) to $1; pass
# the file as `git -c core.excludesFile="$1" ...`. core.excludesFile only affects
# UNTRACKED files, so a tracked-file edit or a NEW non-ephemeral file is unaffected
# (the real source-change / tamper signal is preserved).
ens_write_ephemeral_ignore() { # OUT_FILE
  printf '%s\n' \
    '__pycache__/' '*.py[cod]' '.serena/' '.pytest_cache/' '.mypy_cache/' '.ruff_cache/' \
    '.tox/' '.ipynb_checkpoints/' '.DS_Store' 'node_modules/' '.venv/' 'venv/' \
    '.coverage' '.cache/' '*.egg-info/' > "$1"
}
