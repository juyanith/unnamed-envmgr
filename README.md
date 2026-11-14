# unnamed-envmgr

Envmgr restores a machine's configuration files, packages, and system setup
from a private data repository, and reports when the machine has drifted from
it. See [DESIGN.md](DESIGN.md) for the full specification.

> [!WARNING]
> **Work in progress.** Envmgr is still being built. Commands, options, and the data repository layout can change or break between versions. Envmgr changes files, packages, and system settings, so preview with `--dry-run` and keep backups. If you choose to use it, you do so at your own risk: it comes as is, with no warranty of any kind.

**Status:** ready for testing. Every command in DESIGN.md is implemented:
`setup`, `init`, `check`, `list`, `restore`, `adopt` (including
`--encrypt`), `drop`, `evaluate`, `migrate`, `save`, system units, and the `git`,
`homebrew`, `omarchy`, `flatpak`, and `rpm-ostree` providers.

## Requirements

- macOS, Omarchy, or Fedora COSMIC Atomic
- Bash 3.2 or newer and Git (`setup` installs Chezmoi)
- A private data repository with a `machines/` directory (see DESIGN.md)

## First run

```sh
curl -fsSL https://raw.githubusercontent.com/juyanith/unnamed-envmgr/main/install.sh | bash
```

`install.sh` makes Git usable (on macOS it installs the Command Line Tools
and waits for them), clones envmgr into `~/.local/share/unnamed-envmgr`, and
starts `envmgr setup`. To do the same by hand:

```sh
git clone https://github.com/juyanith/unnamed-envmgr ~/.local/share/unnamed-envmgr
~/.local/share/unnamed-envmgr/bin/envmgr setup
```

`setup` asks a few questions and can be rerun safely; it skips finished
steps. It:

1. Installs Git and Chezmoi if they are missing (Command Line Tools and
   Homebrew on macOS, `omarchy pkg add` on Omarchy, Homebrew on Fedora
   Atomic), asking once for the administrator password that Homebrew's
   installer needs, and links `~/.local/bin/envmgr`.
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

`envmgr --help` lists every command with its options. The most common:

```sh
envmgr adopt config ~/.config/example  # start managing a file or directory
envmgr adopt config --encrypt ~/.netrc # secrets: stored only as ciphertext
envmgr adopt config --from <id> ~/.x   # copy config only another machine has
envmgr adopt package <provider> <pkg>  # add an installed package
envmgr drop config [--delete] ~/.x     # stop managing (--delete removes it)
envmgr drop package [--delete] <provider> <pkg>  # --delete uninstalls
envmgr evaluate [config|package|system]  # start the agent with the check
envmgr evaluate --from <id>            # start the agent to copy config from it
envmgr init <id>                       # select an existing machine
envmgr init --new <id> [--from <id>]   # create a machine, or copy another
envmgr list [config|package|system]    # list what this machine manages
envmgr migrate <url>                   # move envmgr-data to an empty remote
envmgr migrate --no-history <url>      # or move a copy of its current files
envmgr migrate --follow <url>          # then, on every other machine
envmgr save                            # commit this machine's changes, push
```

The first `--encrypt` creates `~/.config/envmgr/age.key`. Back it up and copy
it to each machine that restores encrypted files; it is never committed.

## Development

```sh
tests/run.sh             # runs every test under /bin/bash and bash on PATH
```

The tests need `chezmoi` on `PATH` and use a temporary `HOME`.
