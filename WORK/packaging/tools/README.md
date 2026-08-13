# Pipeline de build StripTease

Chaîne obfuscation + packaging ReaPack. **Aucun fichier source n'est modifié** : tout
est lu depuis `StripTease/`, `FXChains/` et `packaging/src/`, tout est écrit dans
`packaging/out/`. **Rien n'est jamais écrit hors du dépôt** — la copie vers les dossiers
REAPER se fait à la main.

## Utilisation

```bash
python3 packaging/tools/build.py --version 1.0.1 --changelog "Optimisation CPU du VU."
```

Produit :

```
packaging/out/index.xml               # à déposer à la racine du dossier publié
packaging/out/v<version>/
  Effects/StripTease/   # les 9 JSFX
  Scripts/StripTease/   # les 3 scripts Lua
  FXChains/           # les .RfxChain
```

La livraison est rangée **par dossier de destination**, calquée sur la resource path de
REAPER : copier `Effects/`, `Scripts/` et `FXChains/` dans le dossier ressource fusionne
au bon endroit, sans avoir à savoir quel fichier va où. Les URL de l'index reprennent la
même arborescence.

Options utiles : `--edition lite` (voir plus bas), `--no-obfuscate` (build en clair
pour déboguer), `--index-name` (build de test isolé), `--category`, `--base-url`.

La configuration persistante est dans `packaging/tools/build_config.json` — **`base_url` doit
pointer sur l'URL publique** avant toute publication réelle.

## Éditions (`--edition`)

```bash
python3 packaging/tools/build.py --edition lite --version 1.0.0 --changelog "…"
```

Une seule source, deux livraisons. La table `EDITIONS` de `build.py` décrit ce que
chaque édition emporte ; `lite.py` décrit ce qu'elle retire du code.

| | `pro` (défaut) | `lite` |
| --- | --- | --- |
| sortie | `packaging/out/` | `packaging/out-lite/` |
| historique | `versions.json` | `versions-lite.json` |
| table de renommage | `namemap.json` | `namemap-lite.json` |
| tailles de panneau | 7 | 2 (150, 300 px) |
| éléments / panneau | 50 | 12 |
| mètres / panneau | illimité | 1 |
| recettes (liens portables) | ✓ | ✗ |
| `StripTease.jsfx` (mesure de GR) | ✓ | ✗ |
| FX chains | 9 | ✗ |
| `Install FX chains.lua` | ✓ | ✗ |
| Copy / Paste layout & links | ✓ | ✗ |
| groupes de scroll | ✓ | ✗ |

**Les noms de fichiers et les `desc:` sont identiques dans les deux éditions**, et les
deux s'installent dans `Effects/StripTease/`. Passer de la Lite à la Pro est donc une
copie de fichiers par-dessus : les projets, les presets et les templates existants
continuent de charger le même plugin, avec 50 éléments au lieu de 12. C'est la
contrepartie : les deux éditions ne peuvent pas cohabiter dans une même installation
de REAPER. Pour un test côte à côte, builder la Lite avec
`--index-name "StripTease Lite"` (elle atterrit alors dans `Effects/StripTease Lite/`).

### `lite.py`

Le principe : **retirer le code, pas poser un drapeau**. Un `EDITION = 0` dans un
fichier livré en clair se retourne en dix secondes ; du code absent ne se retourne
pas. Les entrées de menu Pro disparaissent du menu du fond, et les trois fonctions qui
alimentent les recettes (`sb_wish_pub`, `sb_wish_offer`, `sb_wish_learned`) sont
vidées — le service Lua ne reçoit plus rien à reconstruire.

Chaque restriction est un `Patch(quoi, extrait_source, remplacement)` ancré sur un
extrait littéral et **doit s'appliquer exactement une fois**. Si le moteur évolue et
qu'un extrait ne correspond plus, le build échoue en nommant le patch, plutôt que de
livrer une Lite silencieusement incomplète. Les sources ne sont jamais modifiées : la
transformation écrit une copie dans le stage, et c'est elle qui part à l'obfuscation.

Un preset, un template ou une FX chain venus de la Pro se chargent dans la Lite sans
erreur : `@serialize` lit tout le flux (sinon l'état suivant serait décalé) puis
ramène l'état aux normes Lite — au-delà de 12 éléments et d'un mètre le surplus est
effacé, et la recette est jetée.

## Fichiers générés et versionnés

| Fichier | Rôle |
| --- | --- |
| `packaging/tools/namemap.json` | table de renommage JSFX, **à committer** : elle garde les noms stables d'une version à l'autre (`namemap-lite.json` pour la Lite) |
| `packaging/tools/versions.json` | historique des versions et changelogs réinjectés dans `index.xml` (`versions-lite.json` pour la Lite) |
| `packaging/tools/build_config.json` | auteur, URLs, texte About, mention de licence |

## Chemins d'installation

ReaPack calcule le chemin selon le `type` de chaque `<source>` :

| type | destination |
| --- | --- |
| `effect` | `Effects/<nom index>/<catégorie>/<fichier>` |
| `script` | `Scripts/<nom index>/<catégorie>/<fichier>` |
| `data` | `Data/<fichier>` — **sans préfixe** |

Avec `index_name = "StripTease"` et `category = "."`, les JSFX atterrissent dans
`Effects/StripTease/`, exactement là où l'installation manuelle actuelle les place :
les projets et les `.RfxChain` existants continuent de fonctionner. Si ReaPack
refuse la catégorie `"."`, passer `--category Panels` : `build.py` repointe alors
automatiquement la ligne `<JS "…">` des 7 FX chains vers le nouveau chemin.

ReaPack ne sait pas écrire dans `FXChains/`. Les chaînes sont livrées en
`Data/StripTease/` et le script **StripTease Install FX chains** les recopie dans
`FXChains/` (à relancer après chaque mise à jour).

## Carte gmem (`check_gmem.py` + `gmem_map.json`)

Le protocole JSFX ↔ Lua repose sur des adresses `gmem` écrites en dur **dans les deux
langages** (`sb_LRN = 12288` d'un côté, `LRN = 12288` de l'autre). Décaler une seule des
deux ne produit aucune erreur : les deux moitiés continuent de tourner et s'écrivent
simplement à côté. C'est un bug silencieux, et coûteux à diagnostiquer.

`gmem_map.json` est la référence : chaque bloc y a une valeur, une taille et la liste des
identifiants qui doivent la porter dans chaque fichier. Le build échoue si une constante
diverge, si elle a été renommée, ou si deux blocs se chevauchent.

La carte n'est **pas** générée dans le code : les sources restent exécutables telles
quelles pendant le développement. En ajoutant un champ à un bloc, augmente sa `size` dans
le JSON — sinon la collision suivante passera inaperçue.

```bash
python3 packaging/tools/check_gmem.py
```

## Obfuscation

### `jsfx_obf.py`

Renomme **uniquement** les identifiants `sb_*` (339 dans le code). Il a été vérifié
que ce préfixe n'apparaît dans aucun mot-clé EEL2, aucun littéral chaîne et aucune
ligne `slider` — le renommage est donc sûr. Sont préservés : `desc:`, `options:`,
les 50 lignes `slider`, `import`, les marqueurs `@…`, et les 247 littéraux chaîne
(libellés de menus).

Garde-fous qui font échouer le build : token `sb_` résiduel, littéraux chaîne
modifiés, ligne d'en-tête ou `slider` modifiée.

### `lua_obf.py`

1. Renommage conservateur des locales de portée fichier — un nom est écarté s'il
   est déclaré plusieurs fois, masqué par un paramètre ou une variable de boucle,
   utilisé comme champ (`.nom`) ou comme clé de table.
2. Suppression des commentaires et de l'indentation.
3. Chiffrement (clé additive) + hexa, le fichier livré se réduit à un stub
   `load(<décodage>)()`. Le `chunkname` `@<nom du fichier>` préserve des messages
   d'erreur exploitables.

Garde-fous : le flux de tokens de la sortie doit être identique à celui de la
source aux renommages près (donc structure et donc syntaxe préservées), et le
décodage du stub doit redonner exactement le corps encodé.

**Ce n'est pas un DRM.** Le protocole gmem/ExtState reste observable et le chunk
décodé est réimprimable depuis REAPER. C'est un ralentisseur contre la reprise
d'algorithme, pas contre un attaquant motivé.

## Génération des panneaux

Les 7 panneaux sont générés depuis `StripTease/StripTease Panel 100 px` (seuls `desc:`
et `@gfx 80 N` changent). Le build **échoue** si un panneau généré diffère du
fichier source correspondant : c'est le garde-fou contre une divergence entre les
7 copies.

## Pourquoi pas `reapack-index`

`reapack-index` suppose un dépôt git dont il dérive des URL GitHub raw. StripTease
est servi depuis un hébergement statique : `build.py` écrit `index.xml`
directement, ce qui donne aussi la main sur le nom de catégorie.
