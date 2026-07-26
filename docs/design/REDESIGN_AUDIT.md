# Audit de refonte visuelle — PILOZ-APP

Date : 26 juillet 2026  
Périmètre : présentation, ergonomie visuelle, responsive et accessibilité uniquement.

## Résumé exécutif

PILOZ-APP possède déjà une base fonctionnelle riche et une identité reconnaissable (bleu nuit, turquoise, fond clair). La faiblesse principale n'est pas fonctionnelle : l'interface résulte de plusieurs générations de styles superposées. Les mêmes objets — cartes, tableaux, filtres, panneaux et boutons — n'ont donc pas toujours la même densité, la même profondeur ou le même rythme.

La refonte conserve intégralement le DOM métier et les comportements existants. Elle ajoute une couche de présentation commune chargée après les feuilles historiques, sans modifier les appels Supabase, les RPC, les règles de permissions, les données ou les parcours.

## Architecture visuelle existante

- Application statique pilotée depuis `index.html` avec composants générés côté client.
- Typographies existantes : Albert Sans, Archivo Black et Spline Sans Mono.
- Couleurs de marque existantes : bleu nuit `#102c50`, turquoise `#11bfae`, fond clair légèrement vert.
- Feuilles principales : `phase1-foundation.css`, `modern-erp.css`, `dashboard-cockpit.css`, `document-viewer-v2.css`, `clients-workspace.css`, `catalog-workspace.css`, `piloz-brand.css`.
- Le thème sombre historique est déjà neutralisé au profit d'un thème clair.
- Les zones complexes (éditeur de documents, visionneuse, catalogue, clients) disposent de leurs propres sous-systèmes CSS.

## Incohérences constatées

### Navigation et structure

- Rail principal très blanc et peu différencié du contenu.
- Panneau secondaire fonctionnel mais visuellement plat.
- Hiérarchie entre contexte global, section et page parfois faible.
- État actif cohérent en couleur, mais peu expressif en profondeur et en mouvement.

### Composants

- Rayons compris entre 6 et 18 px sans logique perceptible.
- Ombres très faibles sur certaines cartes et fortes sur certaines fenêtres.
- Plusieurs styles de boutons, champs, menus et badges coexistent.
- Les tableaux sont lisibles, mais denses et peu éditoriaux.
- Les cartes de tableau de bord ont une structure uniforme qui différencie peu les informations prioritaires.

### Typographie et rythme

- Albert Sans est adaptée au produit, mais la hiérarchie utilise peu ses contrastes de graisse et de taille.
- Les titres de page, sous-titres, aides et libellés manquent parfois de respiration.
- Les montants et données chiffrées ne bénéficient pas toujours du traitement tabulaire/monospace disponible.

### Mouvement

- Les transitions sont locales et hétérogènes.
- Les ouvertures de panneaux, survols de lignes et états actifs manquent d'une grammaire commune.
- La préférence `prefers-reduced-motion` doit rester prioritaire.

### Responsive et accessibilité

- Les principaux seuils responsive existent déjà (1180, 900 et 640 px).
- Les tables se transforment correctement en blocs sur mobile, mais certaines barres d'actions restent chargées.
- Les focus visibles sont présents ; leur rendu doit être unifié et renforcé.
- Le contraste du texte secondaire sur certains fonds teintés mérite d'être renforcé.

## Direction retenue : « Piloz Signal »

Une interface d'exploitation calme, lumineuse et précise :

- rail bleu nuit profond, utilisé comme ancrage permanent ;
- surfaces ivoire/blanc brume avec bordures froides très fines ;
- turquoise Piloz utilisé comme signal, pas comme remplissage omniprésent ;
- halo cyan discret pour les actions et états importants ;
- grands rayons cohérents, ombres diffuses et profondeur par couches ;
- titres éditoriaux compacts, données tabulaires et micro-libellés sobres ;
- transitions rapides, naturelles et désactivables.

## Règles de non-régression

- Aucun changement de schéma, migration, RPC, Edge Function ou requête Supabase.
- Aucun changement de droits, d'authentification ou de navigation métier.
- Aucun texte métier supprimé ou remplacé par une donnée fictive.
- Aucun composant fonctionnel recréé : les sélecteurs historiques sont stylés en place.
- `CNAME` et le blocage d'indexation de l'application restent intacts.
- La refonte est additive et peut être retirée sans perte fonctionnelle.

## Priorités d'implémentation

1. Tokens, arrière-plan, typographie et focus.
2. Rail principal, navigation secondaire et en-têtes.
3. Boutons, champs, filtres, cartes, tableaux et badges.
4. Tableau de bord et écrans éditoriaux.
5. Éditeurs de documents, visionneuse, paramètres, catalogue et clients.
6. Fenêtres, tiroirs, états vides, chargement et notifications.
7. Responsive, mouvement réduit et tests de non-régression.
