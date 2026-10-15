// The Promptly icon, drawn as SVG from a few parameters so the same shape
// comes out right at 16 px and at 1024 px: a prompt chevron in the accent
// green and the cursor beside it, on the dark surface.
//
// Used by render.cjs; `make icons` regenerates every platform's files.

const GREEN = '#7CE38B';
const TEXT = '#E6EDF3';
const BG_TOP = '#1B222C';
const BG_BOTTOM = '#0B0E13';
const BORDER = '#2A323D';

/**
 * @param {object} o
 * @param {number} [o.size] pixel size the SVG is drawn at (decides small-size tweaks)
 * @param {'rounded'|'square'|'none'} [o.background] rounded square, full square (iOS masks it), or nothing
 * @param {number} [o.scale] glyph scale, 1 fills the design, 0.9 keeps clear of the adaptive-icon safe circle
 * @param {string} [o.glyphColor] one colour for both marks (monochrome layers)
 */
function icon(o = {}) {
  const size = o.size ?? 1024;
  const background = o.background ?? 'rounded';
  const scale = o.scale ?? 1;
  const small = size <= 32;
  const stroke = small ? 132 : 104;
  const chevron = o.glyphColor ?? GREEN;
  const cursor = o.glyphColor ?? TEXT;
  const parts = [];
  parts.push('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">');
  parts.push('<defs>');
  parts.push(`<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${BG_TOP}"/><stop offset="1" stop-color="${BG_BOTTOM}"/></linearGradient>`);
  parts.push('<filter id="glow" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="30"/></filter>');
  parts.push('</defs>');
  if (background === 'rounded') {
    parts.push('<rect x="0" y="0" width="1024" height="1024" rx="226" fill="url(#bg)"/>');
    if (!small) parts.push(`<rect x="7" y="7" width="1010" height="1010" rx="220" fill="none" stroke="${BORDER}" stroke-width="10"/>`);
  } else if (background === 'square') {
    parts.push('<rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>');
  }
  // The glyph sits a touch left of centre so the chevron and the cursor
  // read as one mark, ">_".
  const g = `translate(512 512) scale(${scale}) translate(-512 -512)`;
  parts.push(`<g transform="${g}">`);
  const path = 'M300 322 L520 512 L300 702';
  if (!small && !o.glyphColor) {
    parts.push(`<path d="${path}" fill="none" stroke="${GREEN}" stroke-width="${stroke + 10}" stroke-linecap="round" stroke-linejoin="round" opacity="0.5" filter="url(#glow)"/>`);
  }
  parts.push(`<path d="${path}" fill="none" stroke="${chevron}" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round"/>`);
  const cw = small ? 206 : 196;
  const ch = small ? 92 : 74;
  parts.push(`<rect x="582" y="${702 - ch + 18}" width="${cw}" height="${ch}" rx="${ch / 3}" fill="${cursor}"/>`);
  parts.push('</g>');
  parts.push('</svg>');
  return parts.join('\n');
}

module.exports = { icon };
