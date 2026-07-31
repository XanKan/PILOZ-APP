(function(global){
  'use strict';

  const modern=global.PilozModern;
  if(!modern)return;

  const legacyRenderRoute=modern.renderRoute;
  const api=()=>global.PilozERP;
  const app=()=>global.PilozApp;
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  }[char]));
  const number=value=>Number.isFinite(Number(value))?Number(value):0;
  const money=(value,currency='EUR')=>new Intl.NumberFormat('fr-FR',{
    style:'currency',currency:currency||'EUR',maximumFractionDigits:2
  }).format(number(value));
  const compactMoney=(value,currency='EUR')=>new Intl.NumberFormat('fr-FR',{
    style:'currency',currency:currency||'EUR',notation:'compact',maximumFractionDigits:1
  }).format(number(value));
  const date=value=>value?new Intl.DateTimeFormat('fr-FR',{dateStyle:'medium'}).format(new Date(`${String(value).slice(0,10)}T12:00:00`)):'—';
  const datetime=value=>value?new Intl.DateTimeFormat('fr-FR',{dateStyle:'short',timeStyle:'short'}).format(new Date(value)):'—';
  const todayLabel=()=>new Intl.DateTimeFormat('fr-FR',{weekday:'long',day:'numeric',month:'long',year:'numeric'}).format(new Date());
  const localIso=value=>`${value.getFullYear()}-${String(value.getMonth()+1).padStart(2,'0')}-${String(value.getDate()).padStart(2,'0')}`;
  const currentState=()=>app()?.getState?.()||{data:{}};
  const currentRoute=()=>String(location.hash||'#dashboard').slice(1).split('?')[0];
  const clientName=(state,id)=>{
    const client=(state.data.clients||[]).find(row=>row.id===id);
    return client?.legal_name||client?.trade_name||[client?.first_name,client?.last_name].filter(Boolean).join(' ')||'Client';
  };
  const icon=name=>{
    const paths={
      chart:'<path d="M4 19V9m6 10V5m6 14v-7m4 7H2"/>',
      wallet:'<path d="M3 7h15a2 2 0 0 1 2 2v9H5a2 2 0 0 1-2-2V7Zm0 0V5a2 2 0 0 1 2-2h11v4m0 5h4"/>',
      clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
      margin:'<path d="m4 16 5-5 4 4 7-8"/><path d="M15 7h5v5"/>',
      document:'<path d="M6 2h8l4 4v16H6z"/><path d="M14 2v5h5M9 12h6m-6 4h6"/>',
      check:'<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>',
      target:'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/><path d="M15 9l5-5"/>',
      pipeline:'<path d="M4 5h7v5H4zM13 14h7v5h-7zM11 7h3a3 3 0 0 1 3 3v4"/>',
      receipt:'<path d="M5 3h14v18l-3-2-2 2-2-2-2 2-2-2-3 2z"/><path d="M9 8h6m-6 4h6"/>',
      warning:'<path d="M12 3 2.5 20h19z"/><path d="M12 9v5m0 3h.01"/>',
      users:'<path d="M16 20v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 20v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
      cart:'<circle cx="9" cy="20" r="1"/><circle cx="19" cy="20" r="1"/><path d="M3 4h2l2.5 11h11l2-7H6"/>',
      box:'<path d="m3 7 9-4 9 4-9 4zM3 7v10l9 4 9-4V7M12 11v10"/>',
      plus:'<path d="M12 5v14M5 12h14"/>',
      refresh:'<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
      sliders:'<path d="M4 6h9m4 0h3M4 12h3m4 0h9M4 18h7m4 0h5"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="13" cy="18" r="2"/>'
    };
    return`<svg class="cockpit-icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths[name]||paths.chart}</svg>`;
  };
  const metricIcons={revenue_ht:'chart',collected:'wallet',outstanding:'clock',gross_margin:'margin',quote_count:'document',accepted_quote_count:'check',conversion_rate:'target',pipeline_weighted:'pipeline',average_invoice_ht:'receipt',overdue_count:'warning',new_clients:'users',purchases_ht:'cart',stock_value:'box',gross_result:'margin'};
  const metricTones={
    revenue_ht:'ocean',collected:'emerald',outstanding:'amber',gross_margin:'violet',
    quote_count:'sky',accepted_quote_count:'emerald',conversion_rate:'violet',pipeline_weighted:'ocean',
    average_invoice_ht:'indigo',overdue_count:'coral',new_clients:'sky',purchases_ht:'amber',
    stock_value:'indigo',gross_result:'violet'
  };

  const periods=[
    ['today','Aujourd’hui'],['current_week','Cette semaine'],['last_7_days','7 derniers jours'],
    ['last_30_days','30 derniers jours'],['current_month','Mois en cours'],
    ['previous_month','Mois précédent'],['current_quarter','Trimestre en cours'],
    ['current_year','Année en cours'],['previous_year','Année précédente'],['custom','Personnalisé']
  ];
  const comparisons=[
    ['previous','Juste avant (ex. juillet → juin)'],
    ['year','Mêmes dates l’année dernière'],
    ['none','Ne pas comparer']
  ];
  const blockDefinitions={
    receivables:{label:'Échéances clients',description:'Balance âgée et factures à traiter'},
    commercial:{label:'Pipeline commercial',description:'Opportunités ouvertes, valeur et prévision pondérée'},
    recent_documents:{label:'Documents récents',description:'Devis, factures, avoirs et achats'},
    customers:{label:'Clients',description:'Nouveaux clients et principaux contributeurs'},
    catalog:{label:'Articles et main d’œuvre',description:'Ventes et marge du catalogue'},
    agenda:{label:'Mon agenda',description:'Activités du jour et prochaines actions'},
    purchases:{label:'Achats',description:'Commandes et réceptions attendues'},
    notifications:{label:'Notifications importantes',description:'Alertes qui nécessitent votre attention'},
    forecast:{label:'Prévisions détaillées',description:'Échéances ouvertes sur 90 jours'}
  };
  const metricDefinitions={
    revenue_ht:{label:'Chiffre d’affaires facturé',short:'Facturé HT',definition:'Factures finalisées HT moins avoirs finalisés sur la période.',route:'sales/invoices'},
    collected:{label:'Montant encaissé',short:'Encaissé',definition:'Paiements confirmés nets des corrections et remboursements.',route:'sales/payments'},
    outstanding:{label:'Reste à encaisser',short:'À encaisser',definition:'Factures ouvertes nettes des paiements et avoirs liés.',route:'sales/due-dates'},
    gross_margin:{label:'Marge brute',short:'Marge brute',definition:'Chiffre d’affaires HT net moins coûts d’achat mémorisés.',route:'reports'},
    quote_count:{label:'Devis émis',short:'Devis émis',definition:'Nombre de devis créés sur la période.',route:'sales/quotes'},
    accepted_quote_count:{label:'Devis acceptés',short:'Devis acceptés',definition:'Devis acceptés ou déjà facturés sur la période.',route:'sales/quotes'},
    conversion_rate:{label:'Taux de transformation',short:'Transformation',definition:'Devis acceptés divisés par les devis ayant reçu une réponse.',route:'crm/pipeline'},
    pipeline_weighted:{label:'Pipeline pondéré',short:'Pipeline pondéré',definition:'Somme des opportunités ouvertes pondérée par leur probabilité de réussite.',route:'crm/pipeline'},
    average_invoice_ht:{label:'Panier moyen',short:'Panier moyen',definition:'Chiffre d’affaires net divisé par le nombre de factures.',route:'sales/invoices'},
    overdue_count:{label:'Factures en retard',short:'En retard',definition:'Factures ouvertes dont l’échéance est dépassée.',route:'sales/due-dates'},
    new_clients:{label:'Nouveaux clients',short:'Nouveaux clients',definition:'Clients créés pendant la période dans votre périmètre autorisé.',route:'sales/clients'},
    purchases_ht:{label:'Achats',short:'Achats HT',definition:'Commandes fournisseurs HT enregistrées pendant la période.',route:'purchases/orders'},
    gross_result:{label:'Résultat brut estimé',short:'Résultat brut',definition:'Chiffre d’affaires HT net moins coûts mémorisés, avant charges de structure.',route:'reports'}
  };
  const allBlocks=Object.keys(blockDefinitions);
  const defaultMetrics=['revenue_ht','collected','pipeline_weighted','outstanding'];
  const roleBlocks={
    owner:['receivables','commercial','recent_documents','customers','catalog','agenda','purchases','notifications'],
    admin:['receivables','commercial','recent_documents','customers','catalog','agenda','purchases','notifications'],
    accounting:['receivables','recent_documents','customers','catalog','agenda','purchases','notifications'],
    sales:['commercial','recent_documents','customers','agenda','notifications'],
    auditor:['receivables','recent_documents','customers','notifications'],
    read_only:['receivables','recent_documents','customers','notifications'],
    member:['commercial','recent_documents','customers','agenda','notifications']
  };

  const ui={
    context:'',data:null,error:'',loading:false,requestId:0,controller:null,
    cache:new Map(),cacheTtl:30000,period:'current_month',comparison:'previous',
    customStart:'',customEnd:'',preferences:null,preferencesReady:false,
    edit:false,draft:null,dragged:'',dropTarget:'',dropSide:'before',
    customDragType:'',customDragKey:'',customDropSide:'before',
    chartMode:'performance',documentTab:'quote',customerMode:'revenue',saving:false,persistTimer:null,onboardingConfirm:false
  };

  function contextKey(state){return`${state.companyId||''}:${global.PilozRuntime?.session?.user_id||''}`;}
  function resetForContext(state){
    const key=contextKey(state);
    if(ui.context===key)return;
    ui.context=key;ui.data=null;ui.error='';ui.loading=false;ui.requestId+=1;
    ui.controller?.abort();ui.controller=null;ui.preferences=null;ui.preferencesReady=false;
    ui.edit=false;ui.draft=null;ui.period='current_month';ui.comparison='previous';ui.customStart='';ui.customEnd='';ui.onboardingConfirm=false;
    ui.customDragType='';ui.customDragKey='';ui.customDropSide='before';
  }
  function cacheKey(state){return[contextKey(state),ui.period,ui.customStart,ui.customEnd,ui.comparison].join('|');}
  function rpcArgs(){return{period_key:ui.period,custom_start:ui.period==='custom'?ui.customStart||null:null,custom_end:ui.period==='custom'?ui.customEnd||null:null,comparison_mode:ui.comparison};}
  function defaultPreference(role='member'){
    return{layout_version:2,visible_blocks:(roleBlocks[role]||roleBlocks.member).slice(),block_order:(roleBlocks[role]||roleBlocks.member).slice(),block_sizes:{},selected_metrics:defaultMetrics.slice(),period_config:{preset:'current_month',comparison:'previous',density:'comfortable'}};
  }
  function normalizePreference(raw,role,stockEnabled=true,purchasesEnabled=true){
    const fallback=defaultPreference(role),source=raw||{},valid=value=>Array.isArray(value)?value.filter(key=>allBlocks.includes(key)):[];
    const visible=valid(source.visible_blocks),order=valid(source.block_order),metrics=(Array.isArray(source.selected_metrics)?source.selected_metrics:[]).filter(key=>metricDefinitions[key]).slice(0,4);
    const chosen=visible.length?visible:fallback.visible_blocks;
    const ordered=[...order.filter(key=>chosen.includes(key)),...chosen.filter(key=>!order.includes(key))];
    const filtered=ordered.filter(key=>(key!=='stock'||stockEnabled)&&(key!=='purchases'||purchasesEnabled));
    return{
      layout_version:Number(source.layout_version)||2,
      visible_blocks:filtered,
      block_order:filtered.slice(),
      block_sizes:source.block_sizes&&typeof source.block_sizes==='object'?{...source.block_sizes}:{},
      selected_metrics:metrics.length?metrics:fallback.selected_metrics.slice(),
      period_config:{...fallback.period_config,...(source.period_config||{})}
    };
  }
  function clonePreference(value){return JSON.parse(JSON.stringify(value));}
  function applyServerPreferences(payload){
    if(ui.preferencesReady)return false;
    const role=payload.role||payload.preferences?.role||'member',stockEnabled=payload.stock?.enabled!==false,purchasesEnabled=payload.purchases?.enabled!==false;
    const pref=normalizePreference(payload.preferences,role,stockEnabled,purchasesEnabled);
    ui.preferences=pref;ui.preferencesReady=true;
    const period=pref.period_config||{},nextPeriod=period.preset||'current_month',nextComparison=period.comparison||'previous';
    const changed=nextPeriod!==ui.period||nextComparison!==ui.comparison||Boolean(period.custom_start&&period.custom_start!==ui.customStart)||Boolean(period.custom_end&&period.custom_end!==ui.customEnd);
    ui.period=nextPeriod;ui.comparison=nextComparison;ui.customStart=period.custom_start||'';ui.customEnd=period.custom_end||'';
    return changed;
  }

  async function load(force=false){
    const state=currentState();resetForContext(state);
    if(!state.companyId||ui.loading)return;
    if(ui.period==='custom'&&(!ui.customStart||!ui.customEnd))return;
    const key=cacheKey(state),cached=ui.cache.get(key);
    if(!force&&cached&&Date.now()-cached.at<ui.cacheTtl){ui.data=cached.data;ui.error='';render(state);return;}
    ui.controller?.abort();const controller=new AbortController(),requestId=++ui.requestId;
    ui.controller=controller;ui.loading=true;ui.error='';render(state);
    try{
      let payload;
      try{payload=await api().rpc('get_dashboard_command_center',rpcArgs(),{signal:controller.signal});}
      catch(error){if(!['PGRST202','42883'].includes(String(error?.code||'')))throw error;payload=await api().rpc('get_dashboard_cockpit',rpcArgs(),{signal:controller.signal});}
      if(requestId!==ui.requestId||controller.signal.aborted)return;
      if(!payload||!payload.summary)throw Object.assign(new Error('Réponse analytique incomplète.'),{code:'invalid_dashboard_response'});
      if(applyServerPreferences(payload)){
        ui.loading=false;ui.controller=null;load(false);return;
      }
      ui.data=payload;ui.cache.set(key,{at:Date.now(),data:payload});ui.error='';
    }catch(error){
      if(error?.name==='AbortError'||controller.signal.aborted)return;
      console.error('[PILOZ Cockpit] Chargement impossible',{status:error?.status||0,code:error?.code||'',message:error?.message||String(error)});
      ui.error=error?.message||'Impossible de charger les indicateurs.';
    }finally{
      if(requestId===ui.requestId){ui.loading=false;ui.controller=null;if(currentRoute()==='dashboard')render(currentState());}
    }
  }
  function invalidate(){ui.cache.clear();ui.data=null;ui.error='';ui.controller?.abort();ui.loading=false;return load(true);}
  function markStale(){ui.cache.clear();ui.data=null;}

  function periodLabel(summary){
    const period=summary?.period;if(!period)return periods.find(row=>row[0]===ui.period)?.[1]||'Période';
    const compared=ui.comparison!=='none'&&period.comparison_start&&period.comparison_end;
    return`Du ${date(period.start)} au ${date(period.end)}${compared?` — comparé avec les résultats du ${date(period.comparison_start)} au ${date(period.comparison_end)}`:''}`;
  }
  function comparisonHelp(summary){
    const period=summary?.period||{};
    if(ui.comparison==='none')return'Aucune autre période ne sera affichée.';
    if(period.comparison_start&&period.comparison_end)return`Référence utilisée : du ${date(period.comparison_start)} au ${date(period.comparison_end)}.`;
    return ui.comparison==='year'?'Les mêmes jours, un an plus tôt.':'La plage de même durée située juste avant.';
  }
  function variation(value){
    if(value===null||value===undefined||!Number.isFinite(Number(value)))return'';
    const numeric=Number(value),tone=numeric>0?'positive':numeric<0?'negative':'neutral';
    return`<span class="cockpit-variation ${tone}">${numeric>0?'↗':numeric<0?'↘':'→'} ${Math.abs(numeric).toLocaleString('fr-FR',{maximumFractionDigits:1})} %</span>`;
  }
  function metricRaw(key,payload){const summary=payload.summary||{};if(key==='new_clients')return payload.customers?.new_clients;if(key==='purchases_ht')return payload.purchases?.period_amount;if(key==='stock_value')return payload.stock?.value;if(key==='gross_result')return summary.gross_margin;if(key==='pipeline_weighted')return payload.crm?.pipeline_weighted;return summary[key];}
  function metricValue(key,payload){
    const summary=payload.summary||{},value=metricRaw(key,payload);
    if(key==='conversion_rate')return value===null||value===undefined?'—':`${number(value).toLocaleString('fr-FR',{maximumFractionDigits:1})} %`;
    if(['quote_count','accepted_quote_count','overdue_count','new_clients'].includes(key))return number(value).toLocaleString('fr-FR');
    return value===null||value===undefined?'—':money(value,summary.currency);
  }
  function metricContext(key,payload){
    const summary=payload.summary||{};
    if(key==='revenue_ht')return`${number(summary.invoice_count)} facture(s) retenue(s)`;
    if(key==='collected')return`${number(summary.average_payment_days).toLocaleString('fr-FR',{maximumFractionDigits:1})} j de délai moyen`;
    if(key==='outstanding')return`${number(summary.overdue_count)} en retard · ${money(summary.overdue_amount,summary.currency)}`;
    if(key==='gross_margin')return summary.margin_rate===null?'Coûts indisponibles':`${number(summary.margin_rate).toLocaleString('fr-FR',{maximumFractionDigits:1})} % du CA HT`;
    if(key==='average_invoice_ht')return`${number(summary.invoice_count)} facture(s)`;
    if(key==='conversion_rate')return`${number(summary.accepted_quote_count)} accepté(s)`;
    if(key==='new_clients')return`${number(payload.customers?.active_clients)} client(s) actif(s)`;
    if(key==='purchases_ht')return`${number(payload.purchases?.open_orders)} commande(s) ouverte(s)`;
    if(key==='stock_value')return`${number(payload.stock?.count)} article(s) sous seuil`;
    if(key==='gross_result')return summary.margin_rate===null?'Coûts indisponibles':`${number(summary.margin_rate).toLocaleString('fr-FR',{maximumFractionDigits:1})} % du CA HT`;
    if(key==='pipeline_weighted')return`${number(payload.crm?.open_opportunities)} opportunité(s) ouverte(s)`;
    return metricDefinitions[key]?.definition||'';
  }
  function visibleMetrics(payload){
    const summary=payload.summary||{};
    const selected=(ui.preferences?.selected_metrics||defaultMetrics).filter(key=>metricDefinitions[key]);
    const permitted=key=>!['gross_margin','gross_result'].includes(key)||summary.permissions?.margin;
    const available=key=>key!=='purchases_ht'||payload.purchases?.enabled!==false;
    const valued=key=>key!=='stock_value'||payload.stock?.enabled!==false&&payload.stock?.value!==null&&payload.stock?.value!==undefined;
    const allowed=selected.filter(key=>permitted(key)&&available(key)&&valued(key));
    for(const key of defaultMetrics)if(allowed.length<4&&!allowed.includes(key)&&permitted(key)&&available(key)&&valued(key))allowed.push(key);
    return allowed.slice(0,4);
  }
  function renderKpis(payload){
    const summary=payload.summary||{};
    const changes={revenue_ht:summary.revenue_change_percent,collected:summary.collected_change_percent};
    return`<section class="cockpit-kpis" aria-label="Indicateurs principaux">${visibleMetrics(payload).map(key=>{
      const definition=metricDefinitions[key],raw=metricRaw(key,payload),empty=raw===null||raw===undefined||number(raw)===0;
      return`<button type="button" class="cockpit-kpi tone-${metricTones[key]||'ocean'} ${empty?'is-zero':''}" data-metric="${esc(key)}" onclick="PilozDashboardCockpit.navigate('${definition.route}')" title="${esc(definition.definition)}"><span class="cockpit-kpi-top"><i>${icon(metricIcons[key])}</i><em>Ouvrir</em></span><span class="cockpit-kpi-label">${esc(definition.label)}</span><strong>${metricValue(key,payload)}</strong><div>${variation(changes[key])}<small>${esc(metricContext(key,payload))}</small></div></button>`;
    }).join('')}</section>`;
  }
  function pulseMetrics(payload){
    const selected=new Set(visibleMetrics(payload));
    const summary=payload.summary||{};
    const permitted=key=>!['gross_margin','gross_result'].includes(key)||summary.permissions?.margin;
    const available=key=>key!=='purchases_ht'||payload.purchases?.enabled!==false;
    return['quote_count','accepted_quote_count','conversion_rate','average_invoice_ht','overdue_count','new_clients','gross_margin','purchases_ht']
      .filter(key=>!selected.has(key)&&permitted(key)&&available(key))
      .slice(0,6);
  }
  function renderPulse(payload){
    const metrics=pulseMetrics(payload);
    if(!metrics.length)return'';
    return`<section class="cockpit-pulse" aria-labelledby="cockpit-pulse-title"><header><div><span>Vue express</span><h2 id="cockpit-pulse-title">Les autres chiffres de la période</h2></div><small>${esc(refreshLabel(payload))}</small></header><div class="cockpit-pulse-grid">${metrics.map(key=>{
      const definition=metricDefinitions[key];
      return`<button type="button" class="cockpit-pulse-card tone-${metricTones[key]||'ocean'}" onclick="PilozDashboardCockpit.navigate('${definition.route}')" title="${esc(definition.definition)}"><i>${icon(metricIcons[key])}</i><span><small>${esc(definition.label)}</small><strong>${metricValue(key,payload)}</strong><em>${esc(metricContext(key,payload))}</em></span></button>`;
    }).join('')}</div></section>`;
  }
  function chartCoordinates(points,key,width,height,min,max){
    const range=Math.max(1,max-min);
    return points.map((point,index)=>({
      x:index/(Math.max(1,points.length-1))*width,
      y:height-((number(point[key])-min)/range*height),
      value:number(point[key])
    }));
  }
  function smoothChartPath(coordinates){
    if(!coordinates.length)return'';
    if(coordinates.length===1)return`M ${coordinates[0].x.toFixed(1)} ${coordinates[0].y.toFixed(1)}`;
    return coordinates.slice(1).reduce((path,current,index)=>{
      const previous=coordinates[index],control=(previous.x+current.x)/2;
      return`${path} C ${control.toFixed(1)} ${previous.y.toFixed(1)}, ${control.toFixed(1)} ${current.y.toFixed(1)}, ${current.x.toFixed(1)} ${current.y.toFixed(1)}`;
    },`M ${coordinates[0].x.toFixed(1)} ${coordinates[0].y.toFixed(1)}`);
  }
  function chartAreaPath(coordinates,height){
    if(!coordinates.length)return'';
    const first=coordinates[0],last=coordinates[coordinates.length-1];
    return`${smoothChartPath(coordinates)} L ${last.x.toFixed(1)} ${height} L ${first.x.toFixed(1)} ${height} Z`;
  }
  function chartSeries(){
    if(ui.chartMode==='invoiced')return[['invoiced','Facturé']];
    if(ui.chartMode==='collected')return[['collected','Encaissé']];
    if(ui.chartMode==='margin')return[['margin','Marge']];
    if(ui.chartMode==='comparison')return[['invoiced','Période actuelle'],['comparison','Période comparée']];
    return[['invoiced','Facturé'],['collected','Encaissé']];
  }
  function renderChart(payload){
    const points=Array.isArray(payload.timeseries)?payload.timeseries:[],summary=payload.summary,currency=summary.currency||'EUR';
    if(!points.length||!points.some(point=>chartSeries().some(([key])=>number(point[key])!==0)))return`<section class="cockpit-chart-panel"><header><div><span>Analyse</span><h2>Performance de l’activité</h2></div>${chartControls(summary)}</header><div class="cockpit-chart-empty"><b>Aucune facture sur cette période.</b><button onclick="PilozDashboardCockpit.setPeriod('current_year')">Voir l’année en cours</button></div>${renderPerformanceSummary(summary)}</section>`;
    const width=800,height=224,left=66,series=chartSeries().filter(([key])=>key!=='margin'||summary.permissions?.margin),chartValues=points.flatMap(point=>series.map(([key])=>number(point[key]))),min=Math.min(0,...chartValues),max=Math.max(0,...chartValues),range=Math.max(1,max-min);
    const labels=[0,Math.floor((points.length-1)/2),points.length-1].filter((value,index,array)=>array.indexOf(value)===index);
    const palette={invoiced:'#10a99b',collected:'#173f68',margin:'#d28a20',comparison:'#7868d4'};
    const coordinates=Object.fromEntries(series.map(([key])=>[key,chartCoordinates(points,key,width,height,min,max)]));
    const definitions=series.map(([key],index)=>`<linearGradient id="cockpit-area-${key}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="${palette[key]||'#10a99b'}" stop-opacity="${index?'0.2':'0.3'}"/><stop offset="100%" stop-color="${palette[key]||'#10a99b'}" stop-opacity="0"/></linearGradient><filter id="cockpit-glow-${key}" x="-20%" y="-30%" width="140%" height="160%"><feDropShadow dx="0" dy="5" stdDeviation="5" flood-color="${palette[key]||'#10a99b'}" flood-opacity=".2"/></filter>`).join('');
    const areas=series.map(([key])=>`<path class="cockpit-chart-area area-${key}" d="${chartAreaPath(coordinates[key],height)}" fill="url(#cockpit-area-${key})"></path>`).join('');
    const paths=series.map(([key,label])=>`<path class="cockpit-chart-line line-${key}" style="--line:${palette[key]||'#10a99b'}" d="${smoothChartPath(coordinates[key])}" filter="url(#cockpit-glow-${key})" vector-effect="non-scaling-stroke"><title>${esc(label)}</title></path>`).join('');
    const dots=points.map((point,index)=>series.map(([key,label])=>{const coordinate=coordinates[key][index],details=[`${date(point.date)} — ${label} : ${money(point[key],currency)}`,`${number(point.invoice_count)} facture(s)`];if(number(point.credits))details.push(`Avoirs : ${money(point.credits,currency)}`);if(number(point.corrections))details.push(`Corrections et remboursements : ${money(point.corrections,currency)}`);return`<circle class="${index===points.length-1?'is-latest':''}" cx="${coordinate.x.toFixed(1)}" cy="${coordinate.y.toFixed(1)}" r="${index===points.length-1?'5':'3.5'}" style="--dot:${palette[key]||'#10a99b'}" tabindex="0"><title>${esc(details.join(' · '))}</title></circle>`;}).join('')).join('');
    const yTicks=[0,.25,.5,.75,1].map(ratio=>({y:height*ratio,value:max-ratio*range}));
    const grid=yTicks.map(row=>`<line x1="0" y1="${row.y.toFixed(1)}" x2="${width}" y2="${row.y.toFixed(1)}"></line>`).join('');
    const yLabels=yTicks.map(row=>`<text class="cockpit-axis-value" x="-14" y="${(row.y+3).toFixed(1)}" text-anchor="end">${esc(compactMoney(row.value,currency))}</text>`).join('');
    const primaryKey=series[0][0],peakIndex=coordinates[primaryKey].reduce((best,row,index,array)=>row.value>array[best].value?index:best,0),peak=coordinates[primaryKey][peakIndex],calloutX=Math.max(4,Math.min(width-116,peak.x-58));
    const peakCallout=`<g class="cockpit-chart-peak" transform="translate(${calloutX.toFixed(1)} ${(Math.max(6,peak.y-43)).toFixed(1)})"><rect width="116" height="29" rx="9"></rect><text x="58" y="18" text-anchor="middle">Pic · ${esc(compactMoney(peak.value,currency))}</text></g>`;
    const accessible=points.map(point=>`<tr><th>${date(point.date)}</th>${series.map(([key])=>`<td>${money(point[key],currency)}</td>`).join('')}</tr>`).join('');
    return`<section class="cockpit-chart-panel"><header><div><span>Analyse</span><h2>Performance de l’activité</h2><p>${esc(periodLabel(summary))}</p></div>${chartControls(summary)}</header><div class="cockpit-chart-legend">${series.map(([key,label])=>`<span><i style="--legend:${palette[key]||'#10a99b'}"></i><span>${esc(label)} <b>${compactMoney(points.reduce((sum,point)=>sum+number(point[key]),0),currency)}</b></span></span>`).join('')}</div><div class="cockpit-chart" role="img" aria-label="Évolution de la performance sur la période"><svg viewBox="0 -18 ${width+left+10} ${height+52}" preserveAspectRatio="xMidYMid meet"><defs>${definitions}</defs><g transform="translate(${left} 0)"><g class="cockpit-chart-grid">${grid}</g>${yLabels}${areas}${paths}${dots}${peakCallout}${labels.map(index=>`<text class="cockpit-axis-date" x="${(index/(Math.max(1,points.length-1))*width).toFixed(1)}" y="${height+28}" text-anchor="${index===0?'start':index===points.length-1?'end':'middle'}">${esc(date(points[index]?.date))}</text>`).join('')}</g></svg></div><div class="cockpit-chart-table sr-only"><table><caption>Données du graphique de performance</caption><thead><tr><th>Date</th>${series.map(([,label])=>`<th>${esc(label)}</th>`).join('')}</tr></thead><tbody>${accessible}</tbody></table></div>${renderPerformanceSummary(summary)}</section>`;
  }
  function chartControls(summary){
    const modes=[['performance','Facturé + encaissé'],['invoiced','Facturé'],['collected','Encaissé'],['comparison','Comparaison']];
    if(summary.permissions?.margin)modes.splice(3,0,['margin','Marge']);
    return`<div class="cockpit-chart-modes" role="group" aria-label="Séries du graphique">${modes.map(([key,label])=>`<button class="${ui.chartMode===key?'active':''}" aria-pressed="${ui.chartMode===key}" onclick="PilozDashboardCockpit.setChartMode('${key}')">${esc(label)}</button>`).join('')}</div>`;
  }
  function renderPerformanceSummary(summary){
    const rate=summary.revenue_ttc?Math.max(0,Math.min(100,number(summary.collected)/number(summary.revenue_ttc)*100)):null;
    const values=[['Factures',number(summary.invoice_count).toLocaleString('fr-FR'),'Nombre de factures finalisées retenues'],['Panier moyen',summary.average_invoice_ht===null?'—':money(summary.average_invoice_ht,summary.currency),'CA HT net divisé par le nombre de factures'],['Délai moyen',`${number(summary.average_payment_days).toLocaleString('fr-FR',{maximumFractionDigits:1})} j`,'Délai moyen entre émission et paiement'],['Taux d’encaissement',rate===null?'—':`${rate.toLocaleString('fr-FR',{maximumFractionDigits:1})} %`,'Encaissements de la période divisés par le montant TTC facturé']];
    return`<div class="cockpit-performance-summary">${values.map(([label,value,definition])=>`<div title="${esc(definition)}"><span>${esc(label)}</span><b>${value}</b></div>`).join('')}</div>`;
  }
  function forecastLabel(key){return{overdue:'Déjà en retard',days_7:'Dans les 7 jours',days_30:'Dans les 30 jours',days_60:'Dans les 60 jours',later:'Après 60 jours'}[key]||key;}
  function renderForecast(forecast,currency){
    const buckets=forecast?.buckets||[],max=Math.max(1,...buckets.map(row=>number(row.amount))),highlights=forecast?.highlights||{};
    return`<aside class="cockpit-forecast"><header><span>Prévision</span><h2>Encaissements à venir</h2><p>Montants attendus, non garantis · échéances et plans ouverts</p></header><strong>${money(forecast?.total,currency)}</strong><div class="cockpit-forecast-highlights">${[['this_week','Cette semaine'],['next_week','Semaine prochaine'],['this_month','Ce mois'],['next_month','Mois prochain']].map(([key,label])=>`<button onclick="PilozDashboardCockpit.navigate('sales/due-dates','${key}')"><span>${label}</span><b>${money(highlights[key],currency)}</b></button>`).join('')}</div><div class="cockpit-forecast-bars">${buckets.map(row=>`<button onclick="PilozDashboardCockpit.navigate('sales/due-dates','${esc(row.key)}')"><span>${esc(forecastLabel(row.key))}<small>${number(row.count)} échéance(s)</small></span><b>${money(row.amount,currency)}</b><i style="--forecast-width:${Math.max(4,number(row.amount)/max*100)}%"></i></button>`).join('')||'<p>Aucune échéance ouverte à prévoir.</p>'}</div><button class="cockpit-text-action" onclick="PilozDashboardCockpit.navigate('sales/due-dates')">Voir les échéances →</button></aside>`;
  }
  function actionLabel(kind){return{overdue_invoice:'Relancer',expiring_quote:'Ouvrir',overdue_activity:'Terminer',accepted_quote:'Convertir',incomplete_draft:'Compléter',low_stock:'Commander',stale_opportunity:'Ouvrir',hot_prospect:'Qualifier'}[kind]||'Ouvrir';}
  function assigneeLabel(id){if(!id)return'Non attribué';return id===global.PilozRuntime?.session?.user_id?'Moi':`Responsable ${String(id).slice(0,8)}`;}
  function renderPriority(actions,currency,canWrite){
    const rows=(actions||[]).slice(0,6);
    return`<section class="cockpit-priority"><header><div><span>Opérationnel</span><h2>À traiter aujourd’hui</h2></div><button onclick="PilozDashboardCockpit.navigate('crm/activities')">Voir toutes les actions</button></header>${rows.length?`<div>${rows.map(row=>`<article class="tone-${esc(row.tone||'info')}"><i aria-hidden="true"></i><span><b>${esc(row.title)}</b><small>${esc(row.detail||'')}${row.date?` · ${date(row.date)}`:''} · ${esc(assigneeLabel(row.assigned_user_id))}</small></span>${number(row.impact)?`<strong>${money(row.impact,currency)}</strong>`:''}<button ${(row.can_write??canWrite)?'':'disabled'} onclick="PilozDashboardCockpit.openPriority('${esc(row.kind)}','${esc(row.id)}')">${esc(actionLabel(row.kind))}</button></article>`).join('')}</div>`:`<div class="cockpit-good-state"><b>Tout est à jour.</b><span>Aucune action urgente n’est détectée pour cette période.</span></div>`}</section>`;
  }

  function frame(key,content){
    const definition=blockDefinitions[key],size=ui.draft?.block_sizes?.[key]||ui.preferences?.block_sizes?.[key]||'normal';
    const edit=ui.edit;
    return`<section class="cockpit-block block-${key} size-${size} ${edit?'editing':''}" data-cockpit-block="${key}" draggable="${edit}" ondragstart="PilozDashboardCockpit.drag(event,'${key}')" ondragover="PilozDashboardCockpit.dragOver(event,'${key}')" ondragleave="PilozDashboardCockpit.dragLeave(event)" ondrop="PilozDashboardCockpit.drop(event,'${key}')" ondragend="PilozDashboardCockpit.endDrag()"><header>${edit?`<button class="cockpit-drag-handle" aria-label="Déplacer ${esc(definition.label)}" title="Glisser pour déplacer" onkeydown="PilozDashboardCockpit.dragKey(event,'${key}')">⠿</button>`:''}<div><h2>${esc(definition.label)}</h2><p>${esc(definition.description)}</p></div>${edit?`<div class="cockpit-block-tools"><button onclick="PilozDashboardCockpit.toggleSize('${key}')" aria-label="Changer la taille de ${esc(definition.label)}">${size==='wide'?'Taille normale':'Agrandir'}</button><button onclick="PilozDashboardCockpit.toggleBlock('${key}')" aria-label="Masquer ${esc(definition.label)}">×</button></div>`:''}</header>${content}</section>`;
  }
  function emptyBlock(text,action=''){return`<div class="cockpit-block-empty"><span>${esc(text)}</span>${action}</div>`;}
  function renderReceivables(data,summary){
    const buckets=data?.buckets||[],max=Math.max(1,...buckets.map(row=>number(row.amount))),oldest=data?.oldest||[];
    return`<div class="cockpit-receivable-head"><div><span>Total à encaisser</span><b>${money(data?.total,summary.currency)}</b></div><div><span>En retard</span><b>${money(summary.overdue_amount,summary.currency)}</b></div><div><span>Factures</span><b>${number(summary.overdue_count)}</b></div><div><span>Retard moyen</span><b>${number(data?.average_delay).toLocaleString('fr-FR',{maximumFractionDigits:1})} j</b></div><div><span>Plus ancien</span><b>${number(data?.oldest_delay)} j</b></div></div><div class="cockpit-aging">${buckets.map(row=>`<button onclick="PilozDashboardCockpit.navigate('sales/due-dates','${row.key}')"><span>${esc(row.label)}</span><b>${money(row.amount,summary.currency)}</b><i style="--aging:${Math.max(3,number(row.amount)/max*100)}%"></i></button>`).join('')}</div>${oldest.length?`<div class="cockpit-due-list">${oldest.slice(0,4).map(row=>`<article><button class="cockpit-due-main" onclick="PilozDashboardCockpit.openDocument('${row.id}')"><span><b>${esc(row.number||'Facture')}</b><small>${esc(clientName(currentState(),row.client_id))} · ${number(row.days)} j de retard</small></span><strong>${money(row.remaining,summary.currency)}</strong></button><div><button ${summary.permissions?.reminders?'':'disabled'} onclick="PilozDashboardCockpit.openDueEmail('${row.id}')">E-mail</button><button class="primary" ${summary.permissions?.payments?'':'disabled'} onclick="PilozDashboardCockpit.openDuePayment('${row.id}')">Saisir un règlement</button></div></article>`).join('')}</div>`:''}`;
  }
  function funnelLabel(key){return{draft:'Créés',sent:'Envoyés',pending:'En attente',accepted:'Acceptés',rejected:'Refusés',invoiced:'Facturés',expired:'Expirés',other:'Autres'}[key]||key;}
  function renderFunnel(data,summary){
    const rows=data?.stages||[],max=Math.max(1,...rows.map(row=>number(row.count))),colors={draft:'#7e8ca0',sent:'#268fca',pending:'#d28a20',accepted:'#139c70',rejected:'#d76363',invoiced:'#7762c9',expired:'#b35d6f',other:'#557084'};
    return rows.length?`<div class="cockpit-funnel">${rows.map(row=>`<button style="--stage-color:${colors[row.key]||colors.other}" onclick="PilozDashboardCockpit.navigate('sales/quotes','${row.key}')"><i style="--funnel:${Math.max(14,number(row.count)/max*100)}%"></i><span>${esc(funnelLabel(row.key))}</span><b>${number(row.count)}</b><small>${money(row.amount,summary.currency)}</small></button>`).join('')}</div><footer><span>Taux de transformation <b>${data.conversion_rate===null?'—':number(data.conversion_rate).toLocaleString('fr-FR',{maximumFractionDigits:1})+' %'}</b></span><span>En attente <b>${money(data.pending_amount,summary.currency)}</b></span><span>Acceptés <b>${money(data.accepted_amount,summary.currency)}</b></span><span>Expirent bientôt <b>${number(data.expiring_soon)}</b></span></footer>`:emptyBlock('Aucun devis sur cette période.');
  }
  function renderCrmPipeline(data,summary){
    const rows=data?.stages||[],max=Math.max(1,...rows.map(row=>number(row.amount)));
    return rows.length?`<div class="cockpit-funnel">${rows.map(row=>`<button style="--stage-color:${esc(row.color||'#0ca99b')}" onclick="PilozDashboardCockpit.navigate('crm/pipeline')"><i style="--funnel:${Math.max(14,number(row.amount)/max*100)}%"></i><span>${esc(row.name)}</span><b>${number(row.count)}</b><small>${money(row.weighted,summary.currency)} pondéré</small></button>`).join('')}</div><footer><span>Pipeline total <b>${money(data.pipeline_total,summary.currency)}</b></span><span>Pipeline pondéré <b>${money(data.pipeline_weighted,summary.currency)}</b></span><span>Opportunités <b>${number(data.open_opportunities)}</b></span><span>À clôturer ce mois <b>${number(data.closing_this_month)}</b></span></footer>`:emptyBlock('Aucune opportunité ouverte.',`<button onclick="PilozDashboardCockpit.quick('opportunity')">Créer une opportunité</button>`);
  }
  function documentTabs(data){
    const tabs=[['quote','Devis'],['invoice','Factures'],['credit_note','Avoirs'],['purchase_invoice','Achats']];
    const types=ui.documentTab==='invoice'?['invoice','deposit_invoice','balance_invoice']:[ui.documentTab];
    const rows=(data||[]).filter(row=>types.includes(row.type)).slice(0,5);
    return`<nav class="cockpit-tabs">${tabs.map(([key,label])=>`<button class="${ui.documentTab===key?'active':''}" onclick="PilozDashboardCockpit.setDocumentTab('${key}')">${esc(label)}</button>`).join('')}</nav>${rows.length?`<div class="cockpit-list">${rows.map(row=>`<button onclick="PilozDashboardCockpit.openDocument('${row.id}')"><span><b>${esc(row.number||'Brouillon')}</b><small>${esc(row.client_name||'Non renseigné')} · ${date(row.issue_date)} · ${esc(assigneeLabel(row.assigned_user_id))}</small></span><em>${esc(row.status||'')}</em><strong>${money(row.total_ttc)}</strong></button>`).join('')}</div>`:emptyBlock('Aucun document récent dans cet onglet.')}<button class="cockpit-text-action" onclick="PilozDashboardCockpit.openDocumentList('${ui.documentTab}')">Voir tous →</button>`;
  }
  function renderCustomers(data,summary){
    const modes=[['revenue','Chiffre d’affaires'],['outstanding','Reste à payer'],['overdue','Retard']];if(data?.can_view_margin)modes.splice(1,0,['margin','Marge']);
    const rows=(data?.top_clients||[]).slice().sort((a,b)=>number(b[ui.customerMode])-number(a[ui.customerMode])).slice(0,5);
    const metricValue=row=>money(row[ui.customerMode],summary.currency);
    return`<div class="cockpit-client-metrics"><span><b>${number(data?.new_clients)}</b>Nouveaux</span><span><b>${number(data?.active_clients)}</b>Actifs</span><span><b>${number(data?.overdue_clients)}</b>En retard</span></div><nav class="cockpit-tabs">${modes.map(([key,label])=>`<button class="${ui.customerMode===key?'active':''}" onclick="PilozDashboardCockpit.setCustomerMode('${key}')">${esc(label)}</button>`).join('')}</nav>${rows.length?`<ol class="cockpit-ranking">${rows.map((row,index)=>`<li><button onclick="PilozDashboardCockpit.openClient('${row.id}')"><i>${index+1}</i><span>${esc(row.name)}<small>${row.share===null||row.share===undefined?'':number(row.share).toLocaleString('fr-FR',{maximumFractionDigits:1})+' % du CA'}</small></span><strong>${metricValue(row)}</strong></button></li>`).join('')}</ol>`:emptyBlock('Aucune activité client sur cette période.')}<button class="cockpit-text-action" onclick="PilozDashboardCockpit.navigate('sales/clients')">Voir les clients →</button>`;
  }
  function renderCatalog(data,summary){
    const rows=data?.items||[];
    const insights=`<div class="cockpit-catalog-metrics"><span><b>${esc(data?.best_seller?.name||'—')}</b>Meilleure vente</span><span><b>${number(data?.never_sold)}</b>Jamais vendus</span><span><b>${number(data?.missing_price)}</b>Sans prix</span></div>`;
    return insights+(rows.length?`<ol class="cockpit-ranking">${rows.slice(0,5).map((row,index)=>`<li><button onclick="PilozDashboardCockpit.openItem('${row.id}')"><i>${index+1}</i><span>${esc(row.name)}<small>${number(row.quantity).toLocaleString('fr-FR')} vendu(s)</small></span><strong>${money(row.revenue,summary.currency)}${data.can_view_margin&&row.margin!==null?`<small>Marge ${money(row.margin,summary.currency)}</small>`:''}</strong></button></li>`).join('')}</ol>`:emptyBlock('Aucun article, aucune main d’œuvre, aucun abonnement ou frais facturé sur cette période.'));
  }
  function renderStock(data,summary){
    const rows=data?.alerts||[];
    const stockSummary=`<div class="cockpit-stock-summary"><span><b>${number(data?.out_of_stock)}</b>En rupture</span><span><b>${number(data?.count)}</b>Sous seuil</span>${data?.value===null||data?.value===undefined?'':`<span><b>${compactMoney(data.value,summary.currency)}</b>Valeur du stock</span>`}</div>`;
    return stockSummary+(rows.length?`<div class="cockpit-list">${rows.slice(0,6).map(row=>`<button onclick="PilozDashboardCockpit.openItem('${row.id}')"><span><b>${esc(row.name)}</b><small>${esc(row.reference||'')} · seuil ${number(row.threshold)} ${esc(row.unit||'')}${number(row.to_receive)>0?` · ${number(row.to_receive)} à recevoir`:''}</small></span><strong class="negative">${number(row.available)} ${esc(row.unit||'')}</strong></button>`).join('')}</div>`:emptyBlock('Aucun article sous son seuil de stock.'));
  }
  function renderAgenda(data,summary){
    const rows=data?.agenda||[];
    return`<div class="cockpit-agenda-summary"><span><b>${number(data?.today)}</b> aujourd’hui</span><span><b>${number(data?.overdue)}</b> en retard</span><span><b>${number(data?.upcoming)}</b> à venir</span></div>${rows.length?`<div class="cockpit-agenda-list">${rows.slice(0,6).map(row=>`<article><button onclick="PilozDashboardCockpit.openActivity('${row.id}','${row.type}')"><span><b>${esc(row.subject)}</b><small>${datetime(row.due_at)} · ${esc(row.type||'activité')}${row.client_id?` · ${esc(clientName(currentState(),row.client_id))}`:''}</small></span><em>${esc(assigneeLabel(row.assigned_user_id))}</em></button>${summary.permissions?.activities?`<button class="cockpit-complete" onclick="PilozDashboardCockpit.completeActivity('${row.id}')">Terminer</button>`:''}</article>`).join('')}</div>`:emptyBlock('Aucune activité planifiée.')}<button class="cockpit-text-action" onclick="PilozDashboardCockpit.navigate('crm/activities')">Voir l’agenda →</button>`;
  }
  function renderPurchases(data,summary){
    return`<div class="cockpit-purchase-summary"><button onclick="PilozDashboardCockpit.navigate('purchases/orders')"><span>Commandes ouvertes</span><b>${number(data?.open_orders)}</b></button><button onclick="PilozDashboardCockpit.navigate('purchases/orders')"><span>Montant engagé</span><b>${money(data?.open_amount,summary.currency)}</b></button><button onclick="PilozDashboardCockpit.navigate('purchases/receipts')"><span>Réceptions attendues</span><b>${number(data?.expected_receipts)}</b></button></div>`;
  }
  function renderNotifications(data){
    const rows=data?.notifications||[];
    return(rows.length?`<div class="cockpit-notifications">${rows.slice(0,3).map(row=>`<article class="severity-${esc(row.severity||'info')}"><i></i><span><b>${esc(row.title)}</b><small>${esc(row.body||'')} · ${datetime(row.created_at)}</small></span></article>`).join('')}</div>`:emptyBlock('Aucune notification importante.'))+`<button class="cockpit-text-action" onclick="PilozDashboardCockpit.showNotifications()">Ouvrir le centre de notifications →</button>`;
  }
  function renderForecastBlock(data,summary){
    const rows=data?.buckets||[];
    return rows.length?`<div class="cockpit-list">${rows.map(row=>`<button onclick="PilozDashboardCockpit.navigate('sales/due-dates','${row.key}')"><span><b>${esc(forecastLabel(row.key))}</b><small>${number(row.count)} échéance(s)</small></span><strong>${money(row.amount,summary.currency)}</strong></button>`).join('')}</div>`:emptyBlock('Aucune échéance ouverte sur l’horizon.');
  }
  function blockContent(key,payload){
    const summary=payload.summary;
    if(key==='receivables')return renderReceivables(payload.receivables,summary);
    if(key==='commercial')return payload.crm?renderCrmPipeline(payload.crm,summary):renderFunnel(payload.funnel,summary);
    if(key==='recent_documents')return documentTabs(payload.recent_documents);
    if(key==='customers')return renderCustomers(payload.customers,summary);
    if(key==='catalog')return renderCatalog(payload.catalog,summary);
    if(key==='stock')return renderStock(payload.stock,summary);
    if(key==='agenda')return renderAgenda(payload.activity,summary);
    if(key==='purchases')return renderPurchases(payload.purchases,summary);
    if(key==='notifications')return renderNotifications(payload.activity);
    if(key==='forecast')return renderForecastBlock(payload.forecast,summary);
    return'';
  }
  function activePreference(){return ui.edit?ui.draft:ui.preferences;}
  function visibleBlocks(payload){
    const preference=activePreference()||defaultPreference(payload.role),visible=new Set(preference.visible_blocks||[]),order=preference.block_order||[];
    const available=key=>allBlocks.includes(key)&&visible.has(key)&&(key!=='purchases'||payload.purchases?.enabled!==false);
    return[...order.filter(available),...allBlocks.filter(key=>available(key)&&!order.includes(key))];
  }
  function renderSecondary(payload){
    const blocks=visibleBlocks(payload);
    if(!blocks.length)return`<section class="cockpit-no-blocks"><b>Aucun bloc secondaire affiché.</b><button onclick="PilozDashboardCockpit.startCustomize()">Ajouter des informations</button></section>`;
    return`<div class="cockpit-secondary">${blocks.map(key=>frame(key,blockContent(key,payload))).join('')}</div>`;
  }
  function renderCustomizer(payload){
    const preference=ui.draft,purchasesEnabled=payload.purchases?.enabled!==false;
    const selectableBlocks=allBlocks.filter(key=>key!=='purchases'||purchasesEnabled);
    const selectableMetrics=Object.entries(metricDefinitions).filter(([key])=>(!['gross_margin','gross_result'].includes(key)||payload.summary?.permissions?.margin)&&(key!=='purchases_ht'||purchasesEnabled));
    const metricMap=Object.fromEntries(selectableMetrics),selectedMetrics=preference.selected_metrics.filter(key=>metricMap[key]),availableMetrics=selectableMetrics.filter(([key])=>!selectedMetrics.includes(key));
    const selectedBlocks=preference.block_order.filter(key=>selectableBlocks.includes(key)&&preference.visible_blocks.includes(key)),availableBlocks=selectableBlocks.filter(key=>!preference.visible_blocks.includes(key));
    const sortable=(type,keys,labelFor)=>`<div class="cockpit-customizer-sort-list">${keys.map((key,index)=>`<div class="cockpit-customizer-sortable" data-customizer-type="${type}" data-customizer-key="${key}" ondragover="PilozDashboardCockpit.customizerDragOver(event,'${type}','${key}')" ondragleave="PilozDashboardCockpit.customizerDragLeave(event)" ondrop="PilozDashboardCockpit.customizerDrop(event,'${type}','${key}')"><span class="cockpit-customizer-grip" tabindex="0" draggable="true" title="Maintenir puis glisser" aria-label="Déplacer ${esc(labelFor(key))}" ondragstart="PilozDashboardCockpit.customizerDrag(event,'${type}','${key}')" ondragend="PilozDashboardCockpit.customizerEndDrag()">⠿</span><label><input type="checkbox" checked onchange="PilozDashboardCockpit.${type==='metric'?'toggleMetric':'toggleBlock'}('${key}')"><span>${esc(labelFor(key))}</span></label><span class="cockpit-customizer-position">${index+1}</span><div class="cockpit-customizer-order"><button type="button" ${index===0?'disabled':''} aria-label="Monter ${esc(labelFor(key))}" onclick="PilozDashboardCockpit.moveCustomizerItem('${type}','${key}',-1)">↑</button><button type="button" ${index===keys.length-1?'disabled':''} aria-label="Descendre ${esc(labelFor(key))}" onclick="PilozDashboardCockpit.moveCustomizerItem('${type}','${key}',1)">↓</button></div></div>`).join('')||'<p class="cockpit-customizer-empty">Aucun élément affiché.</p>'}</div>`;
    const available=(type,rows,labelFor)=>rows.length?`<div class="cockpit-customizer-available"><b>Disponibles</b>${rows.map(row=>{const key=Array.isArray(row)?row[0]:row;return`<label><input type="checkbox" onchange="PilozDashboardCockpit.${type==='metric'?'toggleMetric':'toggleBlock'}('${key}')"><span>${esc(labelFor(key))}</span></label>`;}).join('')}</div>`:'';
    return`<section class="cockpit-customizer" aria-label="Personnalisation du tableau de bord"><header><div><span>Personnalisation</span><h2>Organisez votre espace de pilotage</h2><p>Maintenez la poignée ⠿ puis déposez chaque élément à la place souhaitée. Les flèches restent disponibles sur mobile.</p></div><div><button onclick="PilozDashboardCockpit.cancelCustomize()">Annuler</button><button onclick="PilozDashboardCockpit.resetCustomize()">Disposition par défaut</button><button class="primary" ${ui.saving?'disabled':''} onclick="PilozDashboardCockpit.saveCustomize()">${ui.saving?'Enregistrement…':'Enregistrer'}</button></div></header><div class="cockpit-customizer-grid"><fieldset class="cockpit-customizer-section"><legend>Indicateurs principaux · 4 maximum</legend><p>Glissez les indicateurs pour choisir leur ordre d’affichage.</p>${sortable('metric',selectedMetrics,key=>metricMap[key]?.label||key)}${available('metric',availableMetrics,key=>metricMap[key]?.label||key)}</fieldset><fieldset class="cockpit-customizer-section"><legend>Blocs secondaires</legend><p>Glissez les blocs pour les placer facilement sur le tableau de bord.</p>${sortable('block',selectedBlocks,key=>blockDefinitions[key]?.label||key)}${available('block',availableBlocks,key=>blockDefinitions[key]?.label||key)}</fieldset><fieldset class="cockpit-density-options"><legend>Densité d’affichage</legend>${[['comfortable','Confortable'],['compact','Compacte']].map(([key,label])=>`<label><input type="radio" name="cockpit-density" ${preference.period_config?.density===key?'checked':''} onchange="PilozDashboardCockpit.setDensity('${key}')"><span>${label}</span></label>`).join('')}</fieldset></div></section>`;
  }
  function quickActions(summary){
    const permission=summary.permissions||{},primary=[] ,secondary=[];
    if(permission.sales_documents){primary.push(`<button class="primary" onclick="PilozDashboardCockpit.quick('quote')">${icon('plus')}<span>Créer un devis</span></button>`,`<button onclick="PilozDashboardCockpit.quick('invoice')">${icon('document')}<span>Créer une facture</span></button>`);}
    if(permission.customers)secondary.push(`<button onclick="PilozDashboardCockpit.quick('client')">Ajouter un client</button>`);
    if(permission.payments)secondary.push(`<button onclick="PilozDashboardCockpit.quick('payment')">Saisir un règlement</button>`);
    if(permission.activities)secondary.push(`<button onclick="PilozDashboardCockpit.quick('activity')">Ajouter une activité</button>`);
    if(permission.customers)secondary.push(`<button onclick="PilozDashboardCockpit.quick('prospect')">Ajouter un prospect</button>`);
    if(permission.activities)secondary.push(`<button onclick="PilozDashboardCockpit.quick('opportunity')">Créer une opportunité</button>`);
    if(permission.catalog_write)secondary.push(`<button onclick="PilozDashboardCockpit.quick('item')">Créer un élément du catalogue</button>`);
    if(permission.purchases)secondary.push(`<button onclick="PilozDashboardCockpit.quick('purchase')">Enregistrer un achat</button>`);
    if(!primary.length&&!secondary.length)return'';
    return`<div class="cockpit-quick-actions" aria-label="Actions rapides">${primary.slice(0,2).join('')}${secondary.length?`<details><summary>${icon('plus')}<span>Plus d’actions</span></summary><div>${secondary.join('')}</div></details>`:''}</div>`;
  }
  function scopeLabel(summary){return summary?.scope==='company'?'Toute l’entreprise':'Mes données';}
  function refreshLabel(payload){
    if(!payload?.generated_at)return'Données actualisées';
    const value=new Date(payload.generated_at);
    if(Number.isNaN(value.getTime()))return'Données actualisées';
    return`Actualisé à ${new Intl.DateTimeFormat('fr-FR',{hour:'2-digit',minute:'2-digit'}).format(value)}`;
  }
  function periodShortcuts(){
    const shortcuts=[['last_7_days','7 jours'],['current_month','Ce mois'],['current_quarter','Trimestre'],['current_year','Cette année']];
    return`<nav class="cockpit-period-shortcuts" aria-label="Périodes rapides">${shortcuts.map(([key,label])=>`<button type="button" class="${ui.period===key?'active':''}" aria-pressed="${ui.period===key}" onclick="PilozDashboardCockpit.setPeriod('${key}')">${esc(label)}</button>`).join('')}</nav>`;
  }
  function renderHeader(payload){
    const first=String(payload.first_name||'').trim(),title=first?`Bonjour 👋 ${first}`:'Bonjour 👋';
    return`<header class="cockpit-header"><div class="cockpit-hero"><div class="cockpit-welcome"><span>${esc(todayLabel())}</span><h1>${esc(title)}</h1><p>Voici les éléments qui méritent votre attention aujourd’hui.</p><div class="cockpit-hero-meta"><span class="cockpit-scope-badge">${icon('users')}${esc(scopeLabel(payload.summary))}</span><span>${esc(refreshLabel(payload))}</span><span>${esc(periodLabel(payload.summary))}</span></div></div>${quickActions(payload.summary)}</div><div class="cockpit-filterbar"><div class="cockpit-filterbar-main cockpit-period">${periodShortcuts()}<label class="cockpit-select-field"><span>Autre période</span><select aria-label="Choisir une période" onchange="PilozDashboardCockpit.setPeriod(this.value)">${periods.map(([key,label])=>`<option value="${key}" ${ui.period===key?'selected':''}>${esc(label)}</option>`).join('')}</select></label><label class="cockpit-select-field"><span>Comparaison</span><select aria-label="Choisir une comparaison" onchange="PilozDashboardCockpit.setComparison(this.value)">${comparisons.map(([key,label])=>`<option value="${key}" ${ui.comparison===key?'selected':''}>${esc(label)}</option>`).join('')}</select></label></div>${ui.period==='custom'?`<div class="cockpit-custom-dates"><label>Du<input type="date" value="${esc(ui.customStart)}" max="${esc(ui.customEnd||'')}" onchange="PilozDashboardCockpit.setCustomDate('start',this.value)"></label><label>Au<input type="date" value="${esc(ui.customEnd)}" min="${esc(ui.customStart||'')}" onchange="PilozDashboardCockpit.setCustomDate('end',this.value)"></label></div>`:''}<div class="cockpit-filterbar-actions"><span class="cockpit-comparison-help">${esc(comparisonHelp(payload.summary))}</span><button class="cockpit-icon-button" onclick="PilozDashboardCockpit.refresh()" aria-label="Actualiser le tableau de bord" title="Actualiser">${icon('refresh')}</button><button class="cockpit-customize-button" onclick="PilozDashboardCockpit.startCustomize()">${icon('sliders')}<span>Personnaliser</span></button></div></div></header>`;
  }
  function isNewCompany(payload,state){return number(payload.summary?.invoice_count)===0&&number(payload.summary?.quote_count)===0&&number(payload.activity?.today)===0&&number(payload.activity?.upcoming)===0&&number(payload.crm?.open_opportunities)===0&&(state.data.clients||[]).length===0;}
  function onboardingDismissed(){return ui.preferences?.period_config?.getting_started_dismissed===true;}
  function renderOnboarding(){
    return`<section class="cockpit-onboarding"><button type="button" class="cockpit-onboarding-close" onclick="PilozDashboardCockpit.requestOnboardingDismiss()" aria-label="Masquer les premiers pas" title="Masquer les premiers pas">×</button><div><span>Premiers pas</span><h2>Bienvenue dans Piloz</h2><p>Commencez par créer votre premier client, puis transformez votre activité en devis et en factures.</p></div><div><button onclick="PilozDashboardCockpit.quick('client')">Ajouter un client</button><button class="primary" onclick="PilozDashboardCockpit.quick('quote')">Créer un devis</button><button onclick="PilozDashboardCockpit.quick('item')">Ajouter un élément du catalogue</button></div></section>`;
  }
  function renderOnboardingConfirm(){
    if(!ui.onboardingConfirm)return'';
    return`<div class="cockpit-confirm-backdrop" role="presentation" onclick="if(event.target===this)PilozDashboardCockpit.cancelOnboardingDismiss()"><section class="cockpit-confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="cockpit-dismiss-title"><button type="button" class="cockpit-confirm-close" onclick="PilozDashboardCockpit.cancelOnboardingDismiss()" aria-label="Fermer">×</button><span>Tableau de bord</span><h2 id="cockpit-dismiss-title">Masquer les premiers pas ?</h2><p>Vous accéderez directement à votre tableau de bord. Les raccourcis pour créer vos clients, devis et articles resteront disponibles dans les menus.</p><footer><button type="button" onclick="PilozDashboardCockpit.cancelOnboardingDismiss()">Annuler</button><button type="button" class="primary" onclick="PilozDashboardCockpit.confirmOnboardingDismiss()">Afficher le tableau de bord</button></footer></section></div>`;
  }
  function skeleton(){
    return`<div class="cockpit-shell is-loading" aria-busy="true"><div class="cockpit-skeleton hero"></div><div class="cockpit-skeleton-row">${Array.from({length:4},()=>'<div class="cockpit-skeleton"></div>').join('')}</div><div class="cockpit-skeleton-grid"><div class="cockpit-skeleton chart"></div><div class="cockpit-skeleton chart"></div></div></div>`;
  }
  function renderError(state){
    const main=document.getElementById('main');
    legacyRenderRoute.call(modern,'dashboard',state);
    const warning=document.createElement('div');warning.className='cockpit-server-warning';warning.setAttribute('role','status');
    warning.innerHTML=`<b>Le nouveau cockpit attend la mise à jour Supabase.</b><span>L’ancien tableau de bord reste disponible sans perte de données.</span><button type="button">Réessayer</button>`;
    warning.querySelector('button').addEventListener('click',()=>invalidate());main.prepend(warning);
  }
  function render(state=currentState()){
    resetForContext(state);const main=document.getElementById('main');if(!main)return;
    if(ui.error&&!ui.data){renderError(state);return;}
    if(!ui.data){main.innerHTML=skeleton();if(!ui.loading)setTimeout(()=>load(false),0);return;}
    const payload=ui.data;
    const density=(activePreference()?.period_config?.density||'comfortable');
    const showOnboarding=isNewCompany(payload,state)&&!onboardingDismissed();
    main.innerHTML=`<main class="cockpit-shell density-${esc(density)}">${renderHeader(payload)}${ui.error?`<div class="cockpit-local-error" role="status">Certaines données n’ont pas pu être actualisées. <button onclick="PilozDashboardCockpit.refresh()">Réessayer</button></div>`:''}${ui.edit?renderCustomizer(payload):''}${showOnboarding?renderOnboarding():`${renderKpis(payload)}${renderPulse(payload)}<section class="cockpit-analytics">${renderChart(payload)}${renderForecast(payload.forecast,payload.summary.currency)}</section>${renderPriority(payload.priority_actions,payload.summary.currency,payload.summary.permissions?.write)}${renderSecondary(payload)}`}${renderOnboardingConfirm()}</main>`;
  }

  function setPeriod(value){
    if(!periods.some(row=>row[0]===value))return;
    ui.period=value;
    if(value==='custom'&&(!ui.customStart||!ui.customEnd)){
      const now=new Date();ui.customStart=localIso(new Date(now.getFullYear(),now.getMonth(),1));ui.customEnd=localIso(now);
    }
    schedulePeriodSave();reloadForSelection();
  }
  function setComparison(value){if(!comparisons.some(row=>row[0]===value))return;ui.comparison=value;schedulePeriodSave();reloadForSelection();}
  function setCustomDate(side,value){if(side==='start')ui.customStart=value;else ui.customEnd=value;schedulePeriodSave();clearTimeout(ui.selectionTimer);ui.selectionTimer=setTimeout(reloadForSelection,350);render(currentState());}
  function reloadForSelection(){ui.controller?.abort();ui.loading=false;ui.data=null;ui.error='';render(currentState());}
  function setChartMode(value){if(!['performance','invoiced','collected','margin','comparison'].includes(value))return;ui.chartMode=value;render(currentState());}
  function setDocumentTab(value){ui.documentTab=value;render(currentState());}
  function setCustomerMode(value){if(!['revenue','margin','outstanding','overdue'].includes(value))return;ui.customerMode=value;render(currentState());}

  function startCustomize(){if(!ui.preferences)return;ui.edit=true;ui.draft=clonePreference(ui.preferences);render(currentState());}
  function cancelCustomize(){ui.edit=false;ui.draft=null;endDrag();customizerEndDrag();render(currentState());}
  function resetCustomize(){if(!ui.draft)return;ui.draft=defaultPreference(ui.data?.role||'member');if(ui.data?.stock?.enabled===false)ui.draft.visible_blocks=ui.draft.visible_blocks.filter(key=>key!=='stock');if(ui.data?.purchases?.enabled===false)ui.draft.visible_blocks=ui.draft.visible_blocks.filter(key=>key!=='purchases');ui.draft.block_order=ui.draft.visible_blocks.slice();render(currentState());}
  function toggleMetric(key){
    if(!ui.draft||!metricDefinitions[key])return;
    const index=ui.draft.selected_metrics.indexOf(key);
    if(index>=0)ui.draft.selected_metrics.splice(index,1);
    else if(ui.draft.selected_metrics.length<4)ui.draft.selected_metrics.push(key);
    else{global.toast?.('Choisissez quatre indicateurs maximum.');return;}
    render(currentState());
  }
  function toggleBlock(key){
    if(!ui.draft||!blockDefinitions[key])return;
    const index=ui.draft.visible_blocks.indexOf(key);
    if(index>=0){ui.draft.visible_blocks.splice(index,1);ui.draft.block_order=ui.draft.block_order.filter(item=>item!==key);}
    else{ui.draft.visible_blocks.push(key);ui.draft.block_order.push(key);}
    render(currentState());
  }
  function toggleSize(key){if(!ui.draft)return;ui.draft.block_sizes[key]=ui.draft.block_sizes[key]==='wide'?'normal':'wide';render(currentState());}
  function setDensity(value){if(!ui.draft||!['comfortable','compact'].includes(value))return;ui.draft.period_config={...(ui.draft.period_config||{}),density:value};render(currentState());}
  function drag(event,key){if(!ui.edit)return;ui.dragged=key;event.dataTransfer.effectAllowed='move';event.dataTransfer.setData('text/plain',key);event.currentTarget.classList.add('dragging');}
  function dragOver(event,key){if(!ui.dragged||ui.dragged===key)return;event.preventDefault();const rect=event.currentTarget.getBoundingClientRect();ui.dropTarget=key;ui.dropSide=event.clientY<rect.top+rect.height/2?'before':'after';document.querySelectorAll('.cockpit-block.drop-before,.cockpit-block.drop-after').forEach(node=>node.classList.remove('drop-before','drop-after'));event.currentTarget.classList.add(ui.dropSide==='before'?'drop-before':'drop-after');}
  function dragLeave(event){if(event.currentTarget.contains(event.relatedTarget))return;event.currentTarget.classList.remove('drop-before','drop-after');}
  function drop(event,key){event.preventDefault();const dragged=ui.dragged||event.dataTransfer.getData('text/plain'),order=ui.draft?.block_order;if(!order||dragged===key){endDrag();return;}const from=order.indexOf(dragged);if(from<0){endDrag();return;}order.splice(from,1);const target=order.indexOf(key);order.splice(target+(ui.dropSide==='after'?1:0),0,dragged);endDrag();render(currentState());}
  function endDrag(){ui.dragged='';ui.dropTarget='';document.querySelectorAll('.cockpit-block.dragging,.cockpit-block.drop-before,.cockpit-block.drop-after').forEach(node=>node.classList.remove('dragging','drop-before','drop-after'));}
  function dragKey(event,key){
    if(!ui.draft||!event.altKey||!['ArrowUp','ArrowDown'].includes(event.key))return;
    event.preventDefault();const order=ui.draft.block_order,index=order.indexOf(key),target=index+(event.key==='ArrowUp'?-1:1);
    if(target<0||target>=order.length)return;[order[index],order[target]]=[order[target],order[index]];render(currentState());requestAnimationFrame(()=>document.querySelector(`[data-cockpit-block="${key}"] .cockpit-drag-handle`)?.focus());
  }
  function customizerDrag(event,type,key){
    if(!ui.draft||!['metric','block'].includes(type))return;
    ui.customDragType=type;ui.customDragKey=key;ui.customDropSide='before';
    if(event.dataTransfer){event.dataTransfer.effectAllowed='move';event.dataTransfer.setData('text/plain',`${type}:${key}`);}
    event.currentTarget.closest('.cockpit-customizer-sortable')?.classList.add('dragging');
  }
  function customizerDragOver(event,type,key){
    if(!ui.customDragKey||ui.customDragType!==type||ui.customDragKey===key)return;
    event.preventDefault();
    if(event.dataTransfer)event.dataTransfer.dropEffect='move';
    const rect=event.currentTarget.getBoundingClientRect();ui.customDropSide=event.clientY<rect.top+rect.height/2?'before':'after';
    document.querySelectorAll('.cockpit-customizer-sortable.drop-before,.cockpit-customizer-sortable.drop-after').forEach(node=>node.classList.remove('drop-before','drop-after'));
    event.currentTarget.classList.add(ui.customDropSide==='before'?'drop-before':'drop-after');
  }
  function customizerDragLeave(event){if(event.currentTarget.contains(event.relatedTarget))return;event.currentTarget.classList.remove('drop-before','drop-after');}
  function customizerDrop(event,type,key){
    event.preventDefault();
    if(!ui.draft||ui.customDragType!==type){customizerEndDrag();return;}
    const order=type==='metric'?ui.draft.selected_metrics:ui.draft.block_order,dragged=ui.customDragKey;
    if(!order||dragged===key){customizerEndDrag();return;}
    const from=order.indexOf(dragged);if(from<0){customizerEndDrag();return;}
    order.splice(from,1);const target=order.indexOf(key);order.splice(target+(ui.customDropSide==='after'?1:0),0,dragged);
    customizerEndDrag();render(currentState());
  }
  function customizerEndDrag(){
    ui.customDragType='';ui.customDragKey='';ui.customDropSide='before';
    document.querySelectorAll('.cockpit-customizer-sortable.dragging,.cockpit-customizer-sortable.drop-before,.cockpit-customizer-sortable.drop-after').forEach(node=>node.classList.remove('dragging','drop-before','drop-after'));
  }
  function moveCustomizerItem(type,key,direction){
    if(!ui.draft||!['metric','block'].includes(type)||![1,-1].includes(Number(direction)))return;
    const order=type==='metric'?ui.draft.selected_metrics:ui.draft.block_order,index=order.indexOf(key),target=index+Number(direction);
    if(index<0||target<0||target>=order.length)return;
    [order[index],order[target]]=[order[target],order[index]];render(currentState());
    requestAnimationFrame(()=>document.querySelector(`[data-customizer-type="${type}"][data-customizer-key="${key}"] .cockpit-customizer-grip`)?.focus());
  }
  async function persistPreference(preference,quiet=false){
    const config={...(preference.period_config||{}),preset:ui.period,comparison:ui.comparison,custom_start:ui.customStart||null,custom_end:ui.customEnd||null};
    const result=await api().rpc('save_dashboard_preferences',{
      target_layout_version:2,target_visible_blocks:preference.visible_blocks,target_block_order:preference.block_order,
      target_block_sizes:preference.block_sizes,target_selected_metrics:preference.selected_metrics,target_period_config:config
    });
    ui.preferences=normalizePreference(result||{...preference,period_config:config},ui.data?.role||'member',ui.data?.stock?.enabled!==false,ui.data?.purchases?.enabled!==false);
    if(ui.data)ui.data.preferences=result;
    if(!quiet)global.toast?.('Tableau de bord enregistré.');
  }
  async function saveCustomize(){
    if(!ui.draft||ui.saving)return;ui.saving=true;render(currentState());
    try{await persistPreference(ui.draft);ui.edit=false;ui.draft=null;}
    catch(error){console.error('[PILOZ Cockpit] Préférences non enregistrées',{status:error?.status||0,code:error?.code||'',message:error?.message||String(error)});global.toast?.('La disposition n’a pas pu être enregistrée.');}
    finally{ui.saving=false;render(currentState());}
  }
  function requestOnboardingDismiss(){
    if(ui.saving)return;ui.onboardingConfirm=true;render(currentState());
    requestAnimationFrame(()=>document.querySelector('.cockpit-confirm-dialog .primary')?.focus());
  }
  function cancelOnboardingDismiss(){if(ui.saving)return;ui.onboardingConfirm=false;render(currentState());}
  async function confirmOnboardingDismiss(){
    if(ui.saving||!ui.preferences)return;
    const previous=clonePreference(ui.preferences),next=clonePreference(ui.preferences);
    next.period_config={...(next.period_config||{}),getting_started_dismissed:true};
    ui.saving=true;ui.onboardingConfirm=false;ui.preferences=next;render(currentState());
    try{await persistPreference(next,true);global.toast?.('Les premiers pas ont été masqués.');}
    catch(error){
      console.error('[PILOZ Cockpit] Masquage des premiers pas non enregistré',{status:error?.status||0,code:error?.code||'',message:error?.message||String(error)});
      ui.preferences=previous;ui.onboardingConfirm=true;global.toast?.('Le choix n’a pas pu être enregistré.');
    }finally{ui.saving=false;render(currentState());}
  }
  function schedulePeriodSave(){
    if(!ui.preferencesReady||!ui.preferences)return;clearTimeout(ui.persistTimer);
    ui.persistTimer=setTimeout(()=>persistPreference(ui.preferences,true).catch(error=>console.error('[PILOZ Cockpit] Période non enregistrée',{code:error?.code||'',message:error?.message||String(error)})),500);
  }

  function navigate(route,filter=''){
    if(filter)sessionStorage.setItem('piloz:dashboard-filter',JSON.stringify({route,filter,created_at:Date.now()}));
    if(route==='sales/due-dates'&&global.PilozCommercialWorkspace?.ui){
      global.PilozCommercialWorkspace.ui.activityFilter=filter==='overdue'||filter==='days_1_15'||filter==='days_16_30'||filter==='days_31_60'||filter==='days_60_plus'?'late':filter==='paid'?'paid':'open';
    }
    app().go(route);
    if(['sales/quotes','sales/invoices'].includes(route)&&global.PilozDocumentViewerV2){
      const tab=filter||'all',period=ui.data?.summary?.period;
      setTimeout(()=>{
        global.PilozDocumentViewerV2.setTab?.(tab);
        if(period?.start&&period?.end){
          global.PilozDocumentViewerV2.setFilter?.('issueFrom',period.start);
          global.PilozDocumentViewerV2.setFilter?.('issueTo',period.end);
        }
      },30);
    }
  }
  function openDocument(id){if(global.PilozDocumentViewerV2?.open)global.PilozDocumentViewerV2.open(id);else app().editDocument(id);}
  function openDueEmail(id){if(global.PilozCommercialWorkspace?.openDueEmail)global.PilozCommercialWorkspace.openDueEmail(id);else openDocument(id);}
  function openDuePayment(id){if(global.PilozCommercialWorkspace?.openDuePayment)global.PilozCommercialWorkspace.openDuePayment(id);else openDocument(id);}
  function openDocumentList(type){navigate(type==='quote'?'sales/quotes':type==='purchase_invoice'?'purchases/invoices':'sales/invoices',type);}
  function openClient(id){if(global.PilozCommercialWorkspace?.openClient)global.PilozCommercialWorkspace.openClient(id);else navigate(`sales/clients/${id}`);}
  function openItem(id){navigate(`sales/items/${id}`);}
  function openActivity(id,type='task'){global.PilozCommercialWorkspace?.openActivity?.('',type,id);}
  function completeActivity(id){global.PilozCommercialWorkspace?.quickActivity?.(id,'complete');}
  function showNotifications(){global.PilozCommercialWorkspace?.showNotifications?.();}
  function openPriority(kind,id){if(kind==='overdue_invoice'&&global.PilozCommercialWorkspace?.openDueEmail)global.PilozCommercialWorkspace.openDueEmail(id);else if(['expiring_quote','accepted_quote','incomplete_draft'].includes(kind))openDocument(id);else if(kind==='overdue_activity')global.PilozCRM?.completeActivity?.(id);else if(kind==='stale_opportunity')global.PilozCRM?.openOpportunity?.(id);else if(kind==='hot_prospect')global.PilozCRM?.openProspect?.(id);else if(kind==='low_stock'){if(app().newPurchaseOrder)app().newPurchaseOrder();else openItem(id);}}
  function quick(kind){
    if(kind==='quote'||kind==='invoice'){app().newDocument(kind);return;}
    if(kind==='client'){if(global.PilozClients?.openClientCreator)global.PilozClients.openClientCreator();else app().openPartnerForm('clients',true);return;}
    if(kind==='payment'){navigate('sales/due-dates','unpaid');return;}
    if(kind==='activity'){global.PilozCRM?.openActivityForm?.();return;}
    if(kind==='prospect'){global.PilozCRM?.openProspectForm?.();return;}
    if(kind==='opportunity'){global.PilozCRM?.openOpportunityForm?.();return;}
    if(kind==='item'){navigate('sales/catalog/new');return;}
    if(kind==='purchase'){app().newPurchaseOrder?.();}
  }
  function refresh(){return invalidate();}
  function renderRoute(routeName,state){if(routeName==='dashboard'){render(state);return true;}return legacyRenderRoute.call(modern,routeName,state);}

  modern.renderRoute=renderRoute;
  global.PilozDashboardCockpit={
    ui,render,load,refresh,invalidate,markStale,setPeriod,setComparison,setCustomDate,setChartMode,setDocumentTab,setCustomerMode,
    startCustomize,cancelCustomize,resetCustomize,toggleMetric,toggleBlock,toggleSize,setDensity,saveCustomize,
    requestOnboardingDismiss,cancelOnboardingDismiss,confirmOnboardingDismiss,
    drag,dragOver,dragLeave,drop,endDrag,dragKey,customizerDrag,customizerDragOver,customizerDragLeave,customizerDrop,customizerEndDrag,moveCustomizerItem,navigate,openDocument,openDueEmail,openDuePayment,openDocumentList,openClient,
    openItem,openActivity,completeActivity,showNotifications,openPriority,quick
  };
  global.PilozDashboardCockpit.resetForContext=resetForContext;
})(window);
