# Limites connues

État au 22 juillet 2026 :

- migrations 039–047 non confirmées sur le projet Supabase de production ;
- aucune inspection directe des sauvegardes, RLS ou fonctions de production ;
- KMS/signature non configuré : événements, clôtures et archives explicitement non signés ;
- archive de production bloquée ; bundle JSON limité à 50 Mo ;
- restauration réelle non exécutée ;
- textes complets NF 525, NF 203 et XP non fournis ; clauses non cartographiées ;
- UBL, CII, Factur-X, XSD et Schematron non implémentés sans profils officiels ;
- aucune plateforme agréée choisie, aucun connecteur réel, webhook ou accusé ;
- e-reporting et cycle électronique seulement préclassifiés, validation externe requise ;
- automatisation des clôtures codée mais job Cron de production non créé ; archives automatiques volontairement bloquées sans KMS ;
- cycle RGPD opérationnel techniquement, mais durées, base légale et procédures à valider par le DPO/juridique ;
- tests de concurrence réels PostgreSQL, charge 10 000 lignes, restauration, pénétration et interopérabilité externe à réaliser ;
- les données historiques restent `legacy_unsecured` et ne reçoivent aucune preuve rétroactive ;
- aucune certification, homologation, conformité AFNOR ou conformité réglementaire n'est revendiquée.
