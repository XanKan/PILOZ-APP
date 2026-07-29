import {assertEquals,assertMatch} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {buildGuidedAnswer,detectPilozIntent,intentArticleSlugs,OfficialExtractiveAssistantProvider} from "../supabase/functions/_shared/pilo-providers.ts";

Deno.test("une question simple sur les factures ouvre le guide métier",()=>{
  assertEquals(detectPilozIntent("comment faire une facture"),"create_invoice");
  assertEquals(intentArticleSlugs("comment faire une facture")[0],"creer-finaliser-facture");
  const answer=buildGuidedAnswer("comment faire une facture");
  assertMatch(answer,/Ventes > Factures/);
  assertMatch(answer,/Créer une facture/);
  assertMatch(answer,/Finaliser la facture/);
});

Deno.test("une question CII reste une question technique",()=>{
  assertEquals(detectPilozIntent("À quoi sert le format CII d'une facture électronique ?"),null);
  assertEquals(intentArticleSlugs("À quoi sert le format CII d'une facture électronique ?")[0],"comprendre-cii");
});

Deno.test("les principales fonctions Piloz ouvrent leur guide officiel",()=>{
  const routes:Array<[string,string]>=[
    ["comment personnaliser les widgets du tableau de bord","personnaliser-tableau-de-bord"],
    ["comment inviter un utilisateur et modifier son rôle","gerer-utilisateurs-roles"],
    ["comment déplacer une opportunité dans le pipeline","deplacer-opportunite-pipeline"],
    ["comment enregistrer un paiement","enregistrer-reglement"],
    ["comment préparer mon export comptable FEC","generer-export-comptable"],
    ["comment traiter une facture fournisseur en litige","traiter-facture-fournisseur-electronique"],
    ["comment activer le MFA","proteger-compte-mfa"],
    ["comment créer un ticket pour le support","creer-ticket-support"],
    ["à quoi sert une archive fiscale KMS","archives-fiscales"],
    ["la gestion des stocks est-elle disponible ?","la-gestion-des-stocks-est-elle-disponible"]
  ];
  for(const [question,slug] of routes)assertEquals(intentArticleSlugs(question)[0],slug,question);
});

Deno.test("la réponse de secours ne restitue jamais les titres Markdown",async()=>{
  const provider=new OfficialExtractiveAssistantProvider();
  const result=await provider.answer({question:"Explique cette fonction",sources:[{
    id:"article-1",slug:"guide",title:"Guide",summary:"Un guide utile.",categoryName:"Aide",availability:"available",publishedAt:null,
    excerpt:"## Résumé\nUn guide utile.\n## Étapes\nOuvrez la page, vérifiez les données puis validez.\n## Résultat attendu\nLa fiche est enregistrée."
  }]});
  assertEquals(result.answer.includes("##"),false);
  assertMatch(result.answer,/Ouvrez la page/);
});
