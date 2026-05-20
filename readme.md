# SetupHub Catalog

Backend catalog for SetupHub.

This repository contains the list of applications displayed by SetupHub,
including provider installer identifiers, categories, tags, descriptions, and
icons. It is intentionally static: the client application can consume it
directly through a CDN without requiring a dedicated backend service.

## Public URLs

The catalog is published through GitHub and can be served by jsDelivr.

- JSON catalog: <https://cdn.jsdelivr.net/gh/santorr/setuphub-catalog@main/packages.json>
- Icon example: <https://cdn.jsdelivr.net/gh/santorr/setuphub-catalog@main/icons/chrome.png>
- jsDelivr GitHub entry point: <https://www.jsdelivr.com/github>

To avoid aggressive jsDelivr caching during development, replace `@main` with a specific branch, tag, or commit.

## Structure

```text
setuphub-catalog/
|-- packages.json
|-- icons/
|   |-- chrome.png
|   `-- ...
|-- scripts/
|   `-- Test-Catalog.ps1
`-- .github/
    `-- workflows/
        `-- catalog-check.yml
```

## Catalog Format

`packages.json` is a single application catalog. Keep one top-level entry per
application and put every installable provider choice in `installers`. This
keeps shared metadata, icons, categories, and descriptions in one place even
when an application can later be installed from Winget, Microsoft Store, Steam,
or another provider.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string | Display name used by SetupHub. |
| `id` | string | Stable SetupHub catalog identifier. This is not sent to a package manager. |
| `icon` | string | File name inside `icons/`. |
| `category` | string | Functional category for the application. |
| `description` | string | Short description shown in the UI. |
| `tags` | string[] | Keywords used for search and filtering. |
| `installers` | object[] | Installable choices. Each installer has a `source` and a provider-specific `package_id`. |

Supported installer sources are currently `winget`, `msstore`, and `steam`.
SetupHub can execute `winget` today; the other sources are reserved for future
provider integrations and are validated structurally only.

Installers can declare `dependencies` when another installer must be present in
the setup first. Each dependency uses the same provider-scoped identity:
`source + package_id`. Dependencies must reference an installer that already
exists somewhere in the catalog.

Example:

```json
{
  "id": "vlc",
  "name": "VLC",
  "icon": "vlc.png",
  "category": "Media",
  "description": "Open-source multimedia player",
  "tags": ["Video", "Audio", "Media", "Player"],
  "installers": [
    {
      "source": "winget",
      "package_id": "VideoLAN.VLC"
    }
  ]
}
```

Example with a dependency:

```json
{
  "id": "counter-strike-2",
  "name": "Counter-Strike 2",
  "icon": "default.png",
  "category": "Gaming",
  "description": "Competitive tactical shooter on Steam",
  "tags": ["Game", "FPS", "Steam"],
  "installers": [
    {
      "name": "Counter-Strike 2",
      "source": "steam",
      "package_id": "730",
      "dependencies": [
        {
          "name": "Steam",
          "source": "winget",
          "package_id": "Valve.Steam"
        }
      ]
    }
  ]
}
```

Example with grouped installers:

```json
{
  "id": "python",
  "name": "Python",
  "icon": "python.png",
  "category": "Development",
  "description": "Powerful programming language",
  "tags": ["Programming", "Scripting", "Development"],
  "installers": [
    {
      "name": "Python 3.12",
      "source": "winget",
      "package_id": "Python.Python.3.12"
    },
    {
      "name": "Python 3.13",
      "source": "winget",
      "package_id": "Python.Python.3.13"
    }
  ]
}
```

## Add an Application

1. Check the exact identifier with `winget show --id <Package.Id> --exact`.
2. Add the entry to `packages.json`.
3. Add the matching PNG icon to `icons/`.
4. Run the local validation.

```powershell
pwsh ./scripts/Test-Catalog.ps1
```

The equivalent command for Windows PowerShell is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/Test-Catalog.ps1
```

If `winget` is not available on the machine, the structure-only validation can still be run:

```powershell
pwsh ./scripts/Test-Catalog.ps1 -SkipWinget
```

Or with Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/Test-Catalog.ps1 -SkipWinget
```

## Validation

`scripts/Test-Catalog.ps1` checks that:

- `packages.json` is valid JSON;
- every entry contains the required fields;
- every referenced icon exists in `icons/`;
- there are no duplicate `source + package_id` installer pairs;
- every dependency references an installer present in the catalog;
- grouped installers contain both `name` and `package_id`;
- every `winget` installer can still be resolved by the local Winget index.

The `winget` validation does not install anything. It reads the local Winget
SQLite source index once, then checks every catalog Winget identifier against
that in-memory list. Non-Winget sources are skipped by this resolver until their
provider integrations exist.

## CI

The GitHub Actions workflow `.github/workflows/catalog-check.yml` runs the validation on `windows-latest`:

- on every push that changes the catalog, icons, script, or workflow;
- on pull requests touching those same files;
- once a week, to detect packages that were removed or renamed in `winget`;
- manually through `workflow_dispatch`.

This helps SetupHub avoid offering broken installers: if a `winget` identifier stops resolving, CI reports it before the client application surfaces a dead install option.
