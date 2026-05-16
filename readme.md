# SetupHub Catalog

Catalogue backend de SetupHub.

Ce depot contient la liste des applications affichees par SetupHub, avec leurs identifiants `winget`, leurs categories, leurs tags et leurs icones. Il est volontairement statique : l'application cliente peut le consommer directement via CDN sans serveur applicatif dedie.

## URLs publiques

Le catalogue est publie automatiquement par GitHub et peut etre servi par jsDelivr.

- Catalogue JSON : <https://cdn.jsdelivr.net/gh/santorr/setuphub-catalog@main/packages.json>
- Exemple d'icone : <https://cdn.jsdelivr.net/gh/santorr/setuphub-catalog@main/icons/chrome.png>
- Racine jsDelivr : <https://www.jsdelivr.com/github>

Pour eviter le cache agressif de jsDelivr pendant le developpement, il est possible de remplacer `@main` par une branche, un tag ou un commit precis.

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

## Format du catalogue

`packages.json` est un tableau d'applications. Chaque entree principale doit contenir :

| Champ | Type | Description |
| --- | --- | --- |
| `name` | string | Nom affiche dans SetupHub. |
| `package_id` | string | Identifiant exact du package dans `winget`. |
| `icon` | string | Nom du fichier dans `icons/`. |
| `category` | string | Categorie fonctionnelle de l'application. |
| `description` | string | Description courte affichee dans l'interface. |
| `tags` | string[] | Mots-cles utiles pour la recherche et le filtrage. |
| `variants` | object[] | Optionnel. Variantes installables avec leur propre `package_id`. |

Exemple :

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

Exemple avec variantes :

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

## Ajouter une application

1. Verifier l'identifiant exact avec `winget show --id <Package.Id> --exact`.
2. Ajouter l'entree dans `packages.json`.
3. Ajouter l'icone PNG correspondante dans `icons/`.
4. Lancer la validation locale.

```powershell
pwsh ./scripts/Test-Catalog.ps1
```

Sur Windows PowerShell, la commande equivalente est :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/Test-Catalog.ps1
```

Si `winget` n'est pas disponible sur la machine, la validation structurelle peut quand meme etre lancee :

```powershell
pwsh ./scripts/Test-Catalog.ps1 -SkipWinget
```

Ou avec Windows PowerShell :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/Test-Catalog.ps1 -SkipWinget
```

## Validation

Le script `scripts/Test-Catalog.ps1` verifie :

- que `packages.json` est un JSON valide ;
- que chaque entree contient les champs obligatoires ;
- que chaque icone referencee existe dans `icons/` ;
- qu'il n'y a pas de doublon dans les `package_id` ;
- que les variantes ont un `name` et un `package_id` ;
- que chaque `package_id` est encore resolu par `winget`.

La validation `winget` n'installe rien. Elle utilise `winget show` pour controler que le package existe toujours dans les sources configurees.

## CI

Le workflow GitHub Actions `.github/workflows/catalog-check.yml` lance la validation sur `windows-latest` :

- a chaque push qui modifie le catalogue, les icones, le script ou le workflow ;
- a chaque pull request sur ces memes fichiers ;
- une fois par semaine, pour detecter les packages retires ou renommes dans `winget` ;
- manuellement via `workflow_dispatch`.

Ce point est utile pour SetupHub : si un identifiant `winget` devient mort, la CI le signale avant que l'application cliente ne propose une installation impossible.
