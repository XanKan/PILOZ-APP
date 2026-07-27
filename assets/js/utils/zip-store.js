(function(global){
 'use strict';

 const encoder=new TextEncoder();
 let crcTable=null;

 function makeCrcTable(){
  const table=new Uint32Array(256);
  for(let value=0;value<256;value+=1){
   let crc=value;
   for(let bit=0;bit<8;bit+=1)crc=(crc&1)?(0xedb88320^(crc>>>1)):(crc>>>1);
   table[value]=crc>>>0;
  }
  return table;
 }

 function crc32(bytes){
  if(!crcTable)crcTable=makeCrcTable();
  let crc=0xffffffff;
  for(let index=0;index<bytes.length;index+=1)crc=crcTable[(crc^bytes[index])&0xff]^(crc>>>8);
  return (crc^0xffffffff)>>>0;
 }

 function utf8(value){return encoder.encode(String(value??''));}

 function base64(value){
  const clean=String(value||'').replace(/\s+/g,''),binary=global.atob?global.atob(clean):'';
  if(!binary&&clean)throw new Error('Contenu Base64 invalide dans l\u2019archive fiscale.');
  const bytes=new Uint8Array(binary.length);
  for(let index=0;index<binary.length;index+=1)bytes[index]=binary.charCodeAt(index);
  return bytes;
 }

 function safeName(value,index){
  const parts=String(value||`fichier-${index+1}`).replace(/\\/g,'/').split('/').filter(part=>part&&part!=='.'&&part!=='..').map(part=>part.replace(/[<>:"|?*\x00-\x1f]/g,'-'));
  return parts.join('/')||`fichier-${index+1}`;
 }

 function asBytes(value){
  if(value instanceof Uint8Array)return value;
  if(value instanceof ArrayBuffer)return new Uint8Array(value);
  return utf8(value);
 }

 function dosStamp(dateValue){
  const date=dateValue instanceof Date&&!Number.isNaN(dateValue.getTime())?dateValue:new Date(),year=Math.max(1980,Math.min(2107,date.getFullYear()));
  return{time:((date.getHours()&31)<<11)|((date.getMinutes()&63)<<5)|((Math.floor(date.getSeconds()/2))&31),date:((year-1980)<<9)|(((date.getMonth()+1)&15)<<5)|(date.getDate()&31)};
 }

 function header(size){return new Uint8Array(size);}
 function u16(bytes,offset,value){new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength).setUint16(offset,value,true);}
 function u32(bytes,offset,value){new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength).setUint32(offset,value>>>0,true);}
 function concat(chunks,total){const output=new Uint8Array(total);let offset=0;chunks.forEach(chunk=>{output.set(chunk,offset);offset+=chunk.length;});return output;}

 function create(entries){
  if(!Array.isArray(entries)||!entries.length)throw new Error('Aucun fichier à placer dans le ZIP.');
  if(entries.length>65535)throw new Error('Le ZIP contient trop de fichiers.');
  const files=entries.map((entry,index)=>{const name=utf8(safeName(entry.name,index)),data=asBytes(entry.data),stamp=dosStamp(entry.modifiedAt),checksum=crc32(data);if(name.length>65535)throw new Error('Nom de fichier trop long dans le ZIP.');if(data.length>0xffffffff)throw new Error('Un fichier dépasse la limite ZIP de 4 Go.');return{name,data,stamp,checksum,offset:0};});
  const localChunks=[];
  let localSize=0;
  files.forEach(file=>{
   file.offset=localSize;
   const local=header(30);
   u32(local,0,0x04034b50);u16(local,4,20);u16(local,6,0x0800);u16(local,8,0);u16(local,10,file.stamp.time);u16(local,12,file.stamp.date);u32(local,14,file.checksum);u32(local,18,file.data.length);u32(local,22,file.data.length);u16(local,26,file.name.length);u16(local,28,0);
   localChunks.push(local,file.name,file.data);
   localSize+=local.length+file.name.length+file.data.length;
  });
  const centralChunks=[];
  let centralSize=0;
  files.forEach(file=>{
   const central=header(46);
   u32(central,0,0x02014b50);u16(central,4,20);u16(central,6,20);u16(central,8,0x0800);u16(central,10,0);u16(central,12,file.stamp.time);u16(central,14,file.stamp.date);u32(central,16,file.checksum);u32(central,20,file.data.length);u32(central,24,file.data.length);u16(central,28,file.name.length);u16(central,30,0);u16(central,32,0);u16(central,34,0);u16(central,36,0);u32(central,38,0);u32(central,42,file.offset);
   centralChunks.push(central,file.name);
   centralSize+=central.length+file.name.length;
  });
  const end=header(22);
  u32(end,0,0x06054b50);u16(end,4,0);u16(end,6,0);u16(end,8,files.length);u16(end,10,files.length);u32(end,12,centralSize);u32(end,16,localSize);u16(end,20,0);
  return concat([...localChunks,...centralChunks,end],localSize+centralSize+end.length);
 }

 function fiscalArchiveEntries(bundle){
  const files=Array.isArray(bundle?.files)?bundle.files:[],metadata={...bundle};
  delete metadata.files;
  const entries=[
   {name:'LISEZ-MOI.txt',data:'Archive fiscale Piloz\r\n\r\n- documents/ : factures et avoirs au format PDF\r\n- data/ : données fiscales structurées\r\n- manifest.json : inventaire et empreintes\r\n- signature.json : signature AWS KMS et état de vérification\r\n- controle-integrite.json : empreinte du paquet\r\n'},
   {name:'manifest.json',data:JSON.stringify(bundle?.manifest||{},null,2)},
   {name:'signature.json',data:JSON.stringify(bundle?.signature||{},null,2)},
   {name:'controle-integrite.json',data:JSON.stringify({format:bundle?.format,format_version:bundle?.format_version,package_hash:bundle?.package_hash,archive_hash:bundle?.manifest?.archive_hash,signature_status:bundle?.signature?.status},null,2)},
   {name:'archive-metadata.json',data:JSON.stringify(metadata,null,2)}
  ];
  files.forEach((file,index)=>{
   const name=safeName(file?.relative_path,index);
   if(file?.encoding==='base64')entries.push({name,data:base64(file.content)});
   else entries.push({name,data:typeof file?.content==='string'?file.content:JSON.stringify(file?.content??null)});
  });
  return entries;
 }

 const api={create,fiscalArchiveEntries,base64ToBytes:base64};
 global.PilozZip=api;
 if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
