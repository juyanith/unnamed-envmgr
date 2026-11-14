# unnamed-envmgr

Envmgr restores a machine's configuration files, packages, and system setup
from a private data repository, and reports when the machine has drifted from
it. See [DESIGN.md](DESIGN.md) for the full specification.

> [!WARNING]
> **Work in progress.** Envmgr is still being built. Commands, options, and the data repository layout can change or break between versions. Envmgr changes files, packages, and system settings, so preview with `--dry-run` and keep backups. If you choose to use it, you do so at your own risk: it comes as is, with no warranty of any kind.

**Status:** ready for testing. Every command in DESIGN.md is implemented:
`setup`, `init`, `check`, `list`, `restore`, `adopt` (including
`--encrypt`), `drop`, `evaluate`, `migrate`, system units, and the `git`,
`homebrew`, `omarchy`, `flatpak`, and `rpm-ostree` providers.

## Requirements

- macOS, Omarchy, or Fedora COSMIC Atomic
- Bash 3.2 or newer and Git (`setup` installs Chezmoi)
- A private data repository with a `machines/` directory (see DESIGN.md)

## First run

```sh
git clone https://github.com/juyanith/unnamed-envmgr ~/.local/share/unnamed-envmgr
~/.local/share/unnamed-envmgr/bin/envmgr setup
```

`setup` asks a few questions and can be rerun safely; it skips finished
steps. It:

1. Installs Git and Chezmoi if they are missing (Command Line Tools and
   Homebrew on macOS, `omarchy pkg add` on Omarchy, Homebrew on Fedora
   Atomic) and links `~/.local/bin/envmgr`.
2. For an SSH data URL on GitHub, creates `~/.ssh/id_ed25519` if needed,
   shows the public key, opens https://github.com/settings/ssh/new, and waits
   until GitHub accepts the key. `gh` is not needed.
3. Clones the data repository (default
   `git@github.com:juyanith/envmgr-data.git` into `~/Work/Git/envmgr-data`).
4. Selects this machine from the data repository, creates a new one
   (optionally copied from an existing machine), or skips.
5. If the machine has encrypted files and no age key, explains how to copy
   `~/.config/envmgr/age.key` from another machine.
6. Optionally records an agent command for `envmgr evaluate`.

Then review and apply:

```sh
envmgr check              # exit 0 in sync, 3 drift
envmgr restore --dry-run  # preview: packages, then config, then system units
envmgr restore
```

While drift remains, `~/.local/state/envmgr/change_summary` exists.
`envmgr restore` exits `75` when a reboot or re-login is needed; rerun it
afterward.

## Other commands

```sh
envmgr adopt config --encrypt ~/.netrc   # secrets: stored only as age ciphertext
envmgr evaluate [config|package|system]  # start the agent with the current check
envmgr migrate <url>                     # move envmgr-data to a new, empty remote
envmgr migrate --no-history <url>        # or move a clean copy of its current files
envmgr migrate --follow <url>            # then, on every other machine
```

The first `--encrypt` creates `~/.config/envmgr/age.key`. Back it up and copy
it to each machine that restores encrypted files; it is never committed.

## Development

```sh
tests/run.sh             # runs every test under /bin/bash and bash on PATH
```

The tests need `chezmoi` on `PATH` and use a temporary `HOME`.
