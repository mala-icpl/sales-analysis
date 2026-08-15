// Renders the shared sidebar into a <div id="app-nav"></div> placeholder.
// Call renderNav("dashboard" | "inventory" | "sales" | "upload") after the
// DOM is ready, before auth-guard fills in the email.
function renderNav(active) {
  const items = [
    { key: "dashboard", href: "index.html", label: "Overview" },
    { key: "inventory", href: "inventory.html", label: "Inventory Health" },
    { key: "sales", href: "sales.html", label: "Sales Analysis" },
    { key: "upload", href: "upload.html", label: "Upload Data" },
  ];
  const el = document.getElementById("app-nav");
  if (!el) return;
  el.innerHTML = `
    <div class="brand-mark">Iconic Creation<span>Inventory &amp; Sales Health</span></div>
    ${items.map(i => `<a class="nav-link${i.key === active ? " active" : ""}" href="${i.href}">${i.label}</a>`).join("")}
    <div class="sidebar-footer">
      Signed in as<br><strong id="user-email">…</strong>
      <button id="sign-out-btn">Sign out</button>
    </div>
  `;
}
