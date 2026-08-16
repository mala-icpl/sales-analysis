// Browser build of the parsing/join logic. Kept in exact parity with
// lib/importers.js (the version validated against real Vinclum exports) —
// only the module wiring differs (window global instead of CommonJS).
// If you change the join/health logic, change lib/importers.js first and
// mirror the change here.
(function () {
  const { mapOrderChannel } = window.PortalMap;

  function clean(v) {
    if (v === undefined || v === null) return null;
    const s = String(v).trim();
    return s === '' || s.toLowerCase() === 'nan' ? null : s;
  }

  function toNum(v) {
    const c = clean(v);
    if (c === null) return null;
    const n = Number(String(c).replace(/,/g, ''));
    return Number.isFinite(n) ? n : null;
  }

  // Mirrors lib/importers.js — see that file for why this exists.
  const KNOWN_BRANDS = ['Carlton London', 'ELLE', 'CL Sport', 'ICONICS'];
  function canonicalizeBrand(raw) {
    const c = clean(raw);
    if (!c) return null;
    const hit = KNOWN_BRANDS.find(b => b.toLowerCase() === c.toLowerCase());
    return hit || c;
  }

  function splitSku(skuDesc) {
    if (!skuDesc) return { size: null };
    const parts = skuDesc.split('_');
    const size = parts.length > 1 ? parts[parts.length - 1] : null;
    return { size };
  }

  function normalizeMaster(rows) {
    const out = [];
    const eanToSku = new Map();
    const skuSet = new Set();
    for (const r of rows) {
      const vinculum_sku = clean(r['Vinculum SKU']);
      if (!vinculum_sku) continue;
      const ean = clean(r['EAN']);
      out.push({
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
      });
      skuSet.add(vinculum_sku);
      if (ean) eanToSku.set(ean, vinculum_sku);
    }
    return { rows: out, eanToSku, skuSet };
  }

  function normalizeInventory(rows, masterSkuSet, snapshotDate, sourceFile, warehouse) {
    const out = [];
    for (const r of rows) {
      const sku_desc_raw = clean(r['SKU Desc']);
      if (!sku_desc_raw) continue;
      const matched = masterSkuSet ? masterSkuSet.has(sku_desc_raw) : false;
      out.push({
        warehouse,
        vinculum_sku: sku_desc_raw,
        matched,
        sku_desc_raw,
        ean: clean(r['SKU']),
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

  function parseVinclumDate(s) {
    const c = clean(s);
    if (!c) return null;
    const m = c.match(/^(\d{2})-(\d{2})-(\d{2})$/);
    if (m) {
      const [, dd, mm, yy] = m;
      const yyyy = Number(yy) < 70 ? `20${yy}` : `19${yy}`;
      return `${yyyy}-${mm}-${dd}`;
    }
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
        period_key: periodKeyFromDate(invoice_date),
      });
    }
    return out;
  }

  window.Importers = { normalizeMaster, normalizeInventory, normalizeSales, clean, toNum, parseVinclumDate };
})();
