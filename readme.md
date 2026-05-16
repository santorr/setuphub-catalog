# SetupHub Catalog

Backend catalog for SetupHub.

This repository contains the list of applications displayed by SetupHub, including their `winget` identifiers, categories, tags, descriptions, and icons. It is intentionally static: the client application can consume it directly through a CDN without requiring a dedicated backend service.

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

`packages.json` is an array of applications. Each top-level entry must contain:

| Field | Type | Description |
| --- | --- | --- |
| `name` | string | Display name used by SetupHub. |
| `package_id` | string | Package identifier in `winget`. For entries without `variants`, this identifier must be directly installable. |
| `icon` | string | File name inside `icons/`. |
| `category` | string | Functional category for the application. |
| `description` | string | Short description shown in the UI. |
| `tags` | string[] | Keywords used for search and filtering. |
| `variants` | object[] | Optional. Installable variants with their own `package_id`. |

When an entry contains `variants`, its top-level `package_id` may be used as a catalog grouping identifier. In that case, CI validates the variant `package_id` values because they represent the installable choices shown to the user.

Example:

```json
{
  "name": "VLC",
  "package_id": "VideoLAN.VLC",
  "icon": "vlc.png",
  "category": "Media",
  "description": "Open-source multimedia player",
  "tags": ["Video", "Audio", "Media", "Player"]
}
```

Example with variants:

```json
{
  "name": "Python",
  "package_id": "Python.Python",
  "icon": "python.png",
  "category": "Development",
  "description": "Powerful programming language",
  "tags": ["Programming", "Scripting", "Development"],
  "variants": [
    { "name": "Python 3.12", "package_id": "Python.Python.3.12" },
    { "name": "Python 3.13", "package_id": "Python.Python.3.13" }
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
- there are no duplicate `package_id` values;
- variants contain both `name` and `package_id`;
- every installable `package_id` can still be resolved by `winget`.

The `winget` validation does not install anything. It uses `winget show` to verify that the package still exists in the configured sources. For entries with variants, the parent entry is not checked with `winget show`; only the variants are checked.

## CI

The GitHub Actions workflow `.github/workflows/catalog-check.yml` runs the validation on `windows-latest`:

- on every push that changes the catalog, icons, script, or workflow;
- on pull requests touching those same files;
- once a week, to detect packages that were removed or renamed in `winget`;
- manually through `workflow_dispatch`.

This helps SetupHub avoid offering broken installers: if a `winget` identifier stops resolving, CI reports it before the client application surfaces a dead install option.
