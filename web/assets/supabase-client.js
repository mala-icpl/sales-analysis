// Requires the Supabase UMD script to be loaded first (see <head> of each page):
// <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>
// That gives us a global `supabase` factory — we shadow it with the client instance.
const sb = window.supabase.createClient(
  window.APP_CONFIG.SUPABASE_URL,
  window.APP_CONFIG.SUPABASE_ANON_KEY
);
