(function(global){
 // Copie cliente des capacités par offre. La base (table public.plans) fait
 // foi pour l'affichage des tarifs et pour has_feature() côté serveur ; cette
 // copie sert uniquement à des vérifications d'interface instantanées, sans
 // aller-retour réseau. Garder ces clés synchronisées avec la migration
 // 202607210012_subscriptions_and_plans.sql et avec le fichier de
 // configuration des offres du site vitrine (PILOZ-SITE).
 const PLAN_FEATURES={
  essential:['crm','quotes','invoices','credit_notes','payments','manual_reminders'],
  pro:['crm','quotes','invoices','credit_notes','payments','manual_reminders','automatic_reminders','recurring_invoices','deposits','sales_pipeline_automations','purchases','suppliers','purchase_orders','inventory','advanced_templates','advanced_dashboard','margin_reports'],
  business:['crm','quotes','invoices','credit_notes','payments','manual_reminders','automatic_reminders','recurring_invoices','deposits','sales_pipeline_automations','purchases','suppliers','purchase_orders','inventory','advanced_templates','advanced_dashboard','margin_reports','multi_warehouse','roles_permissions','activity_logs','api_access']
 };
 const PLAN_META={
  essential:{name:'Essentiel',priceMonthly:29,priceAnnual:290,maxUsers:1},
  pro:{name:'Pro',priceMonthly:59,priceAnnual:590,maxUsers:5},
  business:{name:'Business',priceMonthly:99,priceAnnual:990,maxUsers:15}
 };
 const FEATURE_LABELS={
  crm:'Suivi commercial',quotes:'Devis',invoices:'Factures',credit_notes:'Avoirs',payments:'Paiements',
  manual_reminders:'Relances manuelles',automatic_reminders:'Relances automatiques',recurring_invoices:'Factures récurrentes',
  deposits:'Factures d’acompte et de solde',sales_pipeline_automations:'Automatisations du pipeline',
  purchases:'Achats',suppliers:'Fournisseurs',purchase_orders:'Commandes fournisseurs',inventory:'Gestion de stock',
  multi_warehouse:'Plusieurs entrepôts',advanced_templates:'Modèles personnalisables avancés',
  advanced_dashboard:'Tableaux de bord avancés',margin_reports:'Rapports de marge',roles_permissions:'Rôles et permissions avancés',
  activity_logs:'Historique d’activité avancé',api_access:'Accès API'
 };
 // Offre minimale nécessaire pour débloquer chaque fonctionnalité (pour les
 // messages « Disponible avec l'offre X »).
 function planRequiredFor(featureKey){
  if(PLAN_FEATURES.essential.includes(featureKey))return'essential';
  if(PLAN_FEATURES.pro.includes(featureKey))return'pro';
  if(PLAN_FEATURES.business.includes(featureKey))return'business';
  return null;
 }
 function getSubscription(){const state=global.PilozApp?.getState?.();return state?.data?.subscription?.[0]||null;}
 function isTrialExpired(sub){return sub?.status==='trialing'&&sub.trial_ends_at&&new Date(sub.trial_ends_at)<new Date();}
 function getCurrentPlan(){const sub=getSubscription();return sub?.plan_key||'essential';}
 function getSubscriptionStatus(){const sub=getSubscription();if(!sub)return'unknown';if(isTrialExpired(sub))return'expired';return sub.status;}
 function getPlanLimits(){const key=getCurrentPlan(),meta=PLAN_META[key]||PLAN_META.essential;return{maxUsers:meta.maxUsers,planName:meta.name,priceMonthly:meta.priceMonthly,priceAnnual:meta.priceAnnual};}
 // Absence de données d'abonnement (migration pas encore appliquée, ou
 // chargement pas terminé) => on n'impose aucune restriction plutôt que de
 // bloquer l'application par erreur. Une fois la table réellement peuplée,
 // l'évaluation redevient stricte.
 function hasFeature(featureKey){
  const sub=getSubscription();
  if(!sub)return true;
  if(['canceled','suspended','expired'].includes(sub.status))return false;
  if(isTrialExpired(sub))return false;
  const features=PLAN_FEATURES[sub.plan_key]||PLAN_FEATURES.essential;
  return features.includes(featureKey);
 }
 function canAddUser(currentUserCount){const sub=getSubscription();if(!sub)return true;const limits=getPlanLimits();return currentUserCount<limits.maxUsers;}
 function canUseFeature(featureKey){return hasFeature(featureKey);}
 function upgradeCard(featureKey){
  const required=planRequiredFor(featureKey),label=FEATURE_LABELS[featureKey]||featureKey,planName=(PLAN_META[required]||{}).name||'supérieure';
  return`<div class="modern-empty"><h3>Fonctionnalité verrouillée</h3><p>${label} est disponible avec l’offre Piloz ${planName}.</p><button class="btn btn-p" onclick="PilozApp.go('settings/subscription')">Découvrir l’offre ${planName}</button></div>`;
 }
 global.PilozSubscription={PLAN_FEATURES,PLAN_META,FEATURE_LABELS,planRequiredFor,getSubscription,getCurrentPlan,getSubscriptionStatus,getPlanLimits,hasFeature,canAddUser,canUseFeature,upgradeCard};
})(window);
