# Processus de release

1. Identifier version sémantique et changements fiscaux.
2. Mettre à jour exigences, risques, changelog, migrations et documentation.
3. Faire relire le code et vérifier la compatibilité des données existantes.
4. Exécuter CI, PGlite, Chrome headless, tests RLS inter-entreprises et scan de secrets.
5. Vérifier migrations ordonnées, Edge Functions, `CNAME=app.piloz.fr` et absence de `.env` suivi.
6. Générer le dossier de preuves et faire approuver la release.
7. Sauvegarder selon la procédure et enregistrer l'identifiant de preuve.
8. Déployer d'abord Supabase en environnement de test, puis les fonctions, puis GitHub Pages.
9. Faire les smoke tests connexion, facture, PDF, paiement, journal et ancienne facture.
10. Surveiller les anomalies et consigner la décision de poursuivre ou revenir à la version applicative précédente.

Une migration de données irréversible nécessite procédure dédiée, sauvegarde vérifiée et approbation. Un rollback applicatif ne doit jamais réécrire ou supprimer les données fiscales créées par une version plus récente.
