// Normalization + join logic shared between local test harness and the
// production browser-side importer (same functions get embedded into the
// upload page JS). Pure functions, no I/O — easy to unit test.

const { mapOrderChannel } = require('./portalMap.js');

function clean(v) {
  if (v === undefined || v === null) return null;
  const s = String(v).trim();
  return s === '' || s.toLowerCase() === 'nan' ? null : s;
}

// The master file has a few case/whitespace variants of the same brand
// (e.g. "Iconics" vs "ICONICS", "ELLE " with a trailing space) that would
// otherwise fragment brand-wise reporting. Canonicalize against the known
// set; anything not on this list passes through untouched (trimmed only),
// so a genuinely new brand still shows up rather than being dropped.
const KNOWN_BRANDS = ['Carlton London', 'ELLE', 'CL Sport', 'ICONICS'];
function canonicalizeBrand(raw) {
  const c = clean(raw);
  if (!c) return null;
  const hit = KNOWN_BRANDS.find(b => b.toLowerCase() === c.toLowerCase());
  return hit || c;
}

function toNum(v) {
  const c = clean(v);
  if (c === null) return null;
  const n = Number(c.replace(/,/g, ''));
  return Number.isFinite(n) ? n : null;
}

// Vinculum SKU / SKU Desc format: "<Article>_<Color>_<Size>" (mostly).
// A few legacy rows have extra prefixes/spaces — we still keep the raw
// string as the join key, but attempt to split out size for display.
function splitSku(skuDesc) {
  if (!skuDesc) return { size: null };
  const parts = skuDesc.split('_');
  const size = parts.length > 1 ? parts[parts.length - 1] : null;
  return { size };
}

// ---------------------------------------------------------------------------
// SKU MASTER
// ---------------------------------------------------------------------------
function normalizeMaster(rows) {
  const out = [];
  const eanToSku = new Map();
  const skuSet = new Set();
  for (const r of rows) {
    const vinculum_sku = clean(r['Vinculum SKU']);
    if (!vinculum_sku) continue;
    const ean = clean(r['EAN']);
    const rec = {
      vinculum_sku,
      article: clean(r['Article']),
      article_color: clean(r['Article color']),
      color: clean(r['Color']),
      size: splitSku(vinculum_sku).size,
      ean,
      brand: canonicalizeBrand(r['Brand']),
      mrp: toNum(r['MRP']),
      item_type_name: clean(r['Item type Name']),
      myntra_item_type: clean(r['Myntra item type']),
      myntra_style_id: clean(r['Myntra styl id']),
      asin: clean(r['Asin']),
      fsn: clean(r['FSN']),
      jio_code: clean(r['Jio Code']),
      nykaa_product_id: clean(r['Nykaa Product Id']),
      article_status: clean(r['article Status']),
    };
    out.push(rec);
    skuSet.add(vinculum_sku);
    if (ean) eanToSku.set(ean, vinculum_sku);
  }
  return { rows: out, eanToSku, skuSet };
}

// ---------------------------------------------------------------------------
// INVENTORY
// ---------------------------------------------------------------------------
function normalizeInventory(rows, masterSkuSet, snapshotDate, sourceFile) {
  const out = [];
  for (const r of rows) {
    const sku_desc_raw = clean(r['SKU Desc']);
    if (!sku_desc_raw) continue;
    const matched = masterSkuSet ? masterSkuSet.has(sku_desc_raw) : false;
    out.push({
      vinculum_sku: sku_desc_raw,
      matched,
      sku_desc_raw,
      mfg_sku_code: clean(r['Mfg SKU Code']),
      brand_code: clean(r['Brand Code']),
      total_qty: toNum(r['Total Quantity']) ?? 0,
      available_qty: toNum(r['Available Quantity']) ?? 0,
      mrp: toNum(r['MRP']),
      snapshot_date: snapshotDate,
      source_file: sourceFile || null,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// SALES
// ---------------------------------------------------------------------------
// Vinclum date format observed: DD-MM-YY (e.g. "02-07-26"). Convert to ISO.
function parseVinclumDate(s) {
  const c = clean(s);
  if (!c) return null;
  const m = c.match(/^(\d{2})-(\d{2})-(\d{2})$/);
  if (m) {
    const [, dd, mm, yy] = m;
    const yyyy = Number(yy) < 70 ? `20${yy}` : `19${yy}`;
    return `${yyyy}-${mm}-${dd}`;
  }
  // fallback: try native Date parse
  const d = new Date(c);
  return Number.isNaN(d.getTime()) ? null : d.toISOString().slice(0, 10);
}

function periodKeyFromDate(iso) {
  return iso ? iso.slice(0, 7) : null;
}

function normalizeSales(rows, eanToSku) {
  const out = [];
  for (const r of rows) {
    const client_sku_ean = clean(r['ClientSKU']);
    const vinculum_sku = client_sku_ean && eanToSku ? eanToSku.get(client_sku_ean) || null : null;
    const { portal, entity, unit } = mapOrderChannel(r['Order Channel']);
    const order_date = parseVinclumDate(r['OrderDate']);
    const invoice_date = parseVinclumDate(r['DateofInvoice']);
    out.push({
      client_sku_ean,
      vinculum_sku,
      matched: !!vinculum_sku,
      brand: canonicalizeBrand(r['Brand']),
      order_channel_raw: clean(r['Order Channel']),
      portal,
      entity,
      unit,
      status: clean(r['Status']),
      qty: toNum(r['QTY']) ?? 0,
      mrp: toNum(r['MRP']),
      selling_price: toNum(r['Selling Price']),
      order_amount: toNum(r['OrderAmount']),
      line_amount: toNum(r['Line Amount']),
      order_date,
      invoice_date,
      invoice_no: clean(r['InvoiceNo']),
      order_no: clean(r['OrderNo']),
      external_order_no: clean(r['ExternalOrderNo']),
      source_warehouse: clean(r['SourceWarehouse']),
      // period_key uses invoice date, not order date: a small tail of orders
      // placed in the last days of the prior month get invoiced/shipped
      // early next month. Keying off invoice date keeps a monthly file's
      // rows cleanly inside the month it was actually pulled for, so a
      // re-upload of "July sales" replaces exactly the July batch.
      period_key: periodKeyFromDate(invoice_date),
    });
  }
  return out;
}

module.exports = { normalizeMaster, normalizeInventory, normalizeSales, clean, toNum, parseVinclumDate, canonicalizeBrand };
