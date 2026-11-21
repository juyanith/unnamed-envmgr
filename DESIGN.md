# Envmgr Design

**Status:** Specification for `unnamed-envmgr`. Decisions are recorded at the
end of this document with their dates. The one-time migration from the
legacy layered `envmgr` repository is documented in that repository.

## Purpose

Envmgr manages an explicitly selected set of user configuration files,
packages, and system setup for a small number of named machine environments.
Git keeps the current configuration and its history. Chezmoi is the initial
backend for configuration files; package providers handle package operations;
system units handle setup outside `$HOME`. A stable `envmgr` command interface
keeps the user workflow independent of those backends.

An agent is an optional authoring tool. It helps evaluate and change the
machine's specification, configuration files, package manifests, and system
units. Envmgr does not require configuration composition or automatic
inheritance between machines.

### Terms

- **Machine:** one named environment running one OS installation. A computer
  that boots two operating systems has two machines.
- **Category:** one of `config`, `package`, or `system`.
- **Target:** a destination path under `$HOME` managed by Chezmoi.
- **Provider:** a package manager integration.
- **System unit:** a machine-owned `check`/`apply` pair for setup outside
  `$HOME` and outside package managers.

## Repositories

| Repository | Visibility | Contents |
|---|---|---|
| `unnamed-envmgr` | Public | The tool only: `install.sh`, `bin/envmgr`, `lib/envmgr/`, tests, `README.md` (first-run walkthrough), `DESIGN.md`, `AGENTS.md`. Cloned over HTTPS; no `gh` or credentials needed. |
| `envmgr-data` | Private | `machines/`, plus an `AGENTS.md` with configuration rules (for example, Omarchy's `/usr/share/omarchy/` is read-only upstream state). Cloned over SSH. |
| `envmgr` | Private | Legacy layered implementation and `legacy-export.sh`. Deleted by the user once the machines they care about are migrated. |

`envmgr-data` layout:

```text
AGENTS.md
README.md
machines/
  <machine-id>/
    machine.conf           # metadata
    SPEC.md                # human/agent specification for this machine
    POSTINSTALL.md         # optional: manual steps envmgr cannot automate
    config/                # complete Chezmoi source for this machine
    packages/<provider>/   # provider manifests (see Packages)
    system/<NN-name>/      # system units (see System units)
```

## Local layout

```text
~/.local/share/unnamed-envmgr/    # tool checkout (kept current by the git provider)
~/.local/bin/envmgr -> ../share/unnamed-envmgr/bin/envmgr
~/Work/Git/envmgr-data/           # data checkout; the user edits and commits here
~/.config/envmgr/config           # key=value, parsed, never sourced
  data=~/Work/Git/envmgr-data
  data_url=git@github.com:<user>/envmgr-data.git
  machine=mac-mini
  agent=codex
~/.config/envmgr/age.key          # age identity; never committed
~/.config/chezmoi/chezmoi.toml    # written by envmgr init (see Secrets)
~/.local/state/envmgr/            # $XDG_STATE_HOME/envmgr
  change_summary
  check/<category>                # last recorded result per category
  cache/                          # provider update metadata for offline checks
  system/<machine>/<unit>.applied # stamps for units without a check script
  backups/<timestamp>/...         # targets replaced by restore config
  backups/<label>-<timestamp>/    # files replaced by setup or init
```

Both checkout paths are configurable during `envmgr setup`.

## Machine metadata

`machines/<id>/machine.conf` uses `key=value` lines:

```text
os=darwin
distribution=macos
architecture=apple-silicon
description=Mac mini, primary desk machine
```

- `os` and `distribution` are required. Commands that change the system or
  copy from it (`restore`, `adopt`, `drop`, `save`), and `init`, refuse to
  run when they do not match the running system. `check`, `list`,
  `evaluate`, `diff`, and `publish` warn and continue.
- A mismatch in the optional `architecture` field produces a warning.
- Hardware is not a dimension. Hardware-specific settings live in the files
  of the machines that need them.
- Machine IDs are chosen names, not hostnames.

## General command rules

```text
envmgr setup
envmgr init [--data <path>] <id> | init [--data <path>] --new <id> [--from <id>]
envmgr check   [config|package [provider]|system] [--offline]
envmgr list    [config|package [provider]|system]
envmgr restore [config|package|system] [...]
envmgr adopt   config|package ... | adopt config --from <id> target...
envmgr drop    config|package ...
envmgr evaluate [config|package|system] [--offline]
envmgr evaluate --from <id> [target...] [--offline]
envmgr migrate [--no-history] <url> | migrate --follow <url>
envmgr diff    [config] [target...]
envmgr save    [config] [--force] [target...]
envmgr publish [-m <message>] [--no-push]
```

`envmgr --help` lists every form with its options and a one-line summary.

- Every command acts on the active machine from `~/.config/envmgr/config`.
  If no machine is configured, the command exits with an error that suggests
  `envmgr setup` or `envmgr init`.
- With no category, `check`, `list`, `restore`, and `evaluate` cover all
  three. `restore` always runs in the order package → config → system,
  because configuration and units depend on installed tools, and units may
  read restored targets. A phase that ends with `75` stops the run.
- Commands that change the system print a preview and ask for confirmation.
  `--yes` (`-y`) skips confirmation; `--dry-run` (`-n`) prints the preview
  and exits. Without `--yes`, confirmation needs a terminal.
- Exit codes: `0` success or in sync; `1` error; `2` usage error; `3` check
  found drift; `75` reboot or re-login required before continuing.
- Envmgr commits only in `publish`, and only the active machine's directory.
  It pushes only in `publish` and `migrate`, and pulls only through the `git`
  provider and `evaluate --from` (fast-forward only, clean checkouts only)
  and the rebase in `publish`.
- Envmgr is written in Bash and must run under Bash 3.2, because
  `envmgr setup` runs from `/bin/bash` on a fresh Mac before Homebrew exists.
  No associative arrays, `mapfile`, `${var,,}`, or other Bash 4+ features.
- `bin/envmgr` puts all logic in functions and calls `main "$@"; exit` on its
  last line. Bash then has parsed the whole file before any work starts, so
  the git provider can update the tool's own checkout while it is running.
- The `git` provider runs first in a restore. If it changes the tool or data
  checkout, envmgr re-executes itself with the same arguments, so the rest of
  the run uses the new code and the newly pulled manifests and sources.

## Setup and repositories

#### `envmgr setup`

The `unnamed-envmgr` README directs a new user to one command:

```sh
curl -fsSL https://raw.githubusercontent.com/juyanith/unnamed-envmgr/main/install.sh | bash
```

`install.sh` does only what `setup` cannot do for itself, and knows nothing
about machines or packages:

- Make Git usable: on macOS, start the Command Line Tools installer and wait
  until `xcode-select -p` succeeds; elsewhere, use `git` when present, run
  `omarchy pkg add git` on Omarchy, and otherwise stop and ask the user to
  install Git.
- Clone the tool into `~/.local/share/unnamed-envmgr` over HTTPS, or
  fast-forward an existing checkout (warning when it cannot).
- Replace itself with `envmgr setup`, reading from the terminal rather than
  from the download. All of the script runs from a function called on its
  last line, so a partial download does nothing.

Cloning by hand and running `bin/envmgr setup` is equivalent.

`setup` is interactive and idempotent. It skips steps that are already
complete:

1. **Prerequisites.** Install Git and Chezmoi with the platform's native
   method (Xcode Command Line Tools and Homebrew on macOS, `omarchy pkg add`
   on Omarchy, a Homebrew bootstrap on Fedora Atomic). Setup waits for the
   Command Line Tools installer to finish rather than exiting. Before
   installing Homebrew, it runs `sudo -v` once and keeps the timestamp fresh
   until it exits, because Homebrew's non-interactive installer fails when
   `sudo` would prompt. Link `~/.local/bin/envmgr`.
2. **SSH.** If no key exists, create `~/.ssh/id_ed25519` (with a passphrase
   prompt). Print the public key, open
   `https://github.com/settings/ssh/new`, and wait for confirmation. Verify
   access with `ssh -T git@github.com`. Does not use `gh`.
3. **Data repository.** Ask for the URL and checkout path (default
   `~/Work/Git/envmgr-data`), then clone. The URL has no built-in default,
   because it is personal; the default offered is the `data_url` saved by an
   earlier run, or else `ENVMGR_DATA_URL`. With neither, the prompt shows
   `git@github.com:<username>/envmgr-data.git` as an example (not a default),
   and a blank answer stops setup.
4. **Machine.** Offer the existing machines whose `os`/`distribution` match
   the running system, a new machine (optionally copied from one of them), or
   skip (used during legacy migration). Selecting a machine runs
   `envmgr init`. For a new machine, setup suggests an ID made from the host
   name (lowercased, other characters replaced by `-`) when it is free,
   suggests copying the matching machine whose directory has the latest
   commit (`none` starts empty), and asks for the `description`.
   Machines on another OS are never offered; a first machine on a new OS
   starts empty and is built up carefully with `adopt` and
   `evaluate --from`. When Chezmoi currently uses a source outside the data
   repository (for example, the legacy checkout), setup says so, recommends
   skip, and asks before switching.
5. **Age key.** When the selected machine has `encrypted_` files and
   `~/.config/envmgr/age.key` is missing, ask for the key to be pasted,
   without echoing it. Comment lines are skipped, so the `AGE-SECRET-KEY-`
   line or the whole key file can be pasted. Setup writes it with mode `600`
   only after it decrypts one of the machine's `encrypted_` files (`chezmoi
   decrypt` with a temporary config), and asks again otherwise. A blank
   answer explains how to copy the file instead. Setup never generates a
   key, because a new key cannot decrypt existing files.
6. **Agent.** Optionally record the agent command for `evaluate`.
7. **Tools.** For each of `git` and `chezmoi` that none of the machine's
   providers declares, adopt it with the provider step 1 installs through
   (`homebrew` on macOS and Fedora COSMIC Atomic, `omarchy` on Omarchy), so
   restore keeps it installed and upgraded. A tool the system provides (Git
   from the Command Line Tools or the Fedora image) is left undeclared and
   updated with the system.
8. **Publish.** When the selected machine's directory has uncommitted changes
   (for example, a machine created in step 4, or a tool declared in step
   7), offer to run `envmgr publish`,
   so the machine is on `origin` before anything long-running. A failed
   publish warns and setup continues.
9. **Restore.** Offer to run `envmgr restore`, which previews and confirms
   each phase as usual; inside setup, its confirmations read the same input
   as setup's questions. When restore exits `75`, setup asks for a reboot or
   re-login and exits `75`; on any other failure it exits `1`. Either way,
   running `envmgr setup` again skips the finished steps and reaches restore
   again. When the `git` provider pulls new code, restore re-executes
   `envmgr setup`, which continues to restore without asking again.
10. **Manual steps.** Print the machine's `POSTINSTALL.md`, if present: the
   steps envmgr cannot automate, such as App Store sign-in or privacy grants.

Yes/no questions whose usual answer is yes (publish, restore) default to yes.

#### `envmgr init`

- `init <id>` writes `machine=` to `~/.config/envmgr/config` and sets
  `sourceDir` in `~/.config/chezmoi/chezmoi.toml` (backing up a different
  existing file), after checking `machine.conf`. It changes no targets,
  packages, or system state; run `envmgr restore` next.
- `--data <path>` records `data=` first, for a data checkout that `setup`
  did not clone.
- `init --new <id> [--from <id>]` creates `machines/<id>/` with detected
  metadata and an empty `config/`, `packages/`, `system/`, and `SPEC.md`.
  With `--from`, it copies those, and `POSTINSTALL.md`, from another
  machine with the same `os` and `distribution`. Copies are owned
  independently from then on. Without `--from`, the `git` provider declares
  the envmgr checkout and the data checkout, as every machine does; a
  checkout that cannot be adopted (outside `$HOME`, no `origin`) warns.
  The new machine is then selected as with `init <id>`.

#### `envmgr migrate`

`migrate` moves the whole data repository, with its history, to a new remote:

1. Fetch `origin` (with `--prune` and tags), then check that the data
   checkout is clean, every local branch tracks a branch on `origin` and has
   no unpushed commits, and the new remote is empty.
2. Preview and confirm, then push every branch on `origin` (the default
   branch first, so a new hosted repository adopts it) and every tag. This
   replaces `git push --mirror`, which from a working checkout would also
   publish remote-tracking refs.
3. Run `git remote set-url origin <url>`, and update `data_url=`.
4. Update any git-provider entries that reference the old URL in every
   machine's manifests, and leave those edits uncommitted for review.
5. Print the follow-up step for other machines: `envmgr migrate --follow
   <url>`. It fetches the new remote into a temporary ref namespace (removed
   afterward), then:
   - when a branch there contains the current `HEAD`, changes only `origin`
     and `data_url=`;
   - when the new remote shares no history with the checkout (a copy made
     with `--no-history`), checks that the checkout is clean and fully
     pushed to the old `origin`, then, after confirmation, replaces the
     checkout as described below;
   - otherwise (shared history, but `HEAD` is missing) refuses, because the
     checkout has commits that were never migrated.

`migrate --no-history <url>` makes a clean copy instead: one new root commit
with the current files of `origin`'s default branch, pushed as that branch.
History, other branches, and tags stay only in the old repository; the
preview lists what is left out. Because the checkout no longer shares
history with its remote, envmgr then renames it to
`<data>.old-<timestamp>` and clones the new URL into the same path, so
`data=` and Chezmoi's `sourceDir` stay valid and the machine stays selected.
Envmgr never deletes the renamed checkout.

When `origin` already is `<url>`, `migrate` only records `data_url=`.

The old remote is never deleted.

#### `envmgr publish`

`publish` commits the active machine's directory, `machines/<id>/`, in the data
checkout and pushes it, so other machines can pull it with `restore`. Edits
made under `$HOME` reach it only after `envmgr save`; when config targets
have local changes, `publish` warns and continues.

1. Refuse unless the checkout is on the branch the machine's `git` provider
   entry for the data checkout tracks (`main` when there is none), has an
   `origin`, and has no rebase or merge in progress. Fetch that branch.
2. Stage `machines/<id>/` into a scratch copy of the index, which gives the
   preview: `git status --short` and `git diff --stat`, the commit message,
   unpushed earlier commits, and new commits on `origin`. Changes outside
   `machines/<id>/`, including another machine's directory, are listed in a
   warning and never committed; anything already staged there stays staged.
3. Refuse to commit a config source that looks like a plaintext secret: a
   non-encrypted source beside an encrypted one for the same target, a target
   name that `adopt config` requires `--encrypt` for, or a private key or age
   secret key in the content.
4. When `origin` has new commits, refuse before committing if earlier local
   commits change files outside `machines/<id>/`, or if tracked files outside
   it have uncommitted changes, because the rebase in step 6 would need them
   resolved by hand.
5. Confirm, then `git add -A` and `git commit -- machines/<id>/`. The default
   message is `Update <id>`, with one line per category listing changed
   config sources, package providers, and system units; `-m` replaces it.
6. Rebase onto `origin/<branch>` when it has new commits (machines edit
   separate directories, so this normally applies cleanly), then push. When
   the rebase conflicts, envmgr aborts it and exits `1`, leaving the commit
   local; the same happens when the push fails. Running `publish` again with
   nothing new to commit pushes earlier unpushed commits.

`--no-push` commits only, without fetching first if the network is down.
With nothing to commit and nothing to push, `publish` prints so and exits `0`.

## Configuration

`machines/<id>/config/` is an ordinary Chezmoi source directory. Envmgr calls
Chezmoi with an explicit `--source`, and keeps Chezmoi's default persistent
state, which records the last content written to each target.

- **Self-contained.** A template may reference Chezmoi built-ins (such as
  `.chezmoi.homeDir`) and files inside the same `config/` directory only.
- **No platform data.** There is no `.chezmoi.toml.tmpl`, no
  `[data.platform]`, and no platform-conditional `.chezmoiignore`.
- **Files only.** Allowed attributes are `dot_`, `private_`, `executable_`,
  `exact_`, `empty_`, `symlink_`, `modify_`, and `encrypted_`. Chezmoi `run_`
  scripts are not allowed; that work belongs in system units, and envmgr
  excludes scripts from every Chezmoi status, diff, and apply.
- **Partial ownership** uses `modify_` scripts. They must be deterministic and
  idempotent, and must preserve content they do not own. `exact_` is reserved
  for directories envmgr owns completely (for example, `~/.config/nvim`).

Commands:

- **`check config`** reads `chezmoi status`. Column one (last written state
  versus actual) is reported as **local changes**; column two (actual versus
  source) as **pending restore**. Both count as drift. When there are local
  changes, it adds a line pointing to `diff`, `save`, and `restore config`.
- **`diff [config] [target...]`** is read-only and shows each changed target:
  - a local change, as the diff from source to file (what `save` records);
  - a pending restore, as the diff from file to source (what `restore config`
    writes);
  - a target changed on both sides, as two diffs from the version Chezmoi
    last wrote: **changed here** and **changed in the source**, followed by
    the commands that keep either side. Chezmoi stores only that version's
    hash, so envmgr looks for it in the latest 100 data repository commits
    that changed the source file. When it is not there (a template, an
    encrypted or uncommitted source), `diff` says so and compares the source
    with the file.

  Encrypted targets are listed without their contents. Targets limit the
  output to those at or under them; each must be managed.

  `diff` and `save` cover only config. Like the other config commands, they
  take `config` as an optional first argument, so `save config <target>`
  works; a target named `config` in the current directory is then given as
  `./config`, as for `restore config`.
- **`list config`** prints targets and their kind: file, directory, symlink,
  `modify`, or encrypted.
- **`restore config [target...]`** previews the diff, then confirms and
  applies. Every existing file that restore will change is first copied to
  `~/.local/state/envmgr/backups/<timestamp>/`, whether or not Chezmoi wrote
  it before, except inside `exact_` directories. To restore an older version,
  check it out with Git first.
- **`adopt config [--exact] [--encrypt] target...`** runs `chezmoi add`. For
  a directory, this covers every regular file and symlink currently inside
  it; later files are not managed until adopted. `--exact` warns that
  unmanaged files will be deleted on restore. Partial ownership is authored
  as a `modify_` source, not adopted; adopting a target that a `modify_`
  source manages is refused. A managed file or symlink is refused with a
  pointer to `save`. For a managed directory, only the files and symlinks
  inside it that are not managed yet are added; `--exact` is refused there,
  because it applies when a directory is first adopted.
- **`save [config] [target...]`** copies local edits back into the source: the
  reverse of `restore config`. Without targets it covers every target with
  a local change (column one of `chezmoi status`); targets limit it to those
  at or under them, and each must be managed (otherwise it points to
  `adopt config`). It previews the diff from source to the current file
  (encrypted targets are listed by name only), confirms, and runs
  `chezmoi re-add`, which keeps each source's name, so encryption and
  attributes carry over; symlinks are updated with `chezmoi add`. It skips,
  with a warning and reason, any target that:
  - changed in the source too since Chezmoi last wrote it (the source's
    content no longer matches the hash in Chezmoi's persistent state, for
    example after a pull), because saving would discard that change. The
    warning points to `diff`, `save --force`, and `restore config`.
    `--force` saves such targets anyway; it requires targets, so it never
    discards a source change that was not named. To combine both sides, edit
    the file in `$HOME`, then save it with `--force`;
  - is a template or `modify_` source, which must be edited in the source;
  - was deleted, or changed type (file to symlink or back).

  A target whose source alone changed is a pending restore, not a local
  change, and is never saved. `save` does not commit; it ends by pointing
  to `envmgr publish`.
- **`adopt config --from <id> target...`** copies the sources that machine
  `<id>` has for the targets (every managed file at or under each one) into
  this machine's `config/`, with their names unchanged, so attributes carry
  over. Where this machine already has a source directory for an ancestor
  (for example `dot_config/` while the other machine has
  `private_dot_config/`), the file goes under the existing one. It refuses,
  and points to `envmgr evaluate --from <id> target...`, when any of the
  targets is already managed here or exists in `$HOME`, or when it would
  create an `exact_` directory whose target already exists. It does not
  restore or commit; it warns about copied templates (whose references must
  exist here) and about encrypted files when the age key is missing. It
  cannot be combined with `--exact` or `--encrypt`.
- **`drop config [--delete] target...`** runs `chezmoi forget`, which keeps
  local copies. With `--delete`, after confirmation, envmgr also deletes the
  managed files and then any managed directories left empty. Unmanaged files
  and their directories are never deleted. `--delete` is refused for a
  `modify_` target, which envmgr owns only in part.

## Packages

Envmgr does not support upgrading individual packages. This follows Arch's
policy that [partial upgrades are unsupported](https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported),
applied to every provider. The smallest unit of upgrade is a provider.

```text
envmgr check   package [provider]
envmgr list    package [provider]
envmgr restore package [provider]
envmgr adopt   package <provider> <package...>
envmgr drop    package [--delete] <provider> <package...>
```

- **`restore package [provider]`** installs missing declared packages and
  performs the provider's upgrade. With `--yes`, it runs without prompts
  where the provider allows. If package names are supplied, envmgr exits
  with code `2` and this message: `envmgr does not upgrade individual
  packages; see
  https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported`.
- **`check package [provider]`** (and any `check` that includes packages)
  refreshes the provider's metadata (for
  example, `brew update`, `git fetch`, or a temporary pacman database
  through `checkupdates`). It never changes installed state. It reports
  missing declared packages and pending upgrades, and both count as drift.
  `--offline` skips the metadata refresh. On Homebrew machines the marker is
  therefore usually set; it means `restore` will change something.
- **`adopt package`** records packages that are already installed in the
  provider's manifest, and refuses packages that are not installed.
- **`drop package`** removes packages from the manifest. With `--delete`,
  after confirmation, envmgr also uninstalls them.
- Packages missing from a manifest are never removed automatically.

#### Provider contract

| Operation | Meaning |
|---|---|
| `available` | The package manager exists. |
| `bootstrap` | Install the package manager itself; may return `75`. |
| `refresh` | Refresh metadata without changing installed state. |
| `list` | Declared packages, one per line, with an optional kind (for example, `held` or `cask`). |
| `missing` | Declared packages that are not installed. |
| `pending` | A short description of what an upgrade would change, or nothing. |
| `restore` | Install missing packages and perform the provider's upgrade; may return `75`. |
| `adopt <pkg...>` | Record installed packages in the manifest; refuse ones that are not installed. |
| `forget <pkg...>` | Remove packages from the manifest. |
| `uninstall <pkg...>` | Uninstall packages (`drop package --delete`). |

Providers live in `lib/envmgr/providers/<name>.sh` and run with
`ENVMGR_MANIFEST_DIR` set to `machines/<id>/packages/<provider>/`. A machine
uses a provider when that directory exists. `restore` bootstraps a provider
whose package manager is missing before restoring it.

Providers run in this order: `git`, `rpm-ostree`, `omarchy`, `homebrew`,
`flatpak`. `git` runs first so that the remaining providers, config, and
system phases use the freshly pulled tool and data.

| Provider | Manifests | Upgrade unit | Notes |
|---|---|---|---|
| `rpm-ostree` | `packages` | Whole deployment (`rpm-ostree install --idempotent` for missing packages, then `rpm-ostree upgrade`, both staged into one pending deployment) | Returns `75` after staging. While a staged deployment is waiting for a reboot, restore stages nothing more and returns `75` again. Pending updates come from `rpm-ostree upgrade --check`. `drop --delete` runs `rpm-ostree uninstall`, which also needs a reboot. |
| `omarchy` | `packages`, `aur`, `plugins` (`id url [position]`) | Whole system (`omarchy update`) | Runs `omarchy update` in the foreground when an update is pending, so the user answers its prompts. With `--yes`, envmgr stops before it with an error asking to rerun without `--yes`. Then runs `omarchy pkg add`, `omarchy pkg aur add`, and `omarchy plugin add/enable`. `adopt` sends packages listed by `pacman -Qm` to `aur`. Pending updates come from `checkupdates` (pacman-contrib) and are cached for offline checks. |
| `homebrew` | `Brewfile` (formulae, casks, taps, `mas`), `hold`, optional `trusted-taps` | Declared entries: `brew bundle install --no-upgrade` installs missing entries, then declared outdated formulae and casks are upgraded | Taps in `trusted-taps` are tapped and passed to `brew trust` first. Formulae in `hold` are installed when missing and never upgraded (for example, Kanata HEAD, whose rebuild breaks macOS privacy grants). Removes group/other write permission from `$(brew --prefix)/share`. `adopt` records installed formulae and casks; taps and `mas` entries are added to the `Brewfile` by hand. |
| `flatpak` | `apps`, `remotes` (`name url`) | Declared apps and their runtimes (`flatpak update --user`) | User scope only. Missing apps install from the first remote listed in `remotes`. Updates are limited to declared apps; undeclared apps are ignored. Pending updates are cached for offline checks. |
| `git` | `repos` (`url path [branch]`, branch defaults to `main`; `~/` allowed) | Each repository (`git fetch`, then `git merge --ff-only`) | Clones missing repositories. A checkout is pending only when `origin/<branch>` has commits it lacks. Restore skips, with a warning, a checkout that is on another branch, has uncommitted changes, or has unpushed commits. Every machine lists the tool checkout and the `envmgr-data` checkout here. `adopt` takes checkout paths and records each one's `origin` URL and current branch. `drop --delete` is refused; envmgr never deletes checkouts. |

## System units

```text
machines/<id>/system/
  50-kanata/
    apply        # required: idempotent, may sudo, may exit 75
    check        # optional: read-only; 0 in sync, 3 drift, 1 error
    files/       # udev rules, launchd/systemd units, helpers
  90-hyprland-reload/
    apply
    watch        # optional: targets whose changes re-run a stamp unit
```

- Units run in lexical order of their directory names. Envmgr runs `apply`
  and `check` from the unit directory and sets `ENVMGR_UNIT_DIR`,
  `ENVMGR_MACHINE_DIR`, `ENVMGR_DATA_DIR`, and `ENVMGR_MACHINE`. Both scripts
  must be executable.
- The first comment line of `apply` after the shebang is the unit's
  description. `list system` shows each unit, whether it uses a `check`
  script or a stamp, and its description.
- A unit argument may name the directory (`90-hyprland-reload`) or omit the
  two-digit prefix (`hyprland-reload`).
- **`check system`** runs each unit's `check`. Any exit code other than `0`
  or `3` is an error, which makes `check` exit `1`. A unit without a `check`
  script uses a stamp: it is in sync when a hash of every file in the unit
  directory, plus the current contents of the targets listed in its `watch`
  file, matches `~/.local/state/envmgr/system/<machine>/<unit>.applied`.
  `watch` holds one path per line; `~/` and globs are expanded. Stamps fit
  actions such as reloads and preference scripts, which only need to run
  again after their inputs change.
- **`restore system [unit...] [--force]`** runs `apply`, in order, for the
  selected units that are out of sync, or for every selected unit with
  `--force`. After a successful `apply` it writes the stamp. A unit that
  exits `75` stops the run (the remaining units run on the next restore);
  any other failure stops the run with exit `1`.
- Units never prompt, apart from `sudo`. Interactive choices, such as Kanata
  keyboard selection, are made in the machine's files directly or through
  `evaluate`.
- There is no `adopt` or `drop` for units. Units are authored as files.

## Change summary

`$XDG_STATE_HOME/envmgr/change_summary` exists only while there is drift or
an error. It is rebuilt atomically from the per-category results in
`check/` after every `check`, which re-checks every category (the ones not
requested silently, with packages offline), and after every `restore`,
`adopt`, and `drop` (except with `--dry-run`), which re-check all categories
offline.

```text
machine=mac-mini
checked=2026-11-14T15:40:00Z
config.local=2
config.pending=1
package.missing=0
package.pending=homebrew,flatpak
package.errors=0
system.drift=1
system.errors=0
```

## `evaluate [category]`

`evaluate [category] [--offline]` runs `envmgr check` for the selected
categories, then replaces itself with the `agent=` command, run from the data
repository root, with one appended argument: the initial prompt. The command
is split on whitespace (quotes are not interpreted), and `evaluate` exits
with the agent's exit code. The prompt contains:

- the machine ID and the paths to `machine.conf`, `SPEC.md`,
  `POSTINSTALL.md`, the data repository's `AGENTS.md`, and this `DESIGN.md`;
- current `check` output for the selected categories, as paths and statuses,
  never file contents; that `envmgr diff` shows local config changes, which
  are kept with `envmgr save` or discarded with `envmgr restore config`; and
  that the agent leaves the source of a target with a local change alone
  until the user has done one or the other, because the target would then
  be changed on both sides and `restore` would overwrite the local edit;
- the approval boundary: the agent may edit `machines/<id>/` and repository
  documentation. It must not run `envmgr restore`, install packages, or
  commit, and it ends by pointing the user to `envmgr save` (for local
  changes they keep), then `envmgr restore`, then `envmgr publish`.

Without an `agent=` setting, or when its command is not on `PATH`,
`evaluate` exits `1` with instructions.

`evaluate --from <id> [target...] [--offline]` starts the agent to copy
configuration from another machine to the selected one. (When none of the
targets exist here yet, `adopt config --from` copies them without an
agent.) Run it on the machine that receives the files, so the agent can
look at the targets that already exist there and `envmgr publish` commits
the right directory afterward.

1. Unless `--offline` is given, fetch the data checkout and fast-forward it
   when it is clean, on the expected branch, and fully pushed (the same rule
   as the `git` provider), so the comparison sees the latest files from the
   other machine. Otherwise warn and compare the files already there.
2. Compare the two machines' config sources by target, using `chezmoi
   managed` and `chezmoi source-path` on each `config/` directory. Each
   target is reported, with the source paths on each side, as **only there**
   (a candidate to copy), **different** (sources differ in name or content; a
   candidate to merge or replace), or **only here** (context only). Targets
   with identical sources are omitted. Target arguments limit the comparison
   to targets at or under them. Encrypted sources are compared as ciphertext.
3. When nothing is only there or different, print so and exit `0` without
   starting the agent.
4. Otherwise start the agent as above. The prompt holds both machine IDs,
   both `machine.conf` paths (so the agent can check an OS or distribution
   difference), the comparison (paths only, never contents), and whether the
   age key exists on this machine. The agent may read `machines/<from>/` but
   edits only `machines/<id>/`; it keeps source names so attributes carry
   over, copies `encrypted_` sources byte for byte without decrypting them,
   may read existing targets under `~` to merge them (except files that look
   like secrets), asks the user to save or discard a local change before
   changing that target's source, proposes deleting an only-here target only
   when asked, and
   never restores or commits. It ends by pointing the user to
   `envmgr restore config --dry-run`, `envmgr restore config`, and
   `envmgr publish`.

## Secrets

- Files are unmanaged until adopted, including secret files.
- Secret-bearing files may be adopted only with `--encrypt` (Chezmoi age
  encryption), so `envmgr-data` holds only ciphertext. The age identity lives
  at `~/.config/envmgr/age.key` (mode `600`) and is never committed.
- The first `adopt config --encrypt` creates the key with `chezmoi
  age-keygen` when it is missing, and asks the user to back it up and copy
  it to every machine that restores the encrypted files. Chezmoi's built-in
  age is used, so no `age` binary is needed.
- The envmgr-managed `chezmoi.toml` always sets `encryption = "age"`, so
  encrypted targets keep their names even without a key: after a key is
  lost, `list config` shows them and `drop config [--delete]` removes them,
  after which `check` and `restore` work again. When the key exists, it also
  sets the `[age]` identity and recipient. Before any
  command that decrypts (`check config`, `restore config`, `adopt config
  --encrypt`), envmgr adds those settings if the key was copied in after
  `init`, and fails with instructions if the machine has `encrypted_` files
  but no key.
- The age key itself cannot be adopted.
- `adopt config` refuses plaintext files that match common secret patterns
  (private keys, `*token*`, `.netrc`, `credentials`, and similar names), in
  addition to Chezmoi's own secret detection.
- `evaluate` never decrypts files and never includes target contents in its
  prompt.

## Out of scope

- Scheduled checks and notifications. External tools can run `envmgr check`
  or watch `change_summary`.
- Automatic configuration layering, merging, or cross-machine inheritance.
- Automatic removal of undeclared packages.
- Upgrading individual packages.

## Decisions

| # | Decision | Date |
|---|---|---|
| 1 | Separate public `unnamed-envmgr` (tool) and private `envmgr-data` (data); the legacy `envmgr` repository is kept until the user deletes it | 2026-11-14 |
| 2 | Setup outside `$HOME` lives in a third category, `system`, with per-unit `check`/`apply` | 2026-11-14 |
| 3 | No per-package upgrades on any provider; restore performs each provider's whole upgrade, including `omarchy update` and `rpm-ostree upgrade` | 2026-11-14 |
| 4 | Pending upgrades count as drift in `change_summary` | 2026-11-14 |
| 5 | The tool updates itself through a `git` provider entry tracking `main` | 2026-11-14 |
| 6 | `envmgr migrate` relocates the whole data repository with its history | 2026-11-14 |
| 7 | Legacy conversion is `legacy-export.sh` in the legacy repository | 2026-11-14 |
| 8 | Tool at `~/.local/share/unnamed-envmgr`, data at `~/Work/Git/envmgr-data` | 2026-11-14 |
| 9 | Guided SSH setup without `gh` | 2026-11-14 |
| 10 | `envmgr-data` is a `git` entry; restore fast-forwards it when clean | 2026-11-14 |
| 11 | Restore runs `omarchy update` interactively; `--yes` stops before it | 2026-11-14 |
| 12 | Units without `check` use stamps (unit hash plus `watch` targets) | 2026-11-14 |
| 13 | `check` refreshes metadata online by default; `--offline` skips | 2026-11-14 |
| 14 | Secrets only through Chezmoi age encryption | 2026-11-14 |
| 15 | Agent invoked as a command with the prompt appended as the last argument | 2026-11-14 |
| 16 | `migrate` pushes `origin`'s branches and tags instead of `--mirror` | 2026-11-14 |
| 17 | One age key per user, created by the first `adopt config --encrypt` and copied by hand or pasted into setup, which checks it decrypts the machine's files; setup never generates one | 2026-11-14 |
| 18 | `migrate --no-history` pushes one root commit; checkouts that cannot follow are renamed and re-cloned, never deleted | 2026-11-14 |
| 19 | `publish` commits only the active machine's directory and pushes it, rebasing onto `origin` when the local commits stay inside that directory; envmgr otherwise never commits | 2026-11-14 |
| 20 | Copying configuration between machines that needs judgement (existing targets, merges) goes through `evaluate --from`, run on the receiving machine, with a deterministic comparison in the prompt | 2026-11-14 |
| 21 | `adopt config --from` copies sources only for targets that do not exist on this machine; anything else is sent to `evaluate --from` | 2026-11-14 |
| 22 | A new machine starts from one OS-neutral command, `install.sh` piped from GitHub, which only makes Git usable, clones the tool, and starts `setup`; a machine is based on an existing machine with the same `os` and `distribution`, or starts empty | 2026-11-14 |
| 23 | `setup` carries on through `publish` and `restore`, so the one command leaves the machine configured; after a reboot or error, rerunning `setup` resumes | 2026-11-14 |
| 24 | envmgr's own dependencies are declared like any other package: `setup` adopts `git` and `chezmoi` with the provider that installed them, unless the system provides them, and an empty machine starts with the tool and data checkouts in `git/repos` | 2026-11-15 |
| 25 | Local edits reach the source through `save` (only targets whose source is unchanged since Chezmoi last wrote them); committing and pushing is `publish`, formerly `save`; `adopt` only starts managing targets | 2026-11-17 |
| 26 | `diff` shows a target changed on both sides as each side's change from the version Chezmoi last wrote, found in the data repository's history by hash; envmgr does not merge, and `save --force` keeps this machine's version only for named targets | 2026-11-17 |
| 27 | `diff` and `save` take `config` as an optional first argument, matching `restore`, `adopt`, and `drop`; other categories are usage errors | 2026-11-18 |
| 28 | `evaluate` agents leave the source of a target with a local change alone until the user saves or discards it, so no target becomes changed on both sides through the agent | 2026-11-18 |
| 29 | `setup` has no built-in data repository URL; it offers the saved `data_url` or `ENVMGR_DATA_URL` as the default | 2026-11-21 |
