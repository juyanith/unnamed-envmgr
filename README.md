# unnamed-envmgr

Envmgr restores a machine's configuration files, packages, and system setup
from a private data repository, and reports when the machine has drifted from
it. See [DESIGN.md](DESIGN.md) for the full specification.

**Status:** early development. Implemented so far: `init`, `check config`, and
`list config`. `setup`, `restore`, `adopt`, `drop`, `evaluate`, `migrate`, the
package providers, and system units are not implemented yet.

## Requirements

- macOS, Omarchy, or Fedora COSMIC Atomic
- Bash 3.2 or newer, Git, and [Chezmoi](https://www.chezmoi.io/)
- A data repository with a `machines/` directory (see DESIGN.md)

## Try it with an existing data checkout

```sh
git clone https://github.com/juyanith/unnamed-envmgr ~/.local/share/unnamed-envmgr
ln -s ../share/unnamed-envmgr/bin/envmgr ~/.local/bin/envmgr
envmgr init --data ~/Work/Git/envmgr-data <machine-id>
envmgr check
envmgr list config
```

`envmgr check` exits `0` when the machine is in sync and `3` when it found
drift. While drift remains, `~/.local/state/envmgr/change_summary` exists.

## Development

```sh
tests/run.sh             # runs every test under /bin/bash and bash on PATH
```

The tests need `chezmoi` on `PATH` and use a temporary `HOME`.
