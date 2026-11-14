# Repository instructions

This repository contains only the envmgr tool. Machine data lives in a
separate data repository. Read `DESIGN.md` before making changes.

## Working rules

- Keep each change small; implement one command or provider at a time.
- Bash only, compatible with Bash 3.2: no associative arrays, `mapfile`,
  `${var,,}`, or other Bash 4+ features. `envmgr setup` must run from
  `/bin/bash` on a fresh Mac.
- Use `set -euo pipefail` in entry points. Inside functions that callers
  invoke with `||`, check failures explicitly, because `set -e` does not
  apply there.
- Parse `key=value` files with `envmgr_kv_get`; never source data files.
- Package providers live in `lib/envmgr/providers/<name>.sh` and implement
  the operations listed at the top of `lib/envmgr/package.sh`. Provider
  operations run inside `if` and `||` contexts, so they must return non-zero
  explicitly on failure. Test providers with fakes in `tests/fakes/`.
- Keep commands idempotent. Commands that change the system preview first and
  confirm, unless `--yes` is given.
- Add or update tests in `tests/run.sh` for every behavior change, and run the
  suite under both `/bin/bash` and a current Bash.
- Validate with `bash -n` and `git diff --check` (and `shellcheck` when it is
  available).
- Never commit private keys, tokens, or other credentials, and never add
  personal machine data to this repository.
- Update `DESIGN.md`, including its decisions table, when behavior or an
  architectural decision changes.
