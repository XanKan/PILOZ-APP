# Plan de continuité d'activité

Services prioritaires : authentification et isolation, consultation des documents finalisés, création/finalisation, paiements, PDF/archives, puis modules commerciaux. Dépendances critiques : DNS/GitHub Pages, Supabase Auth/PostgreSQL/Storage/Functions, KMS futur, plateforme future et e-mail.

En incident, geler les opérations fiscales si intégrité, séquence, heure ou signature ne sont plus garanties. Autoriser la consultation sûre si possible. Ne jamais utiliser un tableur non contrôlé pour réinjecter silencieusement numéros ou paiements. Communiquer l'état et conserver la chronologie.

Objectifs RTO/RPO ne sont pas encore approuvés. Ils doivent être définis avec la direction et testés. Les coordonnées d'astreinte, remplaçants, accès d'urgence et fournisseur alternatif restent à compléter hors Git.
