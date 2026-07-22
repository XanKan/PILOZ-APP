export type FiscalSignature={algorithm:string;keyId:string;signatureBase64:string};
export type FiscalSigner={
  status():Promise<{configured:boolean;provider:string;keyId?:string}>;
  signDigest(hexDigest:string):Promise<FiscalSignature>;
  verifyDigest(hexDigest:string,signature:FiscalSignature):Promise<boolean>;
};

function sorted(value:unknown):unknown{
  if(Array.isArray(value))return value.map(sorted);
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value as Record<string,unknown>).sort(([a],[b])=>a.localeCompare(b)).map(([key,item])=>[key,sorted(item)]));
  return value;
}

export function canonicalizeFiscalPayload(value:unknown):string{
  return JSON.stringify(sorted(value));
}

export async function sha256Hex(value:string|Uint8Array):Promise<string>{
  const bytes=typeof value==='string'?new TextEncoder().encode(value):value;
  const digest=await crypto.subtle.digest('SHA-256',bytes);
  return [...new Uint8Array(digest)].map(byte=>byte.toString(16).padStart(2,'0')).join('');
}

export class KmsRequiredSigner implements FiscalSigner{
  async status(){return{configured:false,provider:'none'};}
  async signDigest(_hexDigest:string):Promise<FiscalSignature>{throw new Error('KMS_NOT_CONFIGURED');}
  async verifyDigest(_hexDigest:string,_signature:FiscalSignature):Promise<boolean>{throw new Error('KMS_NOT_CONFIGURED');}
}

// L'implémentation de production doit déléguer à un KMS/HSM. Aucune clé
// privée ne doit être acceptée par cette abstraction ou chargée depuis Git.
export const fiscalSigner: FiscalSigner=new KmsRequiredSigner();
