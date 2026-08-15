# Iconic Creation — Inventory & Sales Health Dashboard

A private dashboard for tracking SKU-level inventory health and sales
performance, brand-wise and portal-wise, from your Vinclum exports.

## How it's built (and why)

- **Database:** Supabase (hosted Postgres). All the health-metric math
  (stock cover days, dead stock, sell-through rate, etc.) runs as SQL
  functions inside the database, so the site stays fast even with tens of
  thousands of SKUs.
- **Site:** plain HTML/CSS/JavaScript pages — no build step. They talk
  directly to Supabase from the browser.
- **Hosting:** Render, as a static site (just serves the files — cheapest
  Render tier, works fine here since there's no server-side code).
- **Login:** Supabase Auth, email + password. There's no public sign-up
  page on purpose — only accounts you create can log in.

## One-time setup

### 1. Create a Supabase project
Go to [supabase.com](https://supabase.com) → New project. Pick any name
and region (Mumbai/`ap-south-1` if offered, for lowest latency from India).
Save the database password somewhere safe when it's shown.

### 2. Run the database schema
In the Supabase dashboard: **SQL Editor → New query**, paste the entire
contents of `supabase/schema.sql`, and run it. This creates all tables,
the health-metric functions, and the security rules. Safe to re-run later
if the schema changes.

### 3. Create your login
**Authentication → Users → Add user** (not "invite" — use "Add user"
so you can set a password directly). Use your email and a password. This
is the only account you need — your husband can either share it or you
can add a second user the same way.

### 4. Get your API keys
**Project Settings → API**. Copy:
- **Project URL** (looks like `https://xxxxx.supabase.co`)
- **anon public** key (a long string starting with `eyJ...`)

Open `web/assets/config.js` in this project and paste them in:
```js
window.APP_CONFIG = {
  SUPABASE_URL: "https://xxxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJ...",
};
```
(These are safe to expose publicly — that's what "anon public" means.
Real access control happens via the Row Level Security rules in
`schema.sql`, which only allow logged-in users to read or write anything.)

### 5. Put the code on GitHub (recommended, makes Render auto-deploy on changes)
Create a new empty repository on [github.com](https://github.com), then
from this project folder:
```bash
git init
git add .
git commit -m "Initial dashboard"
git remote add origin <your-repo-url>
git push -u origin main
```

### 6. Deploy to Render
Go to [render.com](https://render.com) → New → Static Site → connect the
GitHub repo you just created. Render should auto-detect `render.yaml`; if
asked manually, set:
- **Publish directory:** `web`
- **Build command:** (leave empty / `echo skip`)

Click Deploy. In a minute or two you'll have a live URL like
`https://iconic-inventory-dashboard.onrender.com`.

*(If you'd rather not use GitHub, Render also supports dragging the `web`
folder in directly for a manual deploy — ask and I'll walk you through
that instead.)*

### 7. Load your data
Open the live site → log in → **Upload Data**. Upload in this order:
1. **SKU Master** first (the bridge file — inventory and sales join
   against it)
2. **Inventory** (pick the date the snapshot is as of)
3. **Sales** (month is detected automatically from the file)

## Ongoing use

- **Inventory:** re-upload whenever you pull a fresh snapshot from
  Vinclum. Re-uploading the same date safely replaces that date's data.
- **Sales:** re-upload monthly. Re-uploading a month safely replaces just
  that month — no duplicate counting.
- **SKU Master:** re-upload whenever you update it in Vinclum (new
  articles, discontinued ones, etc.). Existing SKUs get updated in place;
  nothing is deleted, so old inventory referencing a since-removed SKU
  still shows up correctly as "legacy stock."

## What the health flags mean

| Flag | Meaning |
|---|---|
| Stockout | Actively selling, zero stock, still an active listing — reorder |
| Low stock cover | Selling, but under ~2 weeks of stock left at current pace |
| Healthy | Stock and sales pace are reasonably matched |
| Overstock | Selling, but more than ~3 months of stock on hand |
| Dead stock | Stock sitting with zero sales in the selected window |
| Discontinued (sold out) | No stock left, but the article is already discontinued — informational only, no action needed |

The "window" (30/60/90 days) is measured back from the most recent date in
your uploaded sales data, not from today — so it stays accurate even if a
monthly upload is a few days late.

## Known data-quality notes (from your actual files)

- ~13% of inventory rows and ~0.5% of sales rows won't match the SKU
  Master — per your confirmation, these are old/discontinued articles you
  intentionally stopped tracking in the master file. They still show up
  in the dashboard (as "legacy/unmapped"), just without brand/status info.
- The EAN column in some inventory CSV exports can get corrupted into
  scientific notation by Excel (e.g. `8.9E+12`) if not formatted as Text
  before saving as CSV. The importer doesn't rely on that column — it uses
  "SKU Desc" instead — so this doesn't break anything, but worth fixing at
  export time if you want clean EAN data for other purposes.
