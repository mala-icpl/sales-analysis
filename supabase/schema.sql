-- ============================================================================
-- Iconic Creation — Inventory & Sales Health Dashboard
-- Database schema for Supabase (Postgres)
-- ============================================================================
-- Run this once in the Supabase SQL editor (or via `psql`) on a fresh project.
-- Safe to re-run: uses CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. SKU MASTER
-- One row per Vinculum SKU (Article_Color_Size). This is the bridge table:
-- it links the internal SKU to every portal's own product ID (ASIN, FSN, etc.)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sku_master (
  vinculum_sku       text PRIMARY KEY,
  article            text,
  article_color      text,
  color              text,
  size               text,
  ean                text,
  brand              text,
  mrp                numeric,
  item_type_name     text,
  myntra_item_type   text,
  myntra_style_id    text,
  asin               text,
  fsn                text,
  jio_code           text,
  nykaa_product_id   text,
  article_status     text,        -- 'Article Live' | 'Discontinue' | 'Inactive'
  updated_at         timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sku_master_ean   ON sku_master (ean);
CREATE INDEX IF NOT EXISTS idx_sku_master_brand ON sku_master (brand);
CREATE INDEX IF NOT EXISTS idx_sku_master_article ON sku_master (article);
CREATE INDEX IF NOT EXISTS idx_sku_master_status ON sku_master (article_status);

-- ----------------------------------------------------------------------------
-- 2. INVENTORY SNAPSHOTS
-- Each upload adds a new snapshot batch (snapshot_date). We keep history so
-- stock trends can be charted later; the app always reads the LATEST snapshot
-- per SKU via v_current_inventory below.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventory_snapshot (
  id             bigserial PRIMARY KEY,
  warehouse      text NOT NULL,    -- which warehouse this snapshot is from (Mala has 2)
  vinculum_sku   text,             -- resolved SKU (from "SKU Desc" column)
  matched        boolean DEFAULT false,  -- true if it matched sku_master
  sku_desc_raw   text,             -- original "SKU Desc" text, unmodified
  ean            text,             -- raw "SKU"/EAN column, stored as-is for reference
                                    -- only (NOT used for matching — some exports
                                    -- corrupt this into scientific notation; see
                                    -- SETUP.md). Format the column as Text before
                                    -- exporting CSV to get clean values here.
  mfg_sku_code   text,
  brand_code     text,             -- Brand Code as it appears in the Vinclum export
  total_qty      integer,
  available_qty  integer,
  mrp            numeric,
  snapshot_date  date NOT NULL,
  uploaded_at    timestamptz DEFAULT now(),
  source_file    text
);

CREATE INDEX IF NOT EXISTS idx_inv_snap_sku_date ON inventory_snapshot (vinculum_sku, snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_inv_snap_date      ON inventory_snapshot (snapshot_date);
CREATE INDEX IF NOT EXISTS idx_inv_snap_warehouse ON inventory_snapshot (warehouse, snapshot_date DESC);

-- Latest snapshot per SKU PER WAREHOUSE (each warehouse uploads and
-- refreshes independently, possibly on different dates).
CREATE OR REPLACE VIEW v_current_inventory_by_warehouse WITH (security_invoker = true) AS
SELECT DISTINCT ON (vinculum_sku, warehouse) *
FROM inventory_snapshot
WHERE vinculum_sku IS NOT NULL AND vinculum_sku <> ''
ORDER BY vinculum_sku, warehouse, snapshot_date DESC, uploaded_at DESC;

-- "Current inventory" = SUMMED across all warehouses. This is what the
-- rest of the app (health flags, KPIs) reads — Mala wants combined stock
-- across both warehouses, not per-warehouse figures.
-- security_invoker=true: without this, the view runs with the view OWNER's
-- privileges (which bypass RLS) rather than the querying user's — silently
-- defeating the RLS policy below. Flagged by Supabase's security advisor.
CREATE OR REPLACE VIEW v_current_inventory WITH (security_invoker = true) AS
SELECT
  vinculum_sku,
  bool_or(matched) AS matched,
  MAX(sku_desc_raw) AS sku_desc_raw,
  MAX(mfg_sku_code) AS mfg_sku_code,
  MAX(brand_code) AS brand_code,
  SUM(total_qty) AS total_qty,
  SUM(available_qty) AS available_qty,
  MAX(mrp) AS mrp,              -- MRP is a product attribute, not warehouse-specific
  MAX(snapshot_date) AS snapshot_date,
  MAX(uploaded_at) AS uploaded_at
FROM v_current_inventory_by_warehouse
GROUP BY vinculum_sku;

-- ----------------------------------------------------------------------------
-- 3. SALES
-- One row per order line. Uploaded as monthly pulls; each upload replaces any
-- existing rows for that period_key (so re-uploading the same month doesn't
-- double-count).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sales (
  id                  bigserial PRIMARY KEY,
  client_sku_ean      text,      -- raw "ClientSKU" column from Vinclum (= EAN)
  vinculum_sku        text,      -- resolved via sku_master.ean -> vinculum_sku
  matched             boolean DEFAULT false,
  brand               text,      -- taken directly from the sales file (reliable)
  order_channel_raw   text,      -- raw "Order Channel" value
  portal              text,      -- grouped portal: Myntra / Nykaa Fashion / Nykaa.com / Ajio / Flipkart / Amazon / Tata Cliq / Own Website / Other
  entity              text,      -- ICPL / Global / Iconic / Unknown
  unit                text,      -- Unit1 / Unit2 / null
  status              text,      -- Shipped complete / delivered / Shipped & Returned / Cancelled / Packed / Pick complete
  qty                 numeric,
  mrp                 numeric,
  selling_price       numeric,
  order_amount        numeric,
  line_amount         numeric,
  order_date          date,
  invoice_date        date,
  invoice_no          text,
  order_no            text,
  external_order_no   text,
  source_warehouse    text,
  period_key          text NOT NULL,   -- 'YYYY-MM', derived from OrderDate at upload time
  uploaded_at         timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_sku        ON sales (vinculum_sku);
CREATE INDEX IF NOT EXISTS idx_sales_period     ON sales (period_key);
CREATE INDEX IF NOT EXISTS idx_sales_portal     ON sales (portal);
CREATE INDEX IF NOT EXISTS idx_sales_brand      ON sales (brand);
CREATE INDEX IF NOT EXISTS idx_sales_order_date ON sales (order_date);
CREATE INDEX IF NOT EXISTS idx_sales_status     ON sales (status);

-- ----------------------------------------------------------------------------
-- 4. UPLOAD LOG (simple audit trail, shown on the Upload/Admin page)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS upload_log (
  id             bigserial PRIMARY KEY,
  file_type      text NOT NULL,     -- 'sku_master' | 'inventory' | 'sales'
  file_name      text,
  period_key     text,              -- for sales uploads
  snapshot_date  date,              -- for inventory uploads
  row_count      integer,
  matched_count  integer,
  unmatched_count integer,
  uploaded_by    text,
  uploaded_at    timestamptz DEFAULT now(),
  notes          text
);

-- ----------------------------------------------------------------------------
-- 5. HELPER FUNCTIONS
-- ----------------------------------------------------------------------------

-- Most recent date we actually have sales data for (data isn't always "today"
-- since it's a monthly pull) — trailing-window calcs are anchored to this.
CREATE OR REPLACE FUNCTION fn_latest_sales_date() RETURNS date
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT MAX(order_date) FROM sales;
$$;

-- Per-SKU, per-portal sales aggregated over a trailing window of p_days,
-- anchored to fn_latest_sales_date() rather than real "today".
CREATE OR REPLACE FUNCTION fn_sku_sales_agg(p_days int)
RETURNS TABLE (
  vinculum_sku    text,
  portal          text,
  units_sold      numeric,
  units_returned  numeric,
  units_cancelled numeric,
  net_revenue     numeric,
  days_in_window  int
) LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT
    s.vinculum_sku,
    s.portal,
    SUM(CASE WHEN s.status IN ('Shipped complete','delivered','Pick complete','Packed') THEN s.qty ELSE 0 END) AS units_sold,
    SUM(CASE WHEN s.status = 'Shipped & Returned' THEN s.qty ELSE 0 END) AS units_returned,
    SUM(CASE WHEN s.status = 'Cancelled' THEN s.qty ELSE 0 END) AS units_cancelled,
    SUM(CASE WHEN s.status IN ('Shipped complete','delivered','Pick complete','Packed') THEN s.line_amount ELSE 0 END) AS net_revenue,
    p_days AS days_in_window
  FROM sales s
  WHERE s.vinculum_sku IS NOT NULL
    AND s.order_date > fn_latest_sales_date() - (p_days || ' days')::interval
  GROUP BY s.vinculum_sku, s.portal;
$$;

-- Full SKU health table: master info + current stock + trailing sales,
-- summed across all portals. This is what the Inventory Health page reads.
--
-- Driven from the UNION of sku_master and v_current_inventory (not just
-- sku_master) so that legacy/obsolete SKUs — intentionally removed from
-- master but still carrying leftover stock — still show up, flagged
-- health_flag='LEGACY_UNMAPPED' / is_legacy=true, instead of silently
-- disappearing from health results.
CREATE OR REPLACE FUNCTION fn_sku_health(p_days int DEFAULT 30)
RETURNS TABLE (
  vinculum_sku      text,
  article           text,
  color             text,
  size              text,
  brand             text,
  article_status    text,
  mrp               numeric,
  available_qty     numeric,
  total_qty         numeric,
  units_sold        numeric,
  units_returned    numeric,
  net_revenue       numeric,
  daily_velocity    numeric,
  stock_cover_days  numeric,
  sell_through_rate numeric,
  health_flag       text,
  is_legacy         boolean
) LANGUAGE sql STABLE SET search_path = public, pg_temp SET work_mem = '64MB' AS $$
  WITH agg AS (
    SELECT vinculum_sku,
           SUM(units_sold) AS units_sold,
           SUM(units_returned) AS units_returned,
           SUM(net_revenue) AS net_revenue
    FROM fn_sku_sales_agg(p_days)
    GROUP BY vinculum_sku
  ),
  universe AS (
    SELECT vinculum_sku FROM sku_master
    UNION
    SELECT vinculum_sku FROM v_current_inventory
  )
  SELECT
    u.vinculum_sku,
    COALESCE(m.article, split_part(u.vinculum_sku, '_', 1)) AS article,
    COALESCE(m.color, split_part(u.vinculum_sku, '_', 2)) AS color,
    COALESCE(m.size, split_part(u.vinculum_sku, '_', 3)) AS size,
    COALESCE(m.brand, i.brand_code, 'Unmapped') AS brand,
    COALESCE(m.article_status, 'Unmapped (legacy)') AS article_status,
    COALESCE(m.mrp, i.mrp) AS mrp,
    COALESCE(i.available_qty, 0)::numeric AS available_qty,
    COALESCE(i.total_qty, 0)::numeric AS total_qty,
    COALESCE(a.units_sold, 0) AS units_sold,
    COALESCE(a.units_returned, 0) AS units_returned,
    COALESCE(a.net_revenue, 0) AS net_revenue,
    ROUND(COALESCE(a.units_sold, 0) / GREATEST(p_days, 1)::numeric, 3) AS daily_velocity,
    CASE
      WHEN COALESCE(a.units_sold, 0) = 0 THEN NULL  -- no sales velocity to project from
      ELSE ROUND(COALESCE(i.available_qty, 0) / (COALESCE(a.units_sold, 0) / GREATEST(p_days, 1)::numeric), 1)
    END AS stock_cover_days,
    CASE
      WHEN (COALESCE(a.units_sold, 0) + COALESCE(i.available_qty, 0)) = 0 THEN NULL
      ELSE ROUND(COALESCE(a.units_sold, 0)::numeric / (COALESCE(a.units_sold, 0) + COALESCE(i.available_qty, 0)), 3)
    END AS sell_through_rate,
    CASE
      WHEN m.vinculum_sku IS NULL
        THEN 'LEGACY_UNMAPPED'   -- has inventory (and maybe sales) but was intentionally removed from master
      WHEN COALESCE(i.available_qty, 0) = 0 AND COALESCE(a.units_sold,0) > 0 AND m.article_status = 'Article Live'
        THEN 'STOCKOUT'          -- selling, live, out of stock: reorder
      WHEN COALESCE(i.available_qty, 0) = 0 AND COALESCE(a.units_sold,0) > 0 AND m.article_status <> 'Article Live'
        THEN 'DISCONTINUED_OUT'  -- sold out, but discontinued: informational only, no reorder
      WHEN COALESCE(i.available_qty, 0) > 0 AND COALESCE(a.units_sold, 0) = 0
        THEN 'DEAD_STOCK'        -- stock sitting, nothing sold in window
      WHEN COALESCE(a.units_sold, 0) > 0 AND COALESCE(i.available_qty, 0) / (COALESCE(a.units_sold, 0) / GREATEST(p_days, 1)::numeric) < 15
        THEN 'LOW_COVER'         -- selling, less than ~2 weeks of stock left
      WHEN COALESCE(a.units_sold, 0) > 0 AND COALESCE(i.available_qty, 0) / (COALESCE(a.units_sold, 0) / GREATEST(p_days, 1)::numeric) > 90
        THEN 'OVERSTOCK'         -- selling, but more than 3 months of stock on hand
      ELSE 'HEALTHY'
    END AS health_flag,
    (m.vinculum_sku IS NULL) AS is_legacy
  FROM universe u
  LEFT JOIN sku_master m ON m.vinculum_sku = u.vinculum_sku
  LEFT JOIN v_current_inventory i ON i.vinculum_sku = u.vinculum_sku
  LEFT JOIN agg a ON a.vinculum_sku = u.vinculum_sku
  WHERE m.article_status IS DISTINCT FROM 'Inactive';
$$;

-- One-row summary used by the Overview dashboard's KPI tiles, so the
-- browser doesn't have to pull all ~60k SKU rows just to add them up.
CREATE OR REPLACE FUNCTION fn_sku_health_summary(p_days int DEFAULT 30)
RETURNS TABLE (
  total_skus         bigint,
  total_available_units bigint,
  total_stock_value  numeric,
  units_sold         numeric,
  net_revenue        numeric,
  dead_stock_skus    bigint,
  dead_stock_units   bigint,
  stockout_skus      bigint,
  low_cover_skus     bigint,
  overstock_skus     bigint,
  discontinued_out_skus bigint,
  legacy_skus        bigint,
  sell_through_rate  numeric
) LANGUAGE sql STABLE SET search_path = public, pg_temp SET work_mem = '64MB' AS $$
  SELECT
    COUNT(*),
    SUM(available_qty)::bigint,
    SUM(available_qty * COALESCE(mrp, 0)),
    SUM(units_sold),
    SUM(net_revenue),
    COUNT(*) FILTER (WHERE health_flag = 'DEAD_STOCK'),
    SUM(available_qty) FILTER (WHERE health_flag = 'DEAD_STOCK')::bigint,
    COUNT(*) FILTER (WHERE health_flag = 'STOCKOUT'),
    COUNT(*) FILTER (WHERE health_flag = 'LOW_COVER'),
    COUNT(*) FILTER (WHERE health_flag = 'OVERSTOCK'),
    COUNT(*) FILTER (WHERE health_flag = 'DISCONTINUED_OUT'),
    COUNT(*) FILTER (WHERE is_legacy),
    ROUND(SUM(units_sold) / NULLIF(SUM(units_sold) + SUM(available_qty), 0), 3)
  FROM fn_sku_health(p_days);
$$;

-- Rolls fn_sku_health up to SKU / Article+Colour / Article level for the
-- Inventory Health page's grouping filter (she wants Article+Colour and
-- Article as the two grouping options — not raw per-SKU rows).
CREATE OR REPLACE FUNCTION fn_inventory_health(p_days int DEFAULT 30, p_group text DEFAULT 'sku')
RETURNS TABLE (
  group_key         text,
  vinculum_sku      text,
  article           text,
  color             text,
  size              text,
  sku_count         bigint,
  brand             text,
  article_status    text,
  mrp               numeric,
  available_qty     numeric,
  total_qty         numeric,
  units_sold        numeric,
  units_returned    numeric,
  net_revenue       numeric,
  daily_velocity    numeric,
  stock_cover_days  numeric,
  sell_through_rate numeric,
  health_flag       text,
  is_legacy         boolean
) LANGUAGE plpgsql STABLE SET search_path = public, pg_temp SET work_mem = '64MB' AS $$
BEGIN
  IF p_group = 'sku' THEN
    RETURN QUERY
    SELECT
      h.vinculum_sku, h.vinculum_sku, h.article, h.color, h.size, 1::bigint,
      h.brand, h.article_status, h.mrp,
      h.available_qty, h.total_qty, h.units_sold, h.units_returned, h.net_revenue,
      h.daily_velocity, h.stock_cover_days, h.sell_through_rate, h.health_flag, h.is_legacy
    FROM fn_sku_health(p_days) h;

  ELSIF p_group = 'article_color' THEN
    RETURN QUERY
    SELECT
      (COALESCE(h.article,'?') || ' / ' || COALESCE(h.color,'?')) AS group_key,
      NULL::text, h.article, h.color, NULL::text, COUNT(*)::bigint,
      MAX(h.brand), MAX(h.article_status), MAX(h.mrp),
      SUM(h.available_qty), SUM(h.total_qty), SUM(h.units_sold), SUM(h.units_returned), SUM(h.net_revenue),
      ROUND(SUM(h.units_sold) / GREATEST(p_days,1)::numeric, 3),
      CASE WHEN SUM(h.units_sold) = 0 THEN NULL
           ELSE ROUND(SUM(h.available_qty) / (SUM(h.units_sold) / GREATEST(p_days,1)::numeric), 1) END,
      CASE WHEN (SUM(h.units_sold) + SUM(h.available_qty)) = 0 THEN NULL
           ELSE ROUND(SUM(h.units_sold) / (SUM(h.units_sold) + SUM(h.available_qty)), 3) END,
      CASE
        WHEN bool_and(h.is_legacy) THEN 'LEGACY_UNMAPPED'
        WHEN SUM(h.available_qty) = 0 AND SUM(h.units_sold) > 0 AND bool_or(h.article_status = 'Article Live') THEN 'STOCKOUT'
        WHEN SUM(h.available_qty) = 0 AND SUM(h.units_sold) > 0 THEN 'DISCONTINUED_OUT'
        WHEN SUM(h.available_qty) > 0 AND SUM(h.units_sold) = 0 THEN 'DEAD_STOCK'
        WHEN SUM(h.units_sold) > 0 AND SUM(h.available_qty) / (SUM(h.units_sold) / GREATEST(p_days,1)::numeric) < 15 THEN 'LOW_COVER'
        WHEN SUM(h.units_sold) > 0 AND SUM(h.available_qty) / (SUM(h.units_sold) / GREATEST(p_days,1)::numeric) > 90 THEN 'OVERSTOCK'
        ELSE 'HEALTHY'
      END,
      bool_and(h.is_legacy)
    FROM fn_sku_health(p_days) h
    GROUP BY h.article, h.color;

  ELSIF p_group = 'article' THEN
    RETURN QUERY
    SELECT
      COALESCE(h.article,'?') AS group_key,
      NULL::text, h.article, NULL::text, NULL::text, COUNT(*)::bigint,
      MAX(h.brand), MAX(h.article_status), MAX(h.mrp),
      SUM(h.available_qty), SUM(h.total_qty), SUM(h.units_sold), SUM(h.units_returned), SUM(h.net_revenue),
      ROUND(SUM(h.units_sold) / GREATEST(p_days,1)::numeric, 3),
      CASE WHEN SUM(h.units_sold) = 0 THEN NULL
           ELSE ROUND(SUM(h.available_qty) / (SUM(h.units_sold) / GREATEST(p_days,1)::numeric), 1) END,
      CASE WHEN (SUM(h.units_sold) + SUM(h.available_qty)) = 0 THEN NULL
           ELSE ROUND(SUM(h.units_sold) / (SUM(h.units_sold) + SUM(h.available_qty)), 3) END,
      CASE
        WHEN bool_and(h.is_legacy) THEN 'LEGACY_UNMAPPED'
        WHEN SUM(h.available_qty) = 0 AND SUM(h.units_sold) > 0 AND bool_or(h.article_status = 'Article Live') THEN 'STOCKOUT'
        WHEN SUM(h.available_qty) = 0 AND SUM(h.units_sold) > 0 THEN 'DISCONTINUED_OUT'
        WHEN SUM(h.available_qty) > 0 AND SUM(h.units_sold) = 0 THEN 'DEAD_STOCK'
        WHEN SUM(h.units_sold) > 0 AND SUM(h.available_qty) / (SUM(h.units_sold) / GREATEST(p_days,1)::numeric) < 15 THEN 'LOW_COVER'
        WHEN SUM(h.units_sold) > 0 AND SUM(h.available_qty) / (SUM(h.units_sold) / GREATEST(p_days,1)::numeric) > 90 THEN 'OVERSTOCK'
        ELSE 'HEALTHY'
      END,
      bool_and(h.is_legacy)
    FROM fn_sku_health(p_days) h
    GROUP BY h.article;

  ELSE
    RAISE EXCEPTION 'invalid p_group: %, expected sku, article_color, or article', p_group;
  END IF;
END;
$$;

-- Aggregate counterpart to fn_inventory_health: same grouping + same filter
-- semantics (brand/health-flag exact match, search across group_key/article/
-- color), but returns just the totals instead of paginated rows. Powers the
-- "Total inventory" summary tile on the Inventory Health page, which needs
-- to reflect ALL matching rows, not just the current page.
CREATE OR REPLACE FUNCTION fn_inventory_health_summary(
  p_days   int  DEFAULT 30,
  p_group  text DEFAULT 'sku',
  p_brand  text DEFAULT NULL,
  p_flag   text DEFAULT NULL,
  p_search text DEFAULT NULL
)
RETURNS TABLE (
  total_groups bigint,
  total_stock  numeric
) LANGUAGE sql STABLE SET search_path = public, pg_temp SET work_mem = '64MB' AS $$
  SELECT
    COUNT(*)::bigint,
    COALESCE(SUM(h.available_qty), 0)
  FROM fn_inventory_health(p_days, p_group) h
  WHERE (p_brand IS NULL OR h.brand = p_brand)
    AND (p_flag IS NULL OR h.health_flag = p_flag)
    AND (p_search IS NULL OR p_search = '' OR
         h.group_key ILIKE '%' || p_search || '%' OR
         h.article   ILIKE '%' || p_search || '%' OR
         h.color     ILIKE '%' || p_search || '%')
$$;

-- Portal x Brand sales rollup for a trailing window — feeds the Overview and
-- Sales Analysis charts without shipping row-level data to the browser.
CREATE OR REPLACE FUNCTION fn_portal_brand_summary(p_days int DEFAULT 30)
RETURNS TABLE (
  portal        text,
  brand         text,
  units_sold    numeric,
  units_returned numeric,
  net_revenue   numeric
) LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT
    s.portal,
    s.brand,
    SUM(CASE WHEN s.status IN ('Shipped complete','delivered','Pick complete','Packed') THEN s.qty ELSE 0 END),
    SUM(CASE WHEN s.status = 'Shipped & Returned' THEN s.qty ELSE 0 END),
    SUM(CASE WHEN s.status IN ('Shipped complete','delivered','Pick complete','Packed') THEN s.line_amount ELSE 0 END)
  FROM sales s
  WHERE s.order_date > fn_latest_sales_date() - (p_days || ' days')::interval
  GROUP BY s.portal, s.brand;
$$;

-- Full period x portal x brand breakdown — small result set (months x 8
-- portals x ~4 brands), fetched once by the Sales Analysis page and sliced
-- in the browser for the period picker / trend chart / portal-brand toggle.
CREATE OR REPLACE FUNCTION fn_sales_by_period()
RETURNS TABLE (
  period_key     text,
  portal         text,
  brand          text,
  total_qty      numeric,
  units_sold     numeric,
  units_returned numeric,
  units_cancelled numeric,
  total_revenue  numeric,
  net_revenue    numeric,
  orders         bigint
) LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT
    s.period_key,
    s.portal,
    s.brand,
    SUM(s.qty),
    SUM(CASE WHEN s.status IN ('Shipped complete','delivered','Pick complete','Packed') THEN s.qty ELSE 0 END),
    SUM(CASE WHEN s.status = 'Shipped & Returned' THEN s.qty ELSE 0 END),
    SUM(CASE WHEN s.status = 'Cancelled' THEN s.qty ELSE 0 END),
    SUM(s.line_amount),
    SUM(CASE WHEN s.status IN ('Shipped complete','delivered','Pick complete','Packed') THEN s.line_amount ELSE 0 END),
    COUNT(DISTINCT s.invoice_no)
  FROM sales s
  GROUP BY s.period_key, s.portal, s.brand;
$$;

-- Top/bottom SKUs by net revenue for a given period (NULL = all periods).
CREATE OR REPLACE FUNCTION fn_top_skus(p_period_key text DEFAULT NULL, p_limit int DEFAULT 15, p_ascending boolean DEFAULT false)
RETURNS TABLE (
  vinculum_sku text,
  brand        text,
  units_sold   numeric,
  net_revenue  numeric
) LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
BEGIN
  RETURN QUERY
  SELECT s.vinculum_sku, MAX(s.brand), SUM(s.qty) FILTER (WHERE s.status IN ('Shipped complete','delivered','Pick complete','Packed')),
         SUM(s.line_amount) FILTER (WHERE s.status IN ('Shipped complete','delivered','Pick complete','Packed'))
  FROM sales s
  WHERE s.vinculum_sku IS NOT NULL AND (p_period_key IS NULL OR s.period_key = p_period_key)
  GROUP BY s.vinculum_sku
  ORDER BY CASE WHEN p_ascending THEN SUM(s.line_amount) FILTER (WHERE s.status IN ('Shipped complete','delivered','Pick complete','Packed')) END ASC NULLS LAST,
           CASE WHEN NOT p_ascending THEN SUM(s.line_amount) FILTER (WHERE s.status IN ('Shipped complete','delivered','Pick complete','Packed')) END DESC NULLS LAST
  LIMIT p_limit;
END;
$$;

-- Distinct brand list for filter dropdowns. Driven from fn_sku_health (not
-- sku_master directly) so it's always populated from whatever brands
-- actually appear in health results — including inventory's brand_code
-- fallback for legacy/unmapped SKUs — even before SKU Master has been
-- uploaded. (Originally read straight from sku_master, which left this
-- dropdown empty whenever master was empty/not yet uploaded — the window
-- arg is fixed at 30 since it only affects sales/velocity figures, not
-- which SKUs/brands exist.)
CREATE OR REPLACE FUNCTION fn_distinct_brands()
RETURNS TABLE (brand text) LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT DISTINCT h.brand FROM fn_sku_health(30) h WHERE h.brand IS NOT NULL ORDER BY 1;
$$;

-- Per Article / Article+Colour / SKU, compares units sold on a chosen
-- "focus" portal vs every other portal combined, across any number of
-- selected calendar months — powers the Portal Opportunity page (campaign
-- targeting: find articles doing well elsewhere but not on a given portal,
-- or vice versa). Returns one row per group PER MONTH (long format, like
-- fn_sales_by_period) so the page can pivot into as many month columns as
-- the user picks, rather than a fixed number.
CREATE OR REPLACE FUNCTION fn_portal_opportunity(
  p_group    text DEFAULT 'article_color',   -- 'sku' | 'article_color' | 'article'
  p_portal   text DEFAULT 'Amazon',
  p_periods  text[] DEFAULT ARRAY[]::text[]
)
RETURNS TABLE (
  group_key      text,
  vinculum_sku   text,
  article        text,
  color          text,
  sku_count      bigint,
  brand          text,
  available_qty  numeric,
  period_key     text,
  portal_units   numeric,
  other_units    numeric
) LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p_group NOT IN ('sku', 'article_color', 'article') THEN
    RAISE EXCEPTION 'invalid p_group: %, expected sku, article_color, or article', p_group;
  END IF;

  RETURN QUERY
  WITH universe AS (
    SELECT sm.vinculum_sku FROM sku_master sm
    UNION
    SELECT ci.vinculum_sku FROM v_current_inventory ci
  ),
  base AS (
    SELECT
      u.vinculum_sku,
      COALESCE(m.article, split_part(u.vinculum_sku, '_', 1)) AS article,
      COALESCE(m.color, split_part(u.vinculum_sku, '_', 2)) AS color,
      COALESCE(m.brand, i.brand_code, 'Unmapped') AS brand,
      COALESCE(i.available_qty, 0)::numeric AS available_qty
    FROM universe u
    LEFT JOIN sku_master m ON m.vinculum_sku = u.vinculum_sku
    LEFT JOIN v_current_inventory i ON i.vinculum_sku = u.vinculum_sku
  ),
  sales_agg AS (
    SELECT
      s.vinculum_sku,
      s.period_key,
      SUM(CASE WHEN s.portal = p_portal THEN s.qty ELSE 0 END) AS portal_units,
      SUM(CASE WHEN s.portal <> p_portal THEN s.qty ELSE 0 END) AS other_units
    FROM sales s
    WHERE s.vinculum_sku IS NOT NULL
      AND s.status IN ('Shipped complete','delivered','Pick complete','Packed')
      AND s.period_key = ANY(p_periods)
    GROUP BY s.vinculum_sku, s.period_key
  ),
  -- every (SKU, requested period) combination, so months with 0 sales still
  -- show up as a 0 column rather than being missing from the pivot
  sku_x_period AS (
    SELECT b.vinculum_sku, pk.period_key
    FROM base b
    CROSS JOIN unnest(p_periods) AS pk(period_key)
  ),
  joined AS (
    SELECT
      b.vinculum_sku, b.article, b.color, b.brand, b.available_qty,
      sxp.period_key,
      COALESCE(sa.portal_units, 0) AS portal_units,
      COALESCE(sa.other_units, 0) AS other_units
    FROM sku_x_period sxp
    JOIN base b ON b.vinculum_sku = sxp.vinculum_sku
    LEFT JOIN sales_agg sa ON sa.vinculum_sku = sxp.vinculum_sku AND sa.period_key = sxp.period_key
  ),
  -- keep a SKU only if it has stock, or sold something (on any portal) in
  -- ANY of the requested periods — otherwise the pivot would be all zeros
  relevant AS (
    SELECT j.vinculum_sku FROM joined j
    GROUP BY j.vinculum_sku
    HAVING MAX(j.available_qty) > 0 OR SUM(j.portal_units + j.other_units) > 0
  )
  SELECT * FROM (
    SELECT
      j.vinculum_sku AS group_key, j.vinculum_sku, j.article, j.color, 1::bigint AS sku_count,
      j.brand, j.available_qty, j.period_key, j.portal_units, j.other_units
    FROM joined j
    JOIN relevant r ON r.vinculum_sku = j.vinculum_sku
    WHERE p_group = 'sku'

    UNION ALL

    SELECT
      (COALESCE(j.article,'?') || ' / ' || COALESCE(j.color,'?')), NULL::text, j.article, j.color, COUNT(DISTINCT j.vinculum_sku)::bigint,
      MAX(j.brand), SUM(j.available_qty), j.period_key, SUM(j.portal_units), SUM(j.other_units)
    FROM joined j
    JOIN relevant r ON r.vinculum_sku = j.vinculum_sku
    WHERE p_group = 'article_color'
    GROUP BY j.article, j.color, j.period_key

    UNION ALL

    SELECT
      COALESCE(j.article,'?'), NULL::text, j.article, NULL::text, COUNT(DISTINCT j.vinculum_sku)::bigint,
      MAX(j.brand), SUM(j.available_qty), j.period_key, SUM(j.portal_units), SUM(j.other_units)
    FROM joined j
    JOIN relevant r ON r.vinculum_sku = j.vinculum_sku
    WHERE p_group = 'article'
    GROUP BY j.article, j.period_key
  ) result;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
-- This is a private internal tool. Only authenticated (logged-in) users may
-- read or write. No public/anon access.
-- ----------------------------------------------------------------------------
ALTER TABLE sku_master        ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_snapshot ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales              ENABLE ROW LEVEL SECURITY;
ALTER TABLE upload_log         ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated read/write sku_master" ON sku_master;
CREATE POLICY "authenticated read/write sku_master" ON sku_master
  FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "authenticated read/write inventory_snapshot" ON inventory_snapshot;
CREATE POLICY "authenticated read/write inventory_snapshot" ON inventory_snapshot
  FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "authenticated read/write sales" ON sales;
CREATE POLICY "authenticated read/write sales" ON sales
  FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "authenticated read/write upload_log" ON upload_log;
CREATE POLICY "authenticated read/write upload_log" ON upload_log
  FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- ----------------------------------------------------------------------------
-- 7. CATALOGUE MASTER
-- Creative/listing data for building portal catalogues (title, category,
-- material, heel type, etc.) — deliberately separate from sku_master so
-- filling this in (slowly, article by article) can never affect
-- inventory/sales matching. Keyed by vinculum_sku, same as everywhere else.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS catalogue_master (
  vinculum_sku    text PRIMARY KEY,
  article         text,
  color           text,
  brand           text,
  vendor          text,
  segment         text,       -- Girl / Boy / Women / Men / Unisex etc.
  category        text,       -- e.g. Heels, Flats, Sneakers
  age_group       text,       -- e.g. 6-6.5Y
  euro_size       text,
  uk_size         text,
  us_size         text,
  cm_size         text,
  upper           text,       -- upper material, e.g. Synthetic
  sole            text,
  heel_height     text,       -- e.g. "1.5 Inches"
  heel_type       text,       -- e.g. Block / Stiletto / Wedge / Flat
  mrp             numeric,
  hsn             text,
  model_no        text,
  item_name       text,       -- internal working name
  display_name    text,       -- customer-facing listing title
  ean             text,       -- barcode
  asin            text,
  notes           text,
  -- spare fields for anything that comes up later, without needing a
  -- schema change each time — use for whatever, rename their meaning
  -- in your own head, they're exposed in the template/download/upload too.
  custom_field_1  text,
  custom_field_2  text,
  custom_field_3  text,
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_catalogue_article  ON catalogue_master (article);
CREATE INDEX IF NOT EXISTS idx_catalogue_brand     ON catalogue_master (brand);
CREATE INDEX IF NOT EXISTS idx_catalogue_category  ON catalogue_master (category);

ALTER TABLE catalogue_master ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated read/write catalogue_master" ON catalogue_master;
CREATE POLICY "authenticated read/write catalogue_master" ON catalogue_master
  FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- How many catalogue rows exist vs how many SKUs actually need one (i.e.
-- SKUs in sku_master that don't yet have a matching catalogue_master row) —
-- powers a small coverage stat on the Catalogue page.
CREATE OR REPLACE FUNCTION fn_catalogue_coverage()
RETURNS TABLE (
  total_master_skus    bigint,
  catalogued_skus      bigint,
  uncatalogued_skus    bigint
) LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT
    (SELECT COUNT(*) FROM sku_master),
    (SELECT COUNT(*) FROM sku_master m WHERE EXISTS (SELECT 1 FROM catalogue_master c WHERE c.vinculum_sku = m.vinculum_sku)),
    (SELECT COUNT(*) FROM sku_master m WHERE NOT EXISTS (SELECT 1 FROM catalogue_master c WHERE c.vinculum_sku = m.vinculum_sku));
$$;

CREATE OR REPLACE FUNCTION fn_distinct_categories()
RETURNS TABLE (category text) LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT DISTINCT c.category FROM catalogue_master c WHERE c.category IS NOT NULL ORDER BY 1;
$$;
