# env-configurer

Module-based machine provisioning via git.

Manages addons defined by `.configurer.yml` manifests. Addons declare a name,
version, entrypoint command, optional source URL, and dependencies.

## Install

Run this in a Command Prompt or PowerShell to download `configurer.bat` and
make it available anywhere on your machine:

```cmd
md "%USERPROFILE%\bin" 2>nul & curl -fsSL https://raw.githubusercontent.com/antenia-lhubert/env-configurer/main/configurer.bat -o "%USERPROFILE%\bin\configurer.bat" & setx PATH "%PATH%;%USERPROFILE%\bin"
```

After running, open a new terminal and use `configurer` from any directory.

## Usage

```
configurer install <target>
configurer run <target> [args...]
configurer update [name]
configurer ls
configurer uninstall <name>
```

### Subcommands

| Command | Description |
|---------|-------------|
| `install <target>` | Install an addon and its dependencies |
| `run <target> [args...]` | Run an addon's entrypoint, passing remaining args through |
| `update [name]` | Update one or all installed addons (skips if already current) |
| `ls` | List installed addons with versions |
| `uninstall <name>` | Remove an installed addon |

### Target Resolution

Targets are resolved in this order:

1. **GitHub subpath URL** - e.g. `https://github.com/org/repo/tree/main/my-addon`
2. **Git URL** - any URL containing `://` or ending with `.git`
3. **Local directory** - an existing path on disk
4. **Installed addon name** (run only) - looked up from the addon store
5. **Official repo fallback** - clones the official mono-repo and looks for `<name>/` at root

### Global Flags

| Flag | Description |
|------|-------------|
| `--no-update` | Skip the self-update check (can appear anywhere in args) |

## .configurer.yml

Every addon must have a `.configurer.yml` at its root:

```yaml
apiVersion: 1
name: my-addon
version: 1.0.0
entrypoint: powershell -NoProfile -ExecutionPolicy Bypass -File main.ps1
source: https://github.com/org/addons/tree/main/my-addon
dependencies:
  - core-utils
  - network-tools@2.0.0
```

| Field | Required | Description |
|-------|----------|-------------|
| `apiVersion` | Yes | Must be `1` |
| `name` | Yes | Addon identity (used as folder name in the addon store) |
| `version` | Yes | Semantic version (used for dependency constraints and updates) |
| `entrypoint` | Yes | Command string executed via `cmd /c` with CWD set to addon root |
| `source` | No | Where to fetch updates from (same resolution logic as targets) |
| `dependencies` | No | List of `name` or `name@min_version` entries |

## Dependencies

- Dependencies are resolved transitively (deps of deps)
- Cycle-safe via visited-set tracking (silently skips already-processed addons)
- On `install`: missing deps are auto-installed after the addon itself
- On `run`: missing deps are auto-installed before execution
- Version constraints use semver comparison (`>=`); if an installed dep is below the required minimum, it is re-fetched from its `source` field (or the official repo)

## Addon Store

Installed addons are stored at:

```
%USERPROFILE%\.config\configurer\installed\<name>\
```

## Command Shims

When an addon is installed, a shim `.bat` file is automatically created at:

```
%USERPROFILE%\.config\configurer\commands\<name>.bat
```

This allows calling any installed addon directly by name from any terminal:

```cmd
:: Instead of:
configurer run my-addon --verbose

:: You can just type:
my-addon --verbose
```

On first install, the `commands` directory is added to the user's PATH automatically (requires a terminal restart to take effect). On uninstall, the corresponding shim is removed.

## Examples

```cmd
:: Install from a local path
configurer install C:\projects\my-addon

:: Install from a GitHub repo subpath
configurer install https://github.com/org/addons/tree/main/my-addon

:: Install by name (resolved from official repo)
configurer install my-addon

:: Run an installed addon with arguments
configurer run my-addon --verbose --target=prod

:: Update all installed addons
configurer update

:: Update a specific addon
configurer update my-addon

:: List installed addons
configurer ls

:: Remove an addon
configurer uninstall my-addon

:: Call an installed addon directly (via command shim)
my-addon --verbose --target=prod
```

## How It Works

1. **Self-update** - checks GitHub for a newer version of configurer.bat and restarts if found
2. **Ensure git** - installs `git` via `winget` if not already in PATH
3. **Resolve target** - GitHub subpath, git URL, local path, installed name, or official repo
4. **Validate manifest** - parses `.configurer.yml`, checks `apiVersion`, required fields
5. **Install/Run** - copies to addon store (install) or executes entrypoint (run)
6. **Create command shim** - writes a `.bat` shim so the addon is callable by name
7. **Ensure PATH** - adds the commands directory to the user's PATH if not already present
8. **Resolve dependencies** - recursively installs/updates any missing or outdated deps
