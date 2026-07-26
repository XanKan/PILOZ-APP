# Piloz Signal — système visuel

## Fondations

- **Navy 950** `#071a31` : rail et zones d'ancrage.
- **Navy 800** `#102c50` : texte principal et titres.
- **Aqua 500** `#11bfae` : action principale et signal.
- **Aqua 600** `#079b91` : survol et contraste.
- **Mist 50** `#f4faf9` : fond applicatif.
- **White glass** `rgba(255,255,255,.88)` : surfaces flottantes.
- **Border** `rgba(16,44,80,.11)` : séparation fine.

## Typographie

- Interface : Albert Sans.
- Signature de marque : Archivo Black, réservée aux grands titres.
- Données, montants et identifiants : Spline Sans Mono.
- Titres : interlignage serré, contraste fort, largeur maîtrisée.
- Textes d'aide : 12 à 14 px, contraste AA sur leur fond.

## Formes et profondeur

- Contrôles : 10 à 12 px de rayon.
- Cartes : 16 à 20 px.
- Fenêtres et grands panneaux : 22 à 26 px.
- Ombre de carte : diffuse et courte.
- Ombre de fenêtre : large, froide et peu opaque.
- Une bordure fine reste toujours visible, même sans ombre.

## Mouvement

- Micro-interaction : 140 à 220 ms.
- Entrée de panneau : 320 à 480 ms avec courbe `cubic-bezier(.16,1,.3,1)`.
- Survol : translation maximale de 2 px.
- Aucun mouvement décoratif continu dans l'application.
- Tout mouvement non essentiel est neutralisé avec `prefers-reduced-motion: reduce`.

## Accessibilité

- Focus visible turquoise/bleu sur tous les contrôles clavier.
- Cibles interactives de 40 px minimum, 44 px sur mobile.
- La couleur ne porte jamais seule le sens : texte, icône ou libellé accompagne les états.
- Contraste renforcé pour les textes secondaires et les badges.
- Les animations ne déplacent ni ne masquent le focus.
