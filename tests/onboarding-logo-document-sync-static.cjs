const assert = require('assert');
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'assets', 'js', 'modules', 'onboarding', 'professional-onboarding.js'),
  'utf8',
);

assert(
  source.includes('function syncOnboardingLogoWithRuntime'),
  'L’onboarding doit exposer une synchronisation du logo vers le runtime.',
);

assert(
  source.includes('runtime.state.data.logoUrls'),
  'Le logo onboarding doit alimenter PilozRuntime.state.data.logoUrls, utilisé par les modèles et brouillons.',
);

assert(
  source.includes('piloz:company-logo-updated'),
  'Un événement applicatif doit signaler la mise à jour du logo entreprise.',
);

assert(
  source.includes('refreshOnboardingLogoRuntimeFromSupabase'),
  'Après upload, le logo actif doit être relu/signé depuis Supabase Storage.',
);

assert(
  source.includes("signedUrl('company-assets'"),
  'Le logo doit être signé depuis le bucket company-assets pour être affichable immédiatement.',
);

assert(
  source.includes('nativeProfessionalUploadLogo=global.professionalUploadLogo'),
  'Le correctif doit compléter la fonction upload existante sans remplacer sa logique métier.',
);

console.log('OK onboarding logo document sync');
