# Matrice des tests d'acceptation

## Résultats reproductibles dans ce dépôt

- calculs commerciaux : `tests/browser-tests.html`, 16/16 tests locaux réussis ;
- rendu ERP : `tests/erp-smoke.html`, 33/33 routes et éditeurs rendus sans erreur ;
- structure PostgreSQL/RLS, champs financiers protégés et isolation comportementale de deux locataires : `supabase/tests/rls_acceptance.sql` (19 assertions), à exécuter sur une base Supabase de test après migration ;
- connectivité publique vérifiée pour la recherche d'entreprises et la recherche d'adresses ;
- aucun déploiement n'a été effectué : les tests nécessitant Auth, Storage, Edge Functions, Resend, Twilio ou des transactions PostgreSQL réelles restent à exécuter sur l'environnement de recette.

## Les 38 scénarios obligatoires

| # | Scénario | Couverture livrée | Validation de recette |
|---:|---|---|---|
| 1 | Recherche par raison sociale | Edge Function + interface avec temporisation | À exécuter après déploiement Edge |
| 2 | Recherche par SIRET | Même flux officiel | À exécuter après déploiement Edge |
| 3 | Sélection d'un établissement | Liste et choix d'établissement | À exécuter avec une société multi-sites |
| 4 | Remplissage SIRET, APE, forme et adresse | Mappage et persistance normalisée | À vérifier sur la base de recette |
| 5 | Adresse prédictive | Edge Function Géoplateforme | À exécuter après déploiement Edge |
| 6 | Confirmation e-mail | Jeton haché, délai et RPC atomique | Nécessite Resend configuré |
| 7 | Validation téléphone | Code haché, délai, cinq essais et RPC atomique | Nécessite Twilio si activé |
| 8 | Import du logo | Validation SVG/image, bucket privé et URL signée | À vérifier avec Storage réel |
| 9 | Création client | Formulaire et table avec RLS | À exécuter sur la recette |
| 10 | Création fournisseur | Formulaire et table avec RLS | À exécuter sur la recette |
| 11 | Article stocké | Catalogue, entrepôt et stock initial | À exécuter sur la recette |
| 12 | Service non stocké | Catalogue sans mouvement de stock | À exécuter sur la recette |
| 13 | Prix d'achat et de vente | Champs, historique et permissions | À exécuter avec deux rôles |
| 14 | Calcul de marge | Couvert par les tests de calcul | Réussi localement |
| 15 | Devis pleine page | Éditeur dédié | Rendu réussi localement |
| 16 | Ajout d'un article existant | Sélecteur catalogue et instantanés | À exécuter sur la recette |
| 17 | Création d'article depuis devis | Formulaire rapide | À exécuter sur la recette |
| 18 | Section et sous-total | Lignes structurantes et calcul hors options | Rendu réussi, persistance à vérifier |
| 19 | Prévisualisation PDF | Aperçu par modèle sans coûts internes | À confronter au navigateur d'impression |
| 20 | Modèle personnalisé | Sélection et rendu d'une version | À exécuter sur la recette |
| 21 | Modification visuelle | Blocs ajoutés, supprimés et réordonnés | Rendu réussi localement |
| 22 | Modification code | Recherche, lignes, annulation/rétablissement | Rendu réussi localement |
| 23 | Restauration d'une version | Historique versionné | À exécuter sur la recette |
| 24 | Devis vers commande | Action de conversion | À exécuter sur la recette |
| 25 | Réservation stock | RPC atomique à la confirmation | À exécuter sur PostgreSQL réel |
| 26 | Livraison partielle | Contrôle du restant et mouvement atomique | À exécuter sur PostgreSQL réel |
| 27 | Livraison complète | Statut livré après solde | À exécuter sur PostgreSQL réel |
| 28 | Stock physique | Vue issue des mouvements | À contrôler après les flux 25–27 |
| 29 | Réception fournisseur | Réception partielle/complète atomique | À exécuter sur PostgreSQL réel |
| 30 | Coût moyen | Recalcul lors de la réception | À contrôler avec plusieurs coûts |
| 31 | Inventaire avec écart | Import/saisie et validation | À exécuter sur PostgreSQL réel |
| 32 | Mouvement d'ajustement | Créé par le RPC d'inventaire | À contrôler après le scénario 31 |
| 33 | Retour client | Mouvement inverse traçable | À exécuter sur PostgreSQL réel |
| 34 | Annulation commande | RPC de statut | À exécuter sur PostgreSQL réel |
| 35 | Libération réservation | Incluse dans l'annulation | À contrôler après le scénario 34 |
| 36 | Facture sans double décrément | Le stock sort à la livraison, pas à la facture | À tester transactionnellement |
| 37 | Données après reconnexion | Persistance Supabase normalisée | À exécuter avec une vraie session |
| 38 | Étanchéité entre entreprises | RLS généralisée + test pgTAP avec JWT simulé et deux locataires | À exécuter aussi avec deux JWT réels en recette |

Le statut « à exécuter » ne signifie pas que le flux est simulé : il signale qu'il dépend volontairement d'une base et de fonctions qui n'ont pas été déployées pendant cette intervention.
