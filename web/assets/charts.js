// Shared chart config: fixed categorical color assignment (never re-cycled
// per filter — same portal/brand always gets the same color everywhere).
const PORTAL_COLOR = {
  "Myntra": "#2a78d6",
  "Nykaa Fashion": "#eb6834",
  "Nykaa.com": "#1baf7a",
  "Ajio": "#eda100",
  "Flipkart": "#e87ba4",
  "Amazon": "#008300",
  "Tata Cliq": "#4a3aa7",
  "Own Website": "#e34948",
  "Other": "#898781",
};
const BRAND_COLOR = {
  "Carlton London": "#2a78d6",
  "ELLE": "#eb6834",
  "CL Sport": "#1baf7a",
  "ICONICS": "#eda100",
};
function brandColor(b) { return BRAND_COLOR[b] || "#898781"; }
function portalColor(p) { return PORTAL_COLOR[p] || "#898781"; }

const HEALTH_COLOR = {
  HEALTHY: "#0ca30c",
  LOW_COVER: "#fab219",
  STOCKOUT: "#d03b3b",
  OVERSTOCK: "#ec835a",
  DEAD_STOCK: "#898781",
  DISCONTINUED_OUT: "#c3c2b7",
};
const HEALTH_LABEL = {
  HEALTHY: "Healthy",
  LOW_COVER: "Low stock cover",
  STOCKOUT: "Stockout (reorder)",
  OVERSTOCK: "Overstock",
  DEAD_STOCK: "Dead stock",
  DISCONTINUED_OUT: "Discontinued (sold out)",
};

Chart.defaults.font.family = "system-ui, -apple-system, 'Segoe UI', sans-serif";
Chart.defaults.font.size = 12;
Chart.defaults.color = "#52514e";
Chart.defaults.borderColor = "#e1e0d9";

function fmtINR(n) {
  if (n === null || n === undefined || Number.isNaN(n)) return "—";
  const abs = Math.abs(n);
  if (abs >= 1e7) return "₹" + (n / 1e7).toFixed(2) + "Cr";
  if (abs >= 1e5) return "₹" + (n / 1e5).toFixed(2) + "L";
  if (abs >= 1e3) return "₹" + (n / 1e3).toFixed(1) + "k";
  return "₹" + Math.round(n).toLocaleString("en-IN");
}
function fmtNum(n) {
  if (n === null || n === undefined || Number.isNaN(n)) return "—";
  return Math.round(n).toLocaleString("en-IN");
}

function horizontalBarChart(canvasId, labels, values, colors, valueFormatter) {
  const ctx = document.getElementById(canvasId).getContext("2d");
  return new Chart(ctx, {
    type: "bar",
    data: {
      labels,
      datasets: [{
        data: values,
        backgroundColor: colors,
        borderRadius: 4,
        maxBarThickness: 22,
      }],
    },
    options: {
      indexAxis: "y",
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: "#0b0b0b",
          padding: 10,
          callbacks: {
            label: (item) => valueFormatter ? valueFormatter(item.raw) : item.raw,
          },
        },
      },
      scales: {
        x: { grid: { color: "#e1e0d9" }, border: { display: false }, ticks: { callback: (v) => valueFormatter ? valueFormatter(v) : v } },
        y: { grid: { display: false }, border: { display: false } },
      },
    },
  });
}

function donutChart(canvasId, labels, values, colors) {
  const ctx = document.getElementById(canvasId).getContext("2d");
  return new Chart(ctx, {
    type: "doughnut",
    data: { labels, datasets: [{ data: values, backgroundColor: colors, borderWidth: 2, borderColor: "#fcfcfb" }] },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      cutout: "62%",
      plugins: {
        legend: { display: false },
        tooltip: { backgroundColor: "#0b0b0b", padding: 10 },
      },
    },
  });
}

function lineChart(canvasId, labels, datasets) {
  const ctx = document.getElementById(canvasId).getContext("2d");
  return new Chart(ctx, {
    type: "line",
    data: {
      labels,
      datasets: datasets.map(d => ({
        label: d.label,
        data: d.data,
        borderColor: d.color,
        backgroundColor: d.color,
        borderWidth: 2,
        pointRadius: 3,
        pointHoverRadius: 5,
        tension: 0.15,
      })),
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { position: "bottom", labels: { usePointStyle: true, boxWidth: 8 } },
        tooltip: { backgroundColor: "#0b0b0b", padding: 10 },
      },
      scales: {
        x: { grid: { display: false }, border: { display: false } },
        y: { grid: { color: "#e1e0d9" }, border: { display: false } },
      },
    },
  });
}
