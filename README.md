# unnamed-envmgr

Envmgr restores a machine's configuration files, packages, and system setup
from a private data repository, and reports when the machine has drifted from
it. See [DESIGN.md](DESIGN.md) for the full specification.

> [!WARNING]
> **Work in progress.** Envmgr is still being built. Commands, options, and the data repository layout can change or break between versions. Envmgr changes files, packages, and system settings, so preview with `--dry-run` and keep backups. If you choose to use it, you do so at your own risk: it comes as is, with no warranty of any kind.

**Status:** ready for testing. Every command in DESIGN.md is implemented:
`setup`, `init`, `check`, `list`, `restore`, `adopt` (including
`--encrypt`), `drop`, `diff`, `evaluate`, `migrate`, `save`, `publish`,
system units, and the `git`, `homebrew`, `omarchy`, `flatpak`, and
`rpm-ostree` providers.

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
4. Selects this machine from the data repository, creates a new one, or
   skips. A new machine's ID defaults to the host name, and it is copied
   from the matching machine changed most recently unless you choose another
   one or `none`.
5. If the machine has encrypted files and no age key, lets you paste the key
   (for example, from a password manager), checks that it decrypts the
   machine's files, and saves it as `~/.config/envmgr/age.key`. Or press
   Enter and copy the file over from another machine before restoring.
6. Optionally records an agent command for `envmgr evaluate`.
7. Declares Git and Chezmoi in the machine's Homebrew or Omarchy packages
   if they were installed that way and aren't declared yet, so
   `envmgr restore` keeps them upgraded.
8. Offers to commit and push a new or changed machine with `envmgr publish`.
9. Offers to run `envmgr restore`, which previews and confirms packages, then
   config, then system units.
10. Prints the machine's `POSTINSTALL.md`, if it has one: manual steps such as
   signing in to the App Store or granting privacy permissions.

When restore needs a reboot or re-login (exit `75`), or stops on an error,
setup says so; run `envmgr setup` again afterward and it continues where it
stopped. Later, check and apply the machine with:

```sh
envmgr check              # exit 0 in sync, 3 drift
envmgr restore --dry-run  # preview: packages, then config, then system units
envmgr restore
```

While drift remains, `~/.local/state/envmgr/change_summary` exists.
`envmgr restore` exits `75` when a reboot or re-login is needed; rerun it
afterward.

## Keeping changes

Edits you make to managed files in your home directory stay local until you
save them into this machine's source, then publish them so other machines
can restore them:

```sh
envmgr check config       # edited files show as local changes
envmgr diff               # see what changed, here and in the source
envmgr save               # copy local edits into the source (or name targets)
envmgr publish            # commit this machine's directory and push it
```

`save` skips templates and `modify_` files (edit their source instead), and
any file that also changed in the source since it was last restored, so a
pulled change is never overwritten. For those, `envmgr diff <file>` shows
each side's change; then keep yours with `envmgr save --force <file>`, take
the source's with `envmgr restore config <file>`, or edit the file to combine
them and save it with `--force`. Start managing a new file with
`envmgr adopt config`, then publish.

## Other commands

`envmgr --help` lists every command with its options. The most common:

```sh
envmgr adopt config ~/.config/example  # start managing a file or directory
                                       # (or the new files in a managed one)
envmgr adopt config --encrypt ~/.netrc # secrets: stored only as ciphertext
envmgr adopt config --from <id> ~/.x   # copy config only another machine has
envmgr adopt package <provider> <pkg>  # add an installed package
envmgr diff [target...]                # show changed config, both sides
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
envmgr save [target...]                # copy local edits into the source
envmgr save --force <target...>        # even if the source changed too
envmgr publish                         # commit this machine's changes, push
```

The first `--encrypt` creates `~/.config/envmgr/age.key`. Back it up (a
password manager works well, because setup accepts the pasted key) and copy
it to each machine that restores encrypted files; it is never committed.

## Development

```sh
tests/run.sh             # runs every test under /bin/bash and bash on PATH
```

The tests need `chezmoi` on `PATH` and use a temporary `HOME`.
