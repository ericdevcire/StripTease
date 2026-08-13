# Passage de GPL-3.0 à une licence commerciale

## Où en est le dépôt

`LICENSE` à la racine est toujours **GPL-3.0**, et les en-têtes des sources disaient
« freeware ». Les deux se contredisaient, et aucun des deux ne correspond au modèle
payant décidé. `packaging/src/LICENSE.txt` est le texte de remplacement proposé ; il est
livré avec le paquet et les en-têtes des sources y renvoient désormais.

**Je n'ai pas touché au `LICENSE` de la racine** : c'est une décision juridique, pas une
tâche de build.

## Ce que tu dois faire toi-même

1. **Faire relire `LICENSE.txt`.** Je ne suis pas juriste et ce texte n'est pas un conseil
   juridique. Les points qui méritent un vrai regard : la clause de garantie face au droit
   de la consommation français (article 6), la limitation de responsabilité (article 7), et
   la formulation sur la rétro-ingénierie (article 3) — le droit européen autorise
   certaines formes de décompilation quelles que soient les clauses contractuelles.
2. **Retirer le bandeau BROUILLON** en tête du fichier une fois la relecture faite.
3. **Remplacer `LICENSE`** à la racine par le texte validé.

## Le point qui ne se répare pas

Relicencier n'a pas d'effet rétroactif. La version 1.0 a été publiée sous GPL-3.0 sur un
dépôt public : **toute personne l'ayant récupérée conserve les droits de la GPL sur cette
version-là**, y compris celui de la redistribuer et d'en publier des forks. Tu es seul
auteur, donc tu peux changer la licence pour la suite, mais tu ne peux pas révoquer ce qui
a déjà été distribué.

Concrètement : les forks légitimes de la 1.0 restent possibles, et l'historique git du
dépôt public contient le code source en clair. C'est ce qui justifie de **recréer le dépôt
vitrine à neuf** plutôt que de faire un commit de suppression — voir l'étape 1 du plan.

## Ce qui est déjà en place

- `LICENSE.txt` est installé avec le paquet dans `Effects/StripTease/`.
- `license_notice` dans `build_config.json` fournit la mention réinjectée dans l'en-tête de
  chaque fichier livré, après obfuscation.
- Les en-têtes des sources ne mentionnent plus « freeware ».
