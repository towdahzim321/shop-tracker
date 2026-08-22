// Tests the Supabase-backed rewrite of shop-tracker.html against an in-memory
// mock of the database + RPC functions (never the owner's real Supabase
// project). The mock lives in Node (so it survives page.goto() reloads,
// letting us test local caching honestly) and the page talks to it through
// window.__sbBackend, an exposeBinding function - the same technique the
// original resilience-test.js used for window.storage.
const { chromium } = require('playwright');
const path = require('path');
const FILE = 'file://' + path.resolve(__dirname, 'index.html');
let failures = 0;
const check = (n, c, x) => { if (c) console.log('  PASS  ' + n); else { failures++; console.log('  FAIL  ' + n + (x ? ' :: ' + x : '')); } };

// ---------------------------------------------------------------------------
// Mock backend (Node side)
// ---------------------------------------------------------------------------
// Mirrors the SQL clean_model_key(): trimmed, inner whitespace collapsed,
// lowercased - must match the app's own cleanModelKey() and the real
// database function exactly, or "near match"/duplicate tests would pass here
// while behaving differently for real.
function cleanKey(s){ return String(s==null?'':s).trim().replace(/\s+/g,' ').toLowerCase(); }

function createBackend(){
  let networkDown = false;
  const db = {
    staff: [], admins: [], authUsers: [], phones: [], daily_logs: [], business_days: [], ledger: [], shop_resets: [],
    settings: { low_stock_threshold: 3 },
    // Every real deployment always has these three shops, seeded by part 5's
    // migration itself - so every test gets them for free rather than having
    // to remember to seed shops before the staff picker can show anything.
    shops: [
      {id:'harare', name:'Harare CBD', active:true, sort_order:1},
      {id:'bulawayo1', name:'Bulawayo Shop 1', active:true, sort_order:2},
      {id:'bulawayo2', name:'Bulawayo Shop 2', active:true, sort_order:3}
    ],
    models: [
      {id:'m1', name:'Galaxy A55', name_key:'galaxy a55', brand:'Samsung', active:true, created_by:null, created_at:new Date(0).toISOString()}
    ]
  };
  let session = null;
  let idc = 1;
  const nid = () => 'id' + (idc++);
  const nowIso = () => new Date(Date.now() + (idc++)).toISOString();
  const err = (msg) => ({ message: msg, code: 'P0001' });
  function isAdmin(){ return !!(session && db.admins.find(a=>a.user_id===session.userId)); }
  function adminUsername(){ const a = session && db.admins.find(x=>x.user_id===session.userId); return a ? a.username : 'admin'; }

  // Pinned to the REAL phones_staff_view's exact column list (confirmed
  // against the live schema dump), not "everything except cost_price" - that
  // was more generous than reality and let a client bug (comparing on bare
  // imei because it had no model_key to compare against) pass 46/46 anyway,
  // since the mock was quietly handing back fields the real view never did.
  function phoneStaffRow(p){
    return {
      id: p.id, shop_id: p.shop_id, imei: p.imei, model: p.model, description: p.description,
      batch_id: p.batch_id, status: p.status, date_received: p.date_received, received_ts: p.received_ts,
      received_by: p.received_by, sale_price: p.sale_price, sold_by: p.sold_by, date_sold: p.date_sold,
      sold_ts: p.sold_ts, below_price: p.below_price, price_shortfall: p.price_shortfall,
      return_reason: p.return_reason, fault_parts: p.fault_parts, return_notes: p.return_notes,
      date_returned: p.date_returned, returned_ts: p.returned_ts, repaired_at: p.repaired_at,
      repaired_by: p.repaired_by, written_off_at: p.written_off_at, written_off_by: p.written_off_by,
      date_written_off: p.date_written_off, list_price: p.list_price
    };
  }
  function ledgerStaffRow(l){ if(l.type==='price_set') return null; return { ...l, price: l.type==='written_off' ? null : l.price }; }

  function applyFilters(rows, filters){
    return rows.filter(r => filters.every(f => f.op==='eq' ? r[f.col]===f.val : (f.op==='in' ? f.val.includes(r[f.col]) : true)));
  }
  function runQuery(state){
    if(networkDown) throw new Error('network down');
    let rows;
    if(state.table==='phones'){ if(!isAdmin()) throw new Error('permission denied'); rows = db.phones; }
    else if(state.table==='phones_staff_view'){ rows = db.phones.map(phoneStaffRow); }
    else if(state.table==='ledger'){ if(!isAdmin()) throw new Error('permission denied'); rows = db.ledger; }
    else if(state.table==='ledger_staff_view'){ rows = db.ledger.map(ledgerStaffRow).filter(Boolean); }
    else if(state.table==='daily_logs'){ rows = db.daily_logs; }
    else if(state.table==='business_days'){ rows = db.business_days; }
    else if(state.table==='staff'){ rows = db.staff.map(s=>({id:s.id, name:s.name, shop_id:s.shop_id, active:s.active})); }
    // Mirrors the real staff_public view (security-staff-pins work): same
    // redacted column set as 'staff' above, minus pin_hash - added so
    // loadStaffList/ensureStaffNames (which query staff_public, not staff
    // directly, since RLS blocks anon reads on the raw table) can be tested.
    else if(state.table==='staff_public'){ rows = db.staff.map(s=>({id:s.id, name:s.name, shop_id:s.shop_id, active:s.active})); }
    else if(state.table==='admins'){ rows = db.admins; }
    else if(state.table==='settings'){ rows = [{ id:true, low_stock_threshold: db.settings.low_stock_threshold }]; }
    else if(state.table==='shop_resets'){ if(!isAdmin()) throw new Error('permission denied'); rows = db.shop_resets; }
    else if(state.table==='shops'){ rows = db.shops; }
    else if(state.table==='models'){ rows = db.models; }
    else rows = [];

    if(state.method==='update'){
      if(state.table==='settings'){
        if(!isAdmin()) throw new Error('permission denied');
        db.settings.low_stock_threshold = state.updateData.low_stock_threshold;
        return { data:null, error:null };
      }
      return { data:null, error:{message:'unsupported update'} };
    }
    rows = applyFilters(rows, state.filters);
    if(state.order) rows = rows.slice().sort((a,b)=>{
      const av=a[state.order.col], bv=b[state.order.col];
      const c = av<bv?-1:(av>bv?1:0);
      return state.order.ascending ? c : -c;
    });
    if(state.limit) rows = rows.slice(0, state.limit);
    if(state.single){
      if(rows.length===0) return { data:null, error:{message:'no rows'} };
      return { data: rows[0], error:null };
    }
    return { data: rows, error:null };
  }

  const RPCS = {
    staff_login({p_staff_id, p_pin}){
      const s = db.staff.find(x=>x.id===p_staff_id && x.active && x.pin===p_pin);
      return { data: s ? [{id:s.id, name:s.name, shop_id:s.shop_id}] : [], error:null };
    },
    staff_receive_stock({p_shop_id, p_staff_id, p_local_date, p_items}){
      const staff = db.staff.find(x=>x.id===p_staff_id && x.shop_id===p_shop_id && x.active);
      if(!staff) return { data:null, error: err('Staff member not recognised for this shop.') };
      const day = db.business_days.find(b=>b.shop_id===p_shop_id && b.date===p_local_date);
      if(!day || day.status!=='open') return { data:null, error: err("Today's business day is not open. Open it before adding entries.") };
      // Duplicate check is (imei, model), not imei alone: two different real
      // phones can legitimately share an IMEI across different models. Named
      // per model in the refusal so staff know exactly what to fix, and
      // checked against both existing stock AND repeats within this same
      // document (mirrors the real unique index catching both cases).
      const seenInDoc = new Set();
      for(const it of p_items){
        const key = cleanKey(it.model);
        for(const imei of it.imeis){
          const pairKey = imei + '|' + key;
          if(seenInDoc.has(pairKey)) return { data:null, error: err('Already recorded: '+imei+' ('+it.model+')') };
          seenInDoc.add(pairKey);
          if(db.phones.some(ph=>ph.imei===imei && ph.model_key===key)) return { data:null, error: err('Already recorded: '+imei+' ('+it.model+')') };
        }
      }
      let count = 0;
      p_items.forEach(it=>{
        const batch = nid();
        const key = cleanKey(it.model);
        // Staff typing a model that isn't on the list yet creates it, same
        // transaction, same as the real staff_receive_stock function.
        if(!db.models.some(m=>m.name_key===key)){
          db.models.push({id:nid(), name:it.model, name_key:key, brand:null, active:true, created_by:p_staff_id, created_at:nowIso()});
        }
        it.imeis.forEach(imei=>{
          const rec = {id:nid(), shop_id:p_shop_id, imei, model:it.model, model_key:key, description: it.description||null, batch_id:batch,
            cost_price:null, list_price:null, status:'in_stock', date_received:p_local_date, received_ts:nowIso(), received_by:p_staff_id,
            sale_price:null, sold_by:null, date_sold:null, sold_ts:null, below_price:false, price_shortfall:0,
            return_reason:null, fault_parts:null, return_notes:null, date_returned:null, returned_ts:null,
            repaired_at:null, repaired_by:null, written_off_at:null, written_off_by:null, date_written_off:null};
          db.phones.push(rec);
          db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'received', phone_id:rec.id, model:rec.model, description:rec.description, imei:rec.imei, price:null, by_staff:p_staff_id, by_admin:null, note:null, extra:{batchId:batch}});
          count++;
        });
      });
      return { data: count, error:null };
    },
    staff_sell_phone({p_shop_id, p_staff_id, p_local_date, p_phone_id, p_price}){
      const staff = db.staff.find(x=>x.id===p_staff_id && x.shop_id===p_shop_id && x.active);
      if(!staff) return { data:null, error: err('Staff member not recognised for this shop.') };
      const day = db.business_days.find(b=>b.shop_id===p_shop_id && b.date===p_local_date);
      if(!day || day.status!=='open') return { data:null, error: err("Today's business day is not open. Open it before adding entries.") };
      const ph = db.phones.find(x=>x.id===p_phone_id && x.shop_id===p_shop_id);
      if(!ph) return { data:null, error: err('This phone is no longer on the system. Ask the owner to check.') };
      if(ph.status!=='in_stock') return { data:null, error: err('This phone is no longer available for sale.') };
      let below=false, short=0;
      if(ph.list_price!=null && p_price < ph.list_price){ below=true; short = Math.round((ph.list_price-p_price)*100)/100; }
      Object.assign(ph, {status:'sold', sale_price:p_price, sold_by:p_staff_id, date_sold:p_local_date, sold_ts:nowIso(), below_price:below, price_shortfall:short});
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'sold', phone_id:ph.id, model:ph.model, description:ph.description, imei:ph.imei, price:p_price, by_staff:p_staff_id, by_admin:null, note:null, extra:{belowPrice:below, shortfall:short}});
      return { data:null, error:null };
    },
    staff_return_phone({p_shop_id, p_staff_id, p_local_date, p_phone_id, p_reason, p_fault_parts, p_notes}){
      const staff = db.staff.find(x=>x.id===p_staff_id && x.shop_id===p_shop_id && x.active);
      if(!staff) return { data:null, error: err('Staff member not recognised for this shop.') };
      const day = db.business_days.find(b=>b.shop_id===p_shop_id && b.date===p_local_date);
      if(!day || day.status!=='open') return { data:null, error: err("Today's business day is not open. Open it before adding entries.") };
      const ph = db.phones.find(x=>x.id===p_phone_id && x.shop_id===p_shop_id);
      if(!ph) return { data:null, error: err('This phone is no longer on the system.') };
      if(ph.status!=='sold') return { data:null, error: err('This phone is not currently marked as sold.') };
      const faulty = p_reason==='Faulty';
      Object.assign(ph, {status: faulty?'faulty':'in_stock', return_reason:p_reason, fault_parts:p_fault_parts, return_notes:p_notes, date_returned:p_local_date, returned_ts:nowIso()});
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'returned', phone_id:ph.id, model:ph.model, description:ph.description, imei:ph.imei, price:null, by_staff:p_staff_id, by_admin:null, note:null, extra:{reason:p_reason, faultParts:p_fault_parts, notes:p_notes, toFaulty:faulty}});
      return { data:null, error:null };
    },
    staff_submit_eod({p_shop_id, p_staff_id, p_local_date, p_physical_count, p_faulty_count, p_cash}){
      const staff = db.staff.find(x=>x.id===p_staff_id && x.shop_id===p_shop_id && x.active);
      if(!staff) return { data:null, error: err('Staff member not recognised for this shop.') };
      const day = db.business_days.find(b=>b.shop_id===p_shop_id && b.date===p_local_date);
      if(!day || day.status!=='open') return { data:null, error: err("Today's business day is not open. Open it before adding entries.") };
      let log = db.daily_logs.find(l=>l.shop_id===p_shop_id && l.date===p_local_date);
      const resubmit = !!log;
      if(!log){ log = {shop_id:p_shop_id, date:p_local_date, confirmed:false, confirmed_by:null, confirmed_at:null, resubmitted:0, previous_counts:[], adjustments:[]}; db.daily_logs.push(log); }
      else { log.previous_counts = (log.previous_counts||[]).concat([{physicalCount:log.physical_count, faultyCount:log.faulty_count, cash:log.cash, submittedBy:(db.staff.find(s=>s.id===log.submitted_by)||{}).name, timestamp: Date.parse(log.submitted_at)}]); log.resubmitted = (log.resubmitted||0)+1; }
      Object.assign(log, {physical_count:p_physical_count, faulty_count:p_faulty_count, cash:p_cash, submitted_by:p_staff_id, submitted_at:nowIso()});
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'eod', phone_id:null, model:null, description:null, imei:null, price:null, by_staff:p_staff_id, by_admin:null,
        note:'End of day: '+p_physical_count+' good, '+p_faulty_count+' faulty, '+p_cash+' cash'+(resubmit?' (replaced an earlier submission)':''), extra:null});
      return { data:null, error:null };
    },
    // Mirrors the real staff_recent_daily_logs (security-staff-pins work):
    // one shop's daily_logs, last 60 days, newest first. Added so
    // refreshShopData's non-admin path - which calls this RPC instead of
    // reading daily_logs directly, since anon can no longer read that table
    // wide-open - has something to talk to in tests.
    staff_recent_daily_logs({p_shop_id}){
      const cutoff = new Date(); cutoff.setDate(cutoff.getDate() - 60);
      const cutoffStr = cutoff.toISOString().slice(0,10);
      const rows = db.daily_logs
        .filter(l=>l.shop_id===p_shop_id && l.date >= cutoffStr)
        .slice().sort((a,b)=> b.date.localeCompare(a.date));
      return { data: rows, error:null };
    },
    staff_open_day({p_shop_id, p_staff_id, p_local_date}){
      const staff = db.staff.find(x=>x.id===p_staff_id && x.shop_id===p_shop_id && x.active);
      if(!staff) return { data:null, error: err('Staff member not recognised for this shop.') };
      openOrReopenDay(p_shop_id, p_local_date, staff.name, false);
      return { data:null, error:null };
    },
    staff_close_day({p_shop_id, p_staff_id, p_local_date}){
      const staff = db.staff.find(x=>x.id===p_staff_id && x.shop_id===p_shop_id && x.active);
      if(!staff) return { data:null, error: err('Staff member not recognised for this shop.') };
      const day = db.business_days.find(b=>b.shop_id===p_shop_id && b.date===p_local_date && b.status==='open');
      if(!day) return { data:null, error: err("Today's business day is not open.") };
      day.status='closed'; day.closed_by=staff.name; day.closed_at=nowIso();
      day.closing_stock = db.phones.filter(p=>p.shop_id===p_shop_id && p.status==='in_stock').length;
      day.closing_faulty = db.phones.filter(p=>p.shop_id===p_shop_id && p.status==='faulty').length;
      return { data:null, error:null };
    },
    admin_reopen_day({p_shop_id, p_date}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      openOrReopenDay(p_shop_id, p_date, adminUsername(), true);
      return { data:null, error:null };
    },
    admin_undo_sale({p_phone_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const ph = db.phones.find(p=>p.id===p_phone_id);
      if(!ph) return { data:null, error: err('Phone not found.') };
      db.ledger.push({id:nid(), shop_id:ph.shop_id, ts:nowIso(), type:'undo_sale', phone_id:ph.id, model:ph.model, description:ph.description, imei:ph.imei, price:ph.sale_price, by_staff:null, by_admin:adminUsername(), note:'Sale undone by admin', extra:null});
      Object.assign(ph, {status:'in_stock', sale_price:null, sold_by:null, date_sold:null, sold_ts:null, below_price:false, price_shortfall:0});
      return { data:null, error:null };
    },
    admin_undo_return({p_phone_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const ph = db.phones.find(p=>p.id===p_phone_id);
      if(!ph) return { data:null, error: err('Phone not found.') };
      db.ledger.push({id:nid(), shop_id:ph.shop_id, ts:nowIso(), type:'undo_return', phone_id:ph.id, model:ph.model, description:ph.description, imei:ph.imei, price:null, by_staff:null, by_admin:adminUsername(), note:'Return undone by admin', extra:{reason:ph.return_reason}});
      Object.assign(ph, {status:'sold', return_reason:null, date_returned:null, returned_ts:null, fault_parts:null, return_notes:null});
      return { data:null, error:null };
    },
    admin_mark_repaired({p_phone_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const ph = db.phones.find(p=>p.id===p_phone_id);
      if(!ph) return { data:null, error: err('Phone not found.') };
      db.ledger.push({id:nid(), shop_id:ph.shop_id, ts:nowIso(), type:'repaired', phone_id:ph.id, model:ph.model, description:ph.description, imei:ph.imei, price:null, by_staff:null, by_admin:adminUsername(), note:'Repaired, returned to sellable stock', extra:{faultParts:ph.fault_parts}});
      Object.assign(ph, {status:'in_stock', repaired_at:nowIso(), repaired_by:adminUsername(), sale_price:null, date_sold:null, sold_ts:null, sold_by:null, below_price:false, price_shortfall:0});
      return { data:null, error:null };
    },
    admin_write_off({p_phone_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const ph = db.phones.find(p=>p.id===p_phone_id);
      if(!ph) return { data:null, error: err('Phone not found.') };
      db.ledger.push({id:nid(), shop_id:ph.shop_id, ts:nowIso(), type:'written_off', phone_id:ph.id, model:ph.model, description:ph.description, imei:ph.imei, price:ph.cost_price, by_staff:null, by_admin:adminUsername(), note:'Written off as a loss', extra:{faultParts:ph.fault_parts}});
      Object.assign(ph, {status:'written_off', written_off_at:nowIso(), written_off_by:adminUsername(), date_written_off: ph.date_returned || '2026-01-01'});
      return { data:null, error:null };
    },
    admin_delete_phone({p_phone_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const idx = db.phones.findIndex(p=>p.id===p_phone_id);
      if(idx<0) return { data:null, error: err('Phone not found.') };
      const ph = db.phones[idx];
      db.ledger.push({id:nid(), shop_id:ph.shop_id, ts:nowIso(), type:'deleted', phone_id:ph.id, model:ph.model, description:ph.description, imei:ph.imei, price:null, by_staff:null, by_admin:adminUsername(), note:'Stock entry deleted by admin', extra:null});
      db.phones.splice(idx,1);
      return { data:null, error:null };
    },
    admin_delete_log({p_shop_id, p_date}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'deleted_eod', phone_id:null, model:null, description:null, imei:null, price:null, by_staff:null, by_admin:adminUsername(), note:'End of day log for '+p_date+' deleted by admin', extra:null});
      db.daily_logs = db.daily_logs.filter(l=>!(l.shop_id===p_shop_id && l.date===p_date));
      return { data:null, error:null };
    },
    admin_confirm_cash({p_shop_id, p_date}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const log = db.daily_logs.find(l=>l.shop_id===p_shop_id && l.date===p_date);
      if(!log) return { data:null, error: err('No end of day log found for this date.') };
      Object.assign(log, {confirmed:true, confirmed_by:adminUsername(), confirmed_at:nowIso()});
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'cash_confirmed', phone_id:null, model:null, description:null, imei:null, price:null, by_staff:null, by_admin:adminUsername(), note:'Confirmed cash seen for '+p_date+': '+log.cash, extra:null});
      return { data:null, error:null };
    },
    admin_cash_adjustment({p_shop_id, p_date, p_amount, p_reason}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const log = db.daily_logs.find(l=>l.shop_id===p_shop_id && l.date===p_date);
      if(!log) return { data:null, error: err('No end of day log found for this date.') };
      log.adjustments = (log.adjustments||[]).concat([{amount:p_amount, reason:p_reason, ts:Date.now(), by:adminUsername()}]);
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'cash_adjustment', phone_id:null, model:null, description:null, imei:null, price:p_amount, by_staff:null, by_admin:adminUsername(), note:'Cash adjustment on '+p_date+': '+p_amount+' - '+p_reason, extra:null});
      return { data:null, error:null };
    },
    admin_set_pricing_batch({p_shop_id, p_batch_id, p_cost, p_list}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      let count=0, model='';
      db.phones.forEach(p=>{
        if(p.shop_id===p_shop_id && p.batch_id===p_batch_id){
          p.cost_price=p_cost; p.list_price=p_list; count++; model=p.model;
          if(p.status==='sold' && p.sale_price!=null){
            if(p.sale_price < p_list){ p.below_price=true; p.price_shortfall = Math.round((p_list-p.sale_price)*100)/100; }
            else { p.below_price=false; p.price_shortfall=0; }
          }
        }
      });
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'price_set', phone_id:null, model, description:null, imei:null, price:null, by_staff:null, by_admin:adminUsername(), note:'Prices set for '+count+' phone(s): Dubai '+p_cost+' / Zim '+p_list, extra:{batchId:p_batch_id}});
      return { data: count, error:null };
    },
    admin_set_staff_pin({p_shop_id, p_name, p_pin}){
      if(!isAdmin()) return { data:null, error: err('admin only') };
      const rec = {id:nid(), shop_id:p_shop_id, name:p_name, pin:p_pin, active:true};
      db.staff.push(rec);
      return { data: rec.id, error:null };
    },
    admin_reset_staff_pin({p_staff_id, p_new_pin}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const s = db.staff.find(x=>x.id===p_staff_id);
      if(!s) return { data:null, error: err('Staff not found.') };
      s.pin = p_new_pin; s.active = true;
      return { data:null, error:null };
    },
    admin_deactivate_staff({p_staff_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const s = db.staff.find(x=>x.id===p_staff_id);
      if(s) s.active = false;
      return { data:null, error:null };
    },
    admin_wipe_shop_data({p_shop_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const counts = {
        phones: db.phones.filter(p=>p.shop_id===p_shop_id).length,
        ledger: db.ledger.filter(l=>l.shop_id===p_shop_id).length,
        dailyLogs: db.daily_logs.filter(l=>l.shop_id===p_shop_id).length,
        businessDays: db.business_days.filter(b=>b.shop_id===p_shop_id).length,
      };
      db.phones = db.phones.filter(p=>p.shop_id!==p_shop_id);
      db.ledger = db.ledger.filter(l=>l.shop_id!==p_shop_id);
      db.daily_logs = db.daily_logs.filter(l=>l.shop_id!==p_shop_id);
      db.business_days = db.business_days.filter(b=>b.shop_id!==p_shop_id);
      db.shop_resets.push({id:nid(), shop_id:p_shop_id, wiped_by:adminUsername(), wiped_at:nowIso(),
        phones_removed:counts.phones, ledger_removed:counts.ledger, daily_logs_removed:counts.dailyLogs, business_days_removed:counts.businessDays});
      return { data: counts, error:null };
    },
    admin_add_shop({p_name}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      if(!p_name || !p_name.trim()) return { data:null, error: err('Shop name is required.') };
      if(db.shops.some(s=>s.name.toLowerCase()===p_name.trim().toLowerCase())) return { data:null, error: err('A shop with this name already exists.') };
      let base = p_name.trim().toLowerCase().replace(/[^a-z0-9]+/g,'');
      if(!base) return { data:null, error: err('Shop name must contain at least one letter or number.') };
      let id = base, suffix = 0;
      while(db.shops.some(s=>s.id===id)){ suffix++; id = base + suffix; }
      const nextOrder = db.shops.reduce((a,s)=>Math.max(a,s.sort_order||0),0) + 1;
      db.shops.push({id, name:p_name.trim(), active:true, sort_order:nextOrder});
      db.ledger.push({id:nid(), shop_id:id, ts:nowIso(), type:'shop_added', phone_id:null, model:null, description:null, imei:null, price:null, by_staff:null, by_admin:adminUsername(), note:'Added shop "'+p_name.trim()+'" ('+id+')', extra:null});
      return { data: id, error:null };
    },
    admin_rename_shop({p_shop_id, p_new_name}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      if(!p_new_name || !p_new_name.trim()) return { data:null, error: err('Shop name is required.') };
      const shop = db.shops.find(s=>s.id===p_shop_id);
      if(!shop) return { data:null, error: err('Shop not found.') };
      if(db.shops.some(s=>s.id!==p_shop_id && s.name.toLowerCase()===p_new_name.trim().toLowerCase())) return { data:null, error: err('A shop with this name already exists.') };
      const oldName = shop.name;
      shop.name = p_new_name.trim();
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'shop_renamed', phone_id:null, model:null, description:null, imei:null, price:null, by_staff:null, by_admin:adminUsername(), note:'Renamed shop "'+oldName+'" to "'+shop.name+'"', extra:null});
      return { data:null, error:null };
    },
    admin_close_shop({p_shop_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const shop = db.shops.find(s=>s.id===p_shop_id);
      if(!shop) return { data:null, error: err('Shop not found.') };
      if(!shop.active) return { data:null, error: err('Shop is already closed.') };
      shop.active = false;
      db.ledger.push({id:nid(), shop_id:p_shop_id, ts:nowIso(), type:'shop_closed', phone_id:null, model:null, description:null, imei:null, price:null, by_staff:null, by_admin:adminUsername(), note:'Closed shop "'+shop.name+'"', extra:null});
      return { data:null, error:null };
    },
    admin_rename_model({p_model_id, p_new_name}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      if(!p_new_name || !p_new_name.trim()) return { data:null, error: err('Model name is required.') };
      const model = db.models.find(m=>m.id===p_model_id);
      if(!model) return { data:null, error: err('Model not found.') };
      const newKey = cleanKey(p_new_name);
      if(db.models.some(m=>m.id!==p_model_id && m.name_key===newKey)) return { data:null, error: err('Another model with this name already exists.') };
      model.name = p_new_name.trim(); model.name_key = newKey;
      return { data:null, error:null };
    },
    admin_set_model_brand({p_model_id, p_brand}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const model = db.models.find(m=>m.id===p_model_id);
      if(!model) return { data:null, error: err('Model not found.') };
      model.brand = (p_brand && p_brand.trim()) ? p_brand.trim() : null;
      return { data:null, error:null };
    },
    admin_hide_model({p_model_id}){
      if(!isAdmin()) return { data:null, error: err('Admin only.') };
      const model = db.models.find(m=>m.id===p_model_id);
      if(!model) return { data:null, error: err('Model not found.') };
      const inUse = db.phones.filter(p=>p.model_key===model.name_key).length;
      if(inUse > 0) return { data:null, error: err('Cannot hide "'+model.name+'": '+inUse+' phone(s) still reference this model.') };
      model.active = false;
      return { data:null, error:null };
    }
  };
  function openOrReopenDay(shopId, date, who, isAdminActor){
    let day = db.business_days.find(b=>b.shop_id===shopId && b.date===date);
    const wasClosed = !!(day && day.status==='closed');
    const eodExists = !!db.daily_logs.find(l=>l.shop_id===shopId && l.date===date);
    if(!day){ day = {shop_id:shopId, date, status:'open', opened_by:who, opened_at:nowIso(), closed_by:null, closed_at:null, reopen_count:0, last_reopen_by:null, last_reopen_at:null}; db.business_days.push(day); }
    else {
      day.status='open'; day.opened_by=who; day.opened_at=nowIso(); day.closed_by=null; day.closed_at=null;
      if(wasClosed && eodExists){ day.reopen_count=(day.reopen_count||0)+1; day.last_reopen_by=who; day.last_reopen_at=nowIso(); }
    }
    if(wasClosed && eodExists){
      db.ledger.push({id:nid(), shop_id:shopId, ts:nowIso(), type:'reopen', phone_id:null, model:null, description:null, imei:null, price:null,
        by_staff: isAdminActor?null:db.staff.find(s=>s.name===who && s.shop_id===shopId)?.id, by_admin: isAdminActor?who:null,
        note:'Day '+date+' reopened after end of day was submitted', extra:null});
    }
  }

  return {
    db,
    setNetworkDown(v){ networkDown = v; },
    seed({staff, admins, authUsers, models}){
      (staff||[]).forEach(s=>db.staff.push(s));
      (admins||[]).forEach(a=>db.admins.push(a));
      (authUsers||[]).forEach(a=>db.authUsers.push(a));
      (models||[]).forEach(m=>db.models.push(m));
    },
    async handle(argStr){
      const req = JSON.parse(argStr);
      try{
        if(req.kind==='query') return JSON.stringify(runQuery(req.state));
        if(req.kind==='rpc'){
          if(networkDown) throw new Error('network down');
          const fn = RPCS[req.name];
          if(!fn) return JSON.stringify({data:null, error:{message:'unknown rpc '+req.name}});
          return JSON.stringify(fn(req.params||{}));
        }
        if(req.kind==='signIn'){
          if(networkDown) throw new Error('network down');
          const acc = db.authUsers.find(u=>u.email===req.creds.email && u.password===req.creds.password);
          if(!acc) return JSON.stringify({data:null, error:{message:'Invalid login credentials'}});
          session = {userId: acc.id};
          return JSON.stringify({data:{user:{id:acc.id}}, error:null});
        }
        if(req.kind==='signOut'){ session=null; return JSON.stringify({data:null, error:null}); }
        if(req.kind==='getSession'){ return JSON.stringify({data:{session: session?{user:{id:session.userId}}:null}, error:null}); }
      }catch(e){
        return JSON.stringify({data:null, error:{message:e.message}});
      }
      return JSON.stringify({data:null, error:{message:'unhandled request kind'}});
    }
  };
}

const MOCK_INIT = `
window.__SB_OVERRIDE__ = (function(){
  function makeBuilder(table){
    const state = { table, method:'select', filters:[], order:null, limit:null, single:false, updateData:null };
    const builder = {
      select(){ return builder; },
      update(obj){ state.method='update'; state.updateData=obj; return builder; },
      eq(col,val){ state.filters.push({op:'eq',col,val}); return builder; },
      in(col,val){ state.filters.push({op:'in',col,val}); return builder; },
      order(col,opts){ state.order = {col, ascending: !opts || opts.ascending !== false}; return builder; },
      limit(n){ state.limit=n; return builder; },
      single(){ state.single=true; return builder; },
      then(resolve, reject){
        window.__sbBackend(JSON.stringify({kind:'query', state})).then(r=>resolve(JSON.parse(r))).catch(reject);
      }
    };
    return builder;
  }
  return {
    from: (table) => makeBuilder(table),
    rpc: (name, params) => window.__sbBackend(JSON.stringify({kind:'rpc', name, params})).then(r=>JSON.parse(r)),
    auth: {
      signInWithPassword: (creds) => window.__sbBackend(JSON.stringify({kind:'signIn', creds})).then(r=>JSON.parse(r)),
      signOut: () => window.__sbBackend(JSON.stringify({kind:'signOut'})).then(r=>JSON.parse(r)),
      getSession: () => window.__sbBackend(JSON.stringify({kind:'getSession'})).then(r=>JSON.parse(r))
    },
    channel: () => { const ch = { on(){return ch;}, subscribe(){return ch;} }; return ch; }
  };
})();
`;

async function newCtx(browser, backend){
  const ctx = await browser.newContext({ viewport: { width: 390, height: 900 } });
  await ctx.exposeBinding('__sbBackend', async (_source, argStr) => backend.handle(argStr));
  await ctx.addInitScript(MOCK_INIT);
  const page = await ctx.newPage();
  page.__errors = [];
  page.on('pageerror', e => page.__errors.push(e.message));
  return page;
}
const tap = async (page, txt) => {
  const ex = page.locator(`button:text-is("${txt}"), .btn:text-is("${txt}"), .link-btn:text-is("${txt}"), .tab:text-is("${txt}"), .model:text-is("${txt}"), .reason-btn:text-is("${txt}")`);
  if (await ex.count()) await ex.first().click();
  else await page.locator(`.btn:has-text("${txt}"), .link-btn:has-text("${txt}"), .list-item:has-text("${txt}"), .reason-btn:has-text("${txt}")`).first().click();
  await page.waitForTimeout(150);
};
const today = () => { const d = new Date(); return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0'); };

(async () => {
  const browser = await chromium.launch();

  // ===========================================================================
  console.log('\n== A. Staff sign-in: shop -> personal name -> personal PIN ==');
  let backend = createBackend();
  backend.seed({ staff: [ {id:'s1', shop_id:'harare', name:'Tendai', pin:'4821', active:true} ] });
  let page = await newCtx(browser, backend);
  await page.goto(FILE); await page.waitForTimeout(400);
  await tap(page, 'Staff entry'); await tap(page, 'Harare CBD');
  let t = await page.locator('#app').innerText();
  check('staff picker lists staff by name, no shared code prompt', /Tendai/.test(t) && !/shop code/i.test(t), t.slice(0,150));
  await tap(page, 'Tendai');
  await page.fill('#pinInput', '0000'); await tap(page, 'Continue');
  t = await page.locator('#app').innerText();
  check('wrong personal PIN is rejected', /not correct/i.test(t));
  await page.fill('#pinInput', '4821'); await tap(page, 'Continue');
  t = await page.locator('#app').innerText();
  check('correct personal PIN signs in', /Signed in as Tendai/.test(t), t.slice(0,150));
  check('no uncaught JS errors so far', page.__errors.length===0, page.__errors.join(' | '));

  console.log('\n== B. Business day gate + receive stock + duplicate IMEI rejected server-side ==');
  await tap(page, "Open today's business day");
  t = await page.locator('#app').innerText();
  check('day now shows open', /is open/.test(t));
  await tap(page, 'Received new stock');
  t = await page.locator('#app').innerText();
  check('receiving stock opens straight to a tap-to-pick model list, not a text box', /What model is this/.test(t) && /Galaxy A55/.test(t), t.slice(0,200));
  await tap(page, 'Galaxy A55'); await page.fill('#recvQty', '2');
  await tap(page, 'Next: enter IMEIs');
  const rows = page.locator('.imeiRow');
  await rows.nth(0).fill('111111111111111');
  await rows.nth(1).fill('222222222222222');
  await tap(page, 'Add this item to the document');
  await tap(page, 'Finish: save document to stock');
  t = await page.locator('#app').innerText();
  check('2 phones added to stock', /2 phone\(s\) added to stock/.test(t), t.slice(0,150));
  check('mock database actually has 2 phones now', backend.db.phones.length===2, 'count='+backend.db.phones.length);

  await tap(page, 'Back to menu');
  await tap(page, 'Received new stock');
  await tap(page, 'Galaxy A55'); await page.fill('#recvQty', '1');
  await tap(page, 'Next: enter IMEIs');
  await page.locator('.imeiRow').first().fill('111111111111111'); // already exists
  await tap(page, 'Add this item to the document');
  t = await page.locator('#app').innerText();
  check('client catches the duplicate immediately, before it even reaches Finish', /already recorded/i.test(t), t.slice(0,200));
  check('nothing extra was added', backend.db.phones.length===2, 'count='+backend.db.phones.length);

  // Not every model shows up in the pick-list (older/unusual devices), so
  // there must always be a manual fallback that still works. (Two "Back"
  // taps: lineImeis's own Back drops to the lineDetails form, then that
  // screen's topbar Back is the real navBack() that returns to the menu.)
  await tap(page, 'Back');
  await tap(page, 'Back');
  await tap(page, 'Received new stock');
  await tap(page, 'Not listed - type it in');
  t = await page.locator('#app').innerText();
  check('"Not listed" reveals a free-text model box with a way back to the list', /Choose from list instead/.test(t), t.slice(0,200));
  await page.fill('#recvModel', 'Nokia 3310');
  t = await page.locator('#app').innerText();
  await tap(page, 'Choose from list instead');
  t = await page.locator('#app').innerText();
  check('switching back to the list returns to the model grid', /What model is this/.test(t), t.slice(0,200));
  await tap(page, 'Back');

  // The client-side check just above (line ~536) proved confirmLine() blocks
  // a genuine repeat. This proves the other half: it must NOT block a
  // same-IMEI, different-model entry either - that's a real, different phone
  // and staff would be stuck unable to record it if the client's own
  // duplicate check doesn't understand model the same way the server does.
  // Uses a manually-typed model (not the picker) since this mock only ever
  // seeds Galaxy A55 - and a model distinct from the iPhone 12 used in the
  // server-only checks below, so this doesn't collide with those.
  await tap(page, 'Received new stock');
  await tap(page, 'Not listed - type it in');
  await page.fill('#recvModel', 'iPhone 13');
  await page.fill('#recvQty', '1');
  await tap(page, 'Next: enter IMEIs');
  await page.locator('.imeiRow').first().fill('111111111111111'); // same IMEI as the Galaxy A55 already in stock
  await tap(page, 'Add this item to the document');
  t = await page.locator('#app').innerText();
  check('same IMEI + a different model is accepted by the CLIENT check, not flagged as already recorded', !/already recorded/i.test(t) && /Items in this document/.test(t), t.slice(0,300));
  await tap(page, 'Finish: save document to stock');
  t = await page.locator('#app').innerText();
  check('the client-accepted phone actually saved', /1 phone\(s\) added to stock/.test(t), t.slice(0,150));
  check('mock database now has the same IMEI recorded under two different models', backend.db.phones.filter(p=>p.imei==='111111111111111').length===2, JSON.stringify(backend.db.phones.filter(p=>p.imei==='111111111111111').map(p=>p.model)));

  // The client-side check above only catches duplicates against data this
  // device already has loaded. Prove the *database* independently enforces
  // the real rule - (imei, model), not imei alone - the scenario this
  // protects against is two shops racing to record the same IMEI within the
  // same few seconds.
  const sameModelResult = JSON.parse(await backend.handle(JSON.stringify({kind:'rpc', name:'staff_receive_stock',
    params:{p_shop_id:'harare', p_staff_id:'s1', p_local_date: today(), p_items:[{model:'Galaxy A55', description:'', imeis:['111111111111111']}]}})));
  check('same IMEI + same model is still refused, independent of the client', sameModelResult.error && /Already recorded: 111111111111111 \(Galaxy A55\)/.test(sameModelResult.error.message), JSON.stringify(sameModelResult));

  const diffModelResult = JSON.parse(await backend.handle(JSON.stringify({kind:'rpc', name:'staff_receive_stock',
    params:{p_shop_id:'harare', p_staff_id:'s1', p_local_date: today(), p_items:[{model:'iPhone 12', description:'', imeis:['111111111111111']}]}})));
  check('same IMEI + a DIFFERENT model is accepted - two real phones can share an IMEI across models', !diffModelResult.error, JSON.stringify(diffModelResult));
  check('the accepted phone is actually on record under the new model', backend.db.phones.some(p=>p.imei==='111111111111111' && p.model==='iPhone 12'), JSON.stringify(backend.db.phones.filter(p=>p.imei==='111111111111111').map(p=>p.model)));

  console.log('\n== C. Sale: belowPrice computed server-side from a price staff never sees ==');
  backend.db.phones[0].list_price = 200; // owner sets Zim price directly in the mock, staff never touches this
  await page.reload(); await page.waitForTimeout(400); // staff session is only in-memory S - reload signs out, that's expected
  await tap(page, 'Staff entry'); await tap(page, 'Harare CBD'); await tap(page, 'Tendai');
  await page.fill('#pinInput', '4821'); await tap(page, 'Continue');
  t = await page.locator('#app').innerText();
  check('staff view of the phone never shows a cost price field', !/Dubai/.test(t));
  await tap(page, 'Sold a phone');
  await tap(page, 'Galaxy A55');
  t = await page.locator('#app').innerText();
  check('staff DOES see the Zim (selling) price as a helpful prompt', /Zim price: \$200/.test(t), t.slice(0,200));
  await page.fill('#priceInput', '150');
  await tap(page, 'Confirm sale');
  t = await page.locator('#app').innerText();
  check('sale recorded', /Sale recorded/.test(t));
  const soldPhone = backend.db.phones.find(p=>p.status==='sold');
  check('belowPrice + shortfall computed correctly server-side (200-150=50)', soldPhone.below_price===true && soldPhone.price_shortfall===50, JSON.stringify(soldPhone));

  console.log('\n== D. Return -> faulty shelf, and stock sheet still works for staff without cost data ==');
  await tap(page, 'Continue');
  await tap(page, 'Client return'); await tap(page, 'Galaxy A55');
  await tap(page, 'Faulty');
  await tap(page, 'Screen/LCD');
  await tap(page, 'Confirm return');
  t = await page.locator('#app').innerText();
  check('faulty return routed to the faulty shelf', /faulty shelf/i.test(t));

  console.log('\n== D2. Printable stock sheet works for staff (needs full history, minus cost) ==');
  await tap(page, 'Continue');
  await tap(page, 'Daily stock sheet (print)');
  t = await page.locator('#app').innerText();
  check('sheet renders for staff with no crash', /Daily stock sheet/.test(t) && page.__errors.length===0, t.slice(0,120));
  check('sheet shows the received/sold movement correctly', /Galaxy A55/.test(t) && /2/.test(t), t.slice(0,400));
  check('sheet never mentions Dubai/cost price to staff', !/Dubai/i.test(t));
  await tap(page, 'Back');

  console.log('\n== D3. Shop dashboard has a print button covering stock/faulty/recent activity ==');
  await tap(page, 'Shop dashboard');
  t = await page.locator('#app').innerText();
  check('dashboard shows the sections a printout needs', /Stock levels/.test(t) && /Faulty shelf/.test(t) && /Recent sales/.test(t), t.slice(0,300));
  let printCalled = await page.evaluate(() => { window.__printCalled = false; window.print = () => { window.__printCalled = true; }; return true; });
  await tap(page, 'Print this dashboard');
  printCalled = await page.evaluate(() => window.__printCalled);
  check('the print button actually triggers the browser print dialog', printCalled===true);
  await tap(page, 'Back');

  console.log('\n== E. End of day + resubmission history ==');
  await tap(page, 'End of day: count & cash');
  await page.fill('#eodCount', '1'); await page.fill('#eodFaulty', '1'); await page.fill('#eodCash', '150');
  await tap(page, 'Submit end of day');
  t = await page.locator('#app').innerText();
  check('EOD submitted', /submitted/i.test(t));
  await tap(page, 'Continue');
  await tap(page, 'End of day: count & cash');
  await page.fill('#eodCount', '1'); await page.fill('#eodFaulty', '1'); await page.fill('#eodCash', '160');
  await tap(page, 'Submit end of day');
  const log = backend.db.daily_logs.find(l=>l.shop_id==='harare');
  check('resubmission kept the earlier figures rather than discarding them', log.resubmitted===1 && log.previous_counts.length===1 && log.previous_counts[0].cash===150, JSON.stringify(log));

  console.log('\n== F. Admin login: real credentials required, and non-admin logins are refused ==');
  backend.seed({
    authUsers: [ {id:'u1', email:'owner@towdah.com', password:'correcthorse'}, {id:'u2', email:'nobody@towdah.com', password:'whatever'} ],
    admins: [ {user_id:'u1', username:'owner'} ]
  });
  page = await newCtx(browser, backend);
  await page.goto(FILE); await page.waitForTimeout(400);
  await tap(page, 'Admin dashboard');
  await page.fill('#adminEmail', 'nobody@towdah.com'); await page.fill('#adminPass', 'whatever');
  await tap(page, 'Log in');
  t = await page.locator('#app').innerText();
  check('a valid Supabase login that is NOT an admin is refused', /not set up as an admin/i.test(t), t.slice(0,200));

  await page.fill('#adminEmail', 'owner@towdah.com'); await page.fill('#adminPass', 'wrongpassword');
  await tap(page, 'Log in');
  t = await page.locator('#app').innerText();
  check('wrong password refused', /not correct/i.test(t));

  await page.fill('#adminEmail', 'owner@towdah.com'); await page.fill('#adminPass', 'correcthorse');
  await tap(page, 'Log in');
  t = await page.locator('#app').innerText();
  check('correct admin login reaches the dashboard', /Admin dashboard/.test(t), t.slice(0,150));
  check('admin DOES see cost/profit figures the staff view hides', /profit/i.test(t));

  console.log('\n== G. Admin corrections are database-enforced, not just UI-hidden ==');
  const anyPhone = backend.db.phones.find(p=>p.status==='faulty') || backend.db.phones[0];
  const directWriteOff = backend.handle(JSON.stringify({kind:'rpc', name:'admin_write_off', params:{p_phone_id: 'nonexistent-not-signed-in-test'}}));
  // Simulate a staff-only session (no admin) attempting an admin RPC directly:
  const staffOnlyBackend = createBackend();
  staffOnlyBackend.seed({ staff:[{id:'sX', shop_id:'harare', name:'X', pin:'1111', active:true}] });
  const rawResult = JSON.parse(await staffOnlyBackend.handle(JSON.stringify({kind:'rpc', name:'admin_delete_phone', params:{p_phone_id:'whatever'}})));
  check('an admin-only action is refused when nobody is signed in as admin', rawResult.error && /Admin only/.test(rawResult.error.message), JSON.stringify(rawResult));

  console.log('\n== H. Settings: add staff, reset PIN, deactivate — deactivated staff cannot sign in ==');
  await tap(page, 'Settings');
  await page.fill('#newStaffName', 'Rudo'); await page.fill('#newStaffPin', '901234');
  await tap(page, 'Add staff member');
  t = await page.locator('#app').innerText();
  check('new staff member appears in the list', /Rudo/.test(t), t.slice(0,200));
  const rudo = backend.db.staff.find(s=>s.name==='Rudo');
  check('new staff PIN stored', rudo && rudo.pin==='901234');

  await tap(page, 'Deactivate');
  await tap(page, 'Yes, deactivate');
  t = await page.locator('#app').innerText();
  check('deactivated staff shown as Deactivated', /Deactivated/.test(t), t.slice(0,300));
  const rawLogin = JSON.parse(await backend.handle(JSON.stringify({kind:'rpc', name:'staff_login', params:{p_staff_id: rudo.id, p_pin:'901234'}})));
  check('deactivated staff can no longer sign in even with the right PIN', rawLogin.data.length===0, JSON.stringify(rawLogin));

  console.log('\n== H2. Danger zone: clear all demo/test data for a shop (admin only, permanent) ==');
  // Seed a phone in a different shop first, to prove the wipe only touches the one shop chosen.
  backend.db.phones.push({id:'other1', shop_id:'bulawayo1', imei:'999999999999999', model:'iPhone 12', description:null,
    batch_id:'bx', cost_price:null, list_price:null, status:'in_stock', date_received: today(), received_ts:new Date().toISOString(),
    received_by:'s1', sale_price:null, sold_by:null, date_sold:null, sold_ts:null, below_price:false, price_shortfall:0,
    return_reason:null, fault_parts:null, return_notes:null, date_returned:null, returned_ts:null,
    repaired_at:null, repaired_by:null, written_off_at:null, written_off_by:null, date_written_off:null});
  const beforeHarare = backend.db.phones.filter(p=>p.shop_id==='harare').length;
  check('harare has phones on record before the wipe', beforeHarare>0, 'count='+beforeHarare);

  await tap(page, 'Clear all data for this shop');
  t = await page.locator('#app').innerText();
  check('wipe screen names the shop and warns it is permanent', /cannot be undone/i.test(t) && /Harare CBD/.test(t), t.slice(0,300));

  await page.fill('#wipeConfirmInput', 'wrong name');
  let btnState = await page.evaluate(()=>document.getElementById('wipeConfirmBtn').style.pointerEvents);
  check('the clear button stays locked until the shop name is typed exactly', btnState==='none', btnState);

  await page.fill('#wipeConfirmInput', 'Harare CBD');
  btnState = await page.evaluate(()=>document.getElementById('wipeConfirmBtn').style.pointerEvents);
  check('the clear button unlocks once the name matches exactly', btnState==='auto', btnState);

  await tap(page, 'Yes, permanently clear Harare CBD');
  await tap(page, 'Yes, clear it permanently'); // are-you-sure modal on top of the typed confirmation
  await tap(page, 'OK'); // summary of what was removed
  await page.waitForTimeout(300);
  check('harare stock is actually gone from the database', backend.db.phones.filter(p=>p.shop_id==='harare').length===0,
    'count='+backend.db.phones.filter(p=>p.shop_id==='harare').length);
  check('the OTHER shop was not touched by a harare-only wipe', backend.db.phones.some(p=>p.shop_id==='bulawayo1'),
    JSON.stringify(backend.db.phones.map(p=>p.shop_id)));
  check('staff logins survive a data wipe (Rudo is still on record, just deactivated)', backend.db.staff.some(s=>s.name==='Rudo'));
  check('a permanent record of the reset is kept, separate from the ledger it cleared', backend.db.shop_resets.some(r=>r.shop_id==='harare'), JSON.stringify(backend.db.shop_resets));
  t = await page.locator('#app').innerText();
  check('settings screen now shows when the shop was last cleared and by whom', /Last cleared/.test(t) && /owner/.test(t), t.slice(0,500));

  console.log('\n== I. Offline handling: never a false success, cached copy shown while disconnected ==');
  backend.setNetworkDown(true);
  await page.reload(); await page.waitForTimeout(500);
  t = await page.locator('#app').innerText();
  check('reload while the database is unreachable shows a clear NOT CONNECTED warning', /NOT CONNECTED/.test(t), t.slice(0,200));
  backend.setNetworkDown(false);

  console.log('\n== J. Local caching gives an instant paint on the next visit ==');
  const cacheBackend = createBackend();
  cacheBackend.seed({ staff: [{id:'c1', shop_id:'harare', name:'Chipo', pin:'2020', active:true}] });
  let cp = await newCtx(browser, cacheBackend);
  await cp.goto(FILE); await cp.waitForTimeout(400);
  await tap(cp, 'Staff entry'); await tap(cp, 'Harare CBD'); await tap(cp, 'Chipo');
  await cp.fill('#pinInput', '2020'); await tap(cp, 'Continue');
  await cp.waitForTimeout(300);
  const cacheKeys = await cp.evaluate(()=>Object.keys(window.localStorage).filter(k=>k.indexOf('twcache_')===0));
  check('a local cache file is written after a successful shop load', cacheKeys.length>0, JSON.stringify(cacheKeys));

  console.log('\n== K1. A staff-typed new model appears in the pick list on the next load ==');
  let modelBackend = createBackend();
  modelBackend.seed({ staff: [{id:'sK1', shop_id:'harare', name:'Kuda', pin:'3344', active:true}] });
  let mp = await newCtx(browser, modelBackend);
  await mp.goto(FILE); await mp.waitForTimeout(400);
  await tap(mp, 'Staff entry'); await tap(mp, 'Harare CBD'); await tap(mp, 'Kuda');
  await mp.fill('#pinInput', '3344'); await tap(mp, 'Continue');
  await tap(mp, "Open today's business day");
  await tap(mp, 'Received new stock');
  await tap(mp, 'Not listed - type it in');
  await mp.fill('#recvModel', 'Nokia 3310');
  await mp.fill('#recvQty', '1');
  await tap(mp, 'Next: enter IMEIs');
  await mp.locator('.imeiRow').first().fill('333333333333333');
  await tap(mp, 'Add this item to the document');
  await tap(mp, 'Finish: save document to stock');
  t = await mp.locator('#app').innerText();
  check('staff-typed new model saves successfully', /1 phone\(s\) added to stock/.test(t), t.slice(0,150));
  check('a staff-typed new model is created in the database', modelBackend.db.models.some(m=>m.name==='Nokia 3310'), JSON.stringify(modelBackend.db.models.map(m=>m.name)));

  await mp.reload(); await mp.waitForTimeout(400);
  await tap(mp, 'Staff entry'); await tap(mp, 'Harare CBD'); await tap(mp, 'Kuda');
  await mp.fill('#pinInput', '3344'); await tap(mp, 'Continue');
  await tap(mp, 'Received new stock');
  t = await mp.locator('#app').innerText();
  check('the staff-typed model now appears in the pick list on the next load', /Nokia 3310/.test(t), t.slice(0,400));

  console.log('\n== K2. Only an admin can call admin_add_shop ==');
  const shopBackend = createBackend();
  shopBackend.seed({ staff:[{id:'sK2', shop_id:'harare', name:'Y', pin:'2222', active:true}] });
  const addShopResult = JSON.parse(await shopBackend.handle(JSON.stringify({kind:'rpc', name:'admin_add_shop', params:{p_name:'Mutare Branch'}})));
  check('a non-admin cannot call admin_add_shop', addShopResult.error && /Admin only/.test(addShopResult.error.message), JSON.stringify(addShopResult));
  check('no shop was actually added', !shopBackend.db.shops.some(s=>s.name==='Mutare Branch'));

  console.log('\n== K3. Closing a shop hides it from the staff picker but keeps its history ==');
  // persistSession:false (main's shop-floor-phone hardening) means the reload
  // in section I above signed the admin back out - re-authenticate before
  // reaching another admin-only screen, same credentials seeded in section F.
  await tap(page, 'Admin dashboard');
  await page.fill('#adminEmail', 'owner@towdah.com'); await page.fill('#adminPass', 'correcthorse');
  await tap(page, 'Log in');
  await tap(page, 'Settings');
  await page.locator('.list-item:has-text("Bulawayo Shop 1")').locator('button:text-is("Close")').click();
  await page.waitForTimeout(150);
  await tap(page, 'Yes, close this shop');
  t = await page.locator('#app').innerText();
  check('closed shop is marked Closed in Settings', /Bulawayo Shop 1/.test(t) && /Closed/.test(t), t.slice(0,600));
  check('the database actually marked the shop inactive', backend.db.shops.find(s=>s.id==='bulawayo1').active===false);

  let closedCheckPage = await newCtx(browser, backend);
  await closedCheckPage.goto(FILE); await closedCheckPage.waitForTimeout(400);
  await tap(closedCheckPage, 'Staff entry');
  t = await closedCheckPage.locator('#app').innerText();
  check('a closed shop no longer appears in the staff shop picker', !/Bulawayo Shop 1/.test(t), t.slice(0,300));
  check('the other open shops still do', /Harare CBD/.test(t) && /Bulawayo Shop 2/.test(t), t.slice(0,300));
  check("the closed shop's phone history is still on record, untouched", backend.db.phones.some(p=>p.shop_id==='bulawayo1'), JSON.stringify(backend.db.phones.filter(p=>p.shop_id==='bulawayo1').map(p=>p.id)));

  console.log('\n== L. cleanModelKey() (JS) must never drift from clean_model_key() (SQL) ==');
  // These input/expected pairs mirror clean_model_key() in
  // supabase-schema-part5.sql exactly - trim, collapse any run of internal
  // whitespace to one space, lowercase. The two functions decide the same
  // thing (is this a duplicate model?) from two different runtimes with no
  // way to check each other at request time, so if they ever drift apart the
  // app and the database will disagree about what a duplicate is, and that
  // will be very hard to spot from the outside. If you change either
  // cleanModelKey() (index.html) or clean_model_key() (part 5), change the
  // other the same way and update this list to match.
  const MODEL_KEY_CASES = [
    ['Galaxy  A15', 'galaxy a15'],
    [' galaxy a15 ', 'galaxy a15'],
    ['GALAXY A15', 'galaxy a15'],
    ['Galaxy\tA15', 'galaxy a15'],
    ['iPhone 12  Pro Max', 'iphone 12 pro max'],
    ['', '']
  ];
  for(const [input, expected] of MODEL_KEY_CASES){
    const actual = await page.evaluate((s)=>cleanModelKey(s), input);
    check('cleanModelKey('+JSON.stringify(input)+') === '+JSON.stringify(expected), actual===expected, 'got '+JSON.stringify(actual));
  }

  await browser.close();
  console.log('\n' + (failures === 0 ? 'ALL SUPABASE-REWRITE CHECKS PASSED' : failures + ' FAILED'));
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(2); });
