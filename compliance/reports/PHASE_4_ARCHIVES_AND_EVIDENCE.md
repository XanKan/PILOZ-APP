# Rapport de phase 4 — archives, vérification et preuves

Date : 22 juillet 2026

## Livré

- registre d'archives, éléments et exports append-only, isolé par `company_id` ;
- création serveur d'un manifeste déterministe comprenant données structurées, PDF et contrôles de chaîne ;
- blocage d'une archive stricte si un PDF final manque ;
- chaînage des archives et événements `archive_created` / `archive_exported` ;
- export serveur d'un bundle JSON contenant les véritables PDF après recontrôle SHA-256 ;
- vérificateur autonome avec détection d'altération, contrôle de chaîne et état de signature explicite ;
- générateur de dossier de preuves sans données client ni secrets ;
- procédure de sauvegarde/restauration documentée sans prétendre qu'elle est activée chez Supabase.

## Résultats de test

- migrations complètes et parcours PGlite : réussite ;
- archive stricte avec JSON et PDF référencé : réussite ;
- tentative de modification directe de l'archive : bloquée ;
- export enregistré comme événement append-only : réussite ;
- vérificateur autonome : 7 contrôles réussis ;
- modification simulée du contenu : altération détectée.

## Limites et validations restantes

- le KMS n'est pas configuré : archives marquées `unsigned` et production volontairement bloquée ;
- la sauvegarde réelle, le PITR, la réplication Storage et un exercice de restauration doivent être exécutés sur l'infrastructure Supabase ;
- l'Edge Function `export-fiscal-archive` et la migration doivent être déployées ;
- la valeur probante, la politique de conservation et l'algorithme de signature nécessitent des validations externes ;
- le bundle JSON est limité à 50 Mo ; prévoir un export en flux ou par lots pour les volumes supérieurs.
