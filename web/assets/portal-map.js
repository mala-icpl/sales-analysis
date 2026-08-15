// Maps a raw Vinclum "Order Channel" string into:
//   portal  - the customer-facing marketplace (what Mala wants to slice by)
//   entity  - which legal entity/seller account it sold under (ICPL / Global / Iconic)
//   unit    - warehouse/unit suffix if present (Unit1 / Unit2)
//
// Rule: match on lowercase-contains checks, most specific first.
// Anything that doesn't match falls into portal "Other" with the raw value
// preserved, so nothing silently disappears — new channel strings just show
// up as "Other" until this map is extended.

function deriveEntity(raw) {
  const s = raw.toLowerCase();
  if (s.includes('global')) return 'Global';
  if (s.includes('iconic')) return 'Iconic';
  if (s.includes('icpl')) return 'ICPL';
  return 'Unknown';
}

function deriveUnit(raw) {
  const s = raw.toLowerCase();
  if (s.includes('unit2') || s.includes('unit-2') || s.includes('unit 2')) return 'Unit2';
  if (s.includes('unit1') || s.includes('unit-1') || s.includes('unit 1')) return 'Unit1';
  return null;
}

const PORTAL_RULES = [
  // [matcher(lowercase string) => boolean, portalName]
  [s => s.includes('nykaa fashion'), 'Nykaa Fashion'],
  [s => s.includes('nykaa.com') || s.includes('nykaa com'), 'Nykaa.com'],
  [s => s.includes('nykaa'), 'Nykaa Fashion'], // fallback if "fashion"/".com" omitted
  [s => s.includes('myntra'), 'Myntra'],
  [s => s.includes('ajio'), 'Ajio'],
  [s => s.includes('cloudtail'), 'Amazon'], // Cloudtail = Amazon dropship arm
  [s => s.includes('amazon'), 'Amazon'],
  [s => s.includes('flipkart'), 'Flipkart'],
  [s => s.includes('tata cliq') || s.includes('tata_cliq') || s.includes('tatacliq'), 'Tata Cliq'],
  [s => s.includes('shopify'), 'Own Website'],
];

function derivePortal(raw) {
  const s = (raw || '').toLowerCase();
  for (const [match, portal] of PORTAL_RULES) {
    if (match(s)) return portal;
  }
  return 'Other';
}

function mapOrderChannel(raw) {
  const value = (raw || '').trim();
  return {
    portal: derivePortal(value),
    entity: deriveEntity(value),
    unit: deriveUnit(value),
  };
}

window.PortalMap = { mapOrderChannel, derivePortal, deriveEntity, deriveUnit };
