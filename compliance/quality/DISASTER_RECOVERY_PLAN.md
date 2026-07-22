# Plan de reprise après sinistre

Déclenchement : perte régionale/projet, corruption, compromission, suppression massive ou indisponibilité dépassant le RTO approuvé. Le responsable incident autorise la reprise et désigne l'environnement cible.

Ordre : préserver preuves ; révoquer secrets compromis ; créer projet isolé ; restaurer dernier backup valide ; déployer migrations et fonctions au commit associé ; restaurer Storage ; configurer DNS/secrets ; contrôler chaînes, archives, séquences, RLS et comptes ; effectuer smoke tests ; autoriser la reprise ; surveiller.

Ne pas attribuer de nouveaux numéros tant que la continuité des séquences n'est pas prouvée. Conserver l'ancien environnement en lecture/preuve si légalement possible. Documenter perte maximale, opérations à ressaisir par événements correctifs et décision de reprise.
