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
| `unnamed-envmgr` | Public | The tool only: `bin/envmgr`, `lib/envmgr/`, tests, `README.md` (first-run walkthrough), `DESIGN.md`, `AGENTS.md`. Cloned over HTTPS; no `gh` or credentials needed. |
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
  data_url=git@github.com:juyanith/envmgr-data.git
  machine=mac-mini
  agent=codex
~/.local/state/envmgr/            # $XDG_STATE_HOME/envmgr
  change_summary
  system/<machine>/<unit>.applied # stamps for units without a check script
  backups/<timestamp>/...
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

- `os` and `distribution` are required. Commands that change the system
  (`restore`, `adopt`, `drop`) refuse to run when they do not match the
  running system. `check`, `list`, and `evaluate` warn and continue.
- A mismatch in the optional `architecture` field produces a warning.
- Hardware is not a dimension. Hardware-specific settings live in the files
  of the machines that need them.
- Machine IDs are chosen names, not hostnames.

## General command rules

```text
envmgr setup
envmgr init <id> | init --new <id> [--from <id>]
envmgr check   [config|package|system]
envmgr list    [config|package|system]
envmgr restore [config|package|system] [...]
envmgr adopt   config|package ...
envmgr drop    config|package ...
envmgr evaluate [config|package|system]
envmgr migrate <url> | migrate --follow <url>
```

- Every command acts on the active machine from `~/.config/envmgr/config`.
  If no machine is configured, the command exits with an error that suggests
  `envmgr setup` or `envmgr init`.
- With no category, `check`, `list`, `restore`, and `evaluate` cover all
  three. `restore` always runs in the order package → config → system,
  because configuration and units depend on installed tools, and units may
  read restored targets. A phase that ends with `75` stops the run.
- Commands that change the system print a preview and ask for confirmation.
  `--yes` skips confirmation; `--dry-run` prints the preview and exits.
- Exit codes: `0` success or in sync; `1` error; `2` usage error; `3` check
  found drift; `75` reboot or re-login required before continuing.
- Envmgr never commits or pushes. It pulls only through the `git` provider
  (fast-forward only, clean checkouts only), and pushes only in `migrate`.
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

The `unnamed-envmgr` README directs a new user to:

```sh
git clone https://github.com/juyanith/unnamed-envmgr ~/.local/share/unnamed-envmgr
~/.local/share/unnamed-envmgr/bin/envmgr setup
```

`setup` is interactive and idempotent. It skips steps that are already
complete:

1. **Prerequisites.** Install Git and Chezmoi with the platform's native
   method (Xcode Command Line Tools and Homebrew on macOS, `omarchy pkg add`
   on Omarchy, a Homebrew bootstrap on Fedora Atomic, which may return `75`).
   Link `~/.local/bin/envmgr`.
2. **SSH.** If no key exists, create `~/.ssh/id_ed25519` (with a passphrase
   prompt). Print the public key, open
   `https://github.com/settings/ssh/new`, and wait for confirmation. Verify
   access with `ssh -T git@github.com`. Does not use `gh`.
3. **Data repository.** Ask for the URL (default
   `git@github.com:juyanith/envmgr-data.git`) and checkout path (default
   `~/Work/Git/envmgr-data`), then clone.
4. **Machine.** Offer the existing machines whose `os`/`distribution` match
   the running system, a new machine (optionally copied from one of them), or
   skip (used during legacy migration). Selecting a machine runs
   `envmgr init`.
5. **Agent.** Optionally record the agent command for `evaluate`.

#### `envmgr init`

- `init <id>` writes `machine=` to `~/.config/envmgr/config` and sets
  `sourceDir` in `~/.config/chezmoi/chezmoi.toml`, after checking
  `machine.conf`. It changes no targets, packages, or system state; run
  `envmgr restore` next.
- `init --new <id> [--from <id>]` creates `machines/<id>/` with detected
  metadata and an empty `config/`, `packages/`, `system/`, and `SPEC.md`.
  With `--from`, it copies those directories from another machine with the
  same `os` and `distribution`. Copies are owned independently from then on.

#### `envmgr migrate`

`migrate` moves the whole data repository, with its history, to a new remote:

1. Check that the data checkout is clean, all local branches are pushed, and
   the new remote is empty.
2. Run `git push --mirror <url>`.
3. Run `git remote set-url origin <url>`, and update `data_url=`.
4. Update any git-provider entries that reference the old URL in every
   machine's manifests, and leave those edits uncommitted for review.
5. Print the follow-up step for other machines: `envmgr migrate --follow
   <url>` only changes `origin` and `data_url=` after verifying that the new
   remote contains the current `HEAD`.

The old remote is never deleted.

## Configuration

`machines/<id>/config/` is an ordinary Chezmoi source directory. Envmgr calls
Chezmoi with an explicit `--source`, and keeps Chezmoi's default persistent
state, which records the last content written to each target.

- **Self-contained.** A template may reference Chezmoi built-ins (such as
  `.chezmoi.homeDir`) and files inside the same `config/` directory only.
- **No platform data.** There is no `.chezmoi.toml.tmpl`, no
  `[data.platform]`, and no platform-conditional `.chezmoiignore`.
- **Files only.** Allowed attributes are `dot_`, `private_`, `executable_`,
  `exact_`, `empty_`, `modify_`, and `encrypted_`. Chezmoi `run_` scripts are
  not allowed; that work belongs in system units.
- **Partial ownership** uses `modify_` scripts. They must be deterministic and
  idempotent, and must preserve content they do not own. `exact_` is reserved
  for directories envmgr owns completely (for example, `~/.config/nvim`).

Commands:

- **`check config`** reads `chezmoi status`. Column one (last written state
  versus actual) is reported as **local changes**; column two (actual versus
  source) as **pending restore**. Both count as drift.
- **`list config`** prints targets and their kind: file, directory, `modify`,
  or encrypted.
- **`restore config [target...]`** previews the diff, then confirms and
  applies. Every existing file that restore will change is first copied to
  `~/.local/state/envmgr/backups/<timestamp>/`, whether or not Chezmoi wrote
  it before, except inside `exact_` directories. To restore an older version,
  check it out with Git first.
- **`adopt config [--exact] [--encrypt] target...`** runs `chezmoi add`. For
  a directory, this covers every regular file and symlink currently inside
  it; later files are not managed until adopted. `--exact` warns that
  unmanaged files will be deleted on restore. Partial ownership is authored
  as a `modify_` source, not adopted.
- **`drop config [--delete] target...`** runs `chezmoi forget`, which keeps
  local copies. With `--delete`, after confirmation, envmgr also deletes the
  managed files and then any managed directories left empty. Unmanaged files
  and their directories are never deleted.

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
| `missing` | Declared packages that are not installed. |
| `pending` | A short description of what an upgrade would change, or nothing. |
| `restore` | Install missing packages and perform the provider's upgrade; may return `75`. |
| `adopt <pkg...>` / `uninstall <pkg...>` | Record or remove specific packages. |

Providers run in this order: `git`, `rpm-ostree`, `omarchy`, `homebrew`,
`flatpak`. `git` runs first so that the remaining providers, config, and
system phases use the freshly pulled tool and data.

| Provider | Manifests | Upgrade unit | Notes |
|---|---|---|---|
| `rpm-ostree` | `packages` | Whole deployment (`rpm-ostree upgrade`, plus layering missing packages in the same transaction) | Returns `75` when a deployment is staged. |
| `omarchy` | `packages`, `aur`, `plugins` (`id url [position]`) | Whole system (`omarchy update`) | Runs `omarchy update` in the foreground when an update is pending, so the user answers its prompts. With `--yes`, envmgr stops before it with an error asking to rerun without `--yes`. Then runs `omarchy pkg add`, `omarchy pkg aur add`, and `omarchy plugin add/enable`. `adopt` sends packages listed by `pacman -Qm` to `aur`. |
| `homebrew` | `Brewfile` (formulae, casks, taps, `mas`), `hold`, optional `trusted-taps` | Declared entries: `brew bundle install --no-upgrade` installs missing entries, then declared outdated formulae and casks are upgraded | Taps in `trusted-taps` are tapped and passed to `brew trust` first. Formulae in `hold` are installed when missing and never upgraded (for example, Kanata HEAD, whose rebuild breaks macOS privacy grants). Removes group/other write permission from `$(brew --prefix)/share`. |
| `flatpak` | `apps`, `remotes` (`name url`) | Declared apps and their runtimes (`flatpak update --user`) | User scope only. |
| `git` | `repos` (`url path [branch]`, branch defaults to `main`; `~/` allowed) | Each repository (`git fetch`, then `git merge --ff-only`) | Clones missing repositories. A checkout is pending only when `origin/<branch>` has commits it lacks. Restore skips, with a warning, a checkout that is on another branch, has uncommitted changes, or has unpushed commits. Every machine lists the tool checkout and the `envmgr-data` checkout here. `drop --delete` is refused; envmgr never deletes checkouts. |

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
  description, shown by `list system`.
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

`$XDG_STATE_HOME/envmgr/change_summary` exists only while there is drift. It
is written atomically after every `check`, which refreshes all categories'
entries. A category not requested in that run reuses its result from within
the last 10 minutes when nothing it depends on has changed, and is otherwise
re-checked offline.

```text
machine=mac-mini
checked=2026-11-14T15:40:00Z
config.local=2
config.pending=1
package.missing=0
package.pending=homebrew,flatpak
system.drift=1
```

## `evaluate [category]`

`evaluate` runs the `agent=` command from the data repository root, with one
appended argument: the initial prompt. The prompt contains:

- the machine ID and the paths to `machine.conf`, `SPEC.md`, and the data
  repository's `AGENTS.md`;
- current `check` output for the selected categories, as paths and statuses,
  never file contents;
- the approval boundary: the agent may edit `machines/<id>/` and repository
  documentation. It must not run `envmgr restore`, install packages, or
  commit.

## Secrets

- Files are unmanaged until adopted, including secret files.
- Secret-bearing files may be adopted only with `--encrypt` (Chezmoi age
  encryption), so `envmgr-data` holds only ciphertext. The age identity lives
  at `~/.config/envmgr/age.key` and is never committed.
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
