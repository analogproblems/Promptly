#!/usr/bin/env node
// Renders the icon for every platform from tools/icons/icon.cjs.
//
// Needs Node with the playwright package (its Chromium does the drawing) and
// ImageMagick's `convert` for the Windows .ico. Run from the repository root:
//   node tools/icons/render.cjs
// or `make icons`. The outputs are committed, so this only runs when the
// icon changes.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');
const { icon } = require('./icon.cjs');

const root = path.resolve(__dirname, '..', '..');
const app = path.join(root, 'app');
const ID = 'dev.promptly.promptly';

function out(rel) {
  const p = path.join(root, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  return p;
}

async function main() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 64, height: 64 }, deviceScaleFactor: 1 });

  async function render(file, size, opts = {}) {
    await page.setViewportSize({ width: size, height: size });
    const svg = icon({ size, ...opts });
    await page.setContent(
      `<html><body style="margin:0;background:transparent"><div style="width:${size}px;height:${size}px">` +
        svg.replace('width="1024" height="1024"', `width="${size}" height="${size}"`) +
        '</div></body></html>',
    );
    await page.screenshot({ path: out(file), omitBackground: opts.background !== 'square' });
    return out(file);
  }

  // The master SVG, for the docs and the Linux scalable icon.
  fs.writeFileSync(out('app/assets/icon/promptly.svg'), icon() + '\n');
  fs.writeFileSync(out(`app/linux/icons/hicolor/scalable/apps/${ID}.svg`), icon() + '\n');

  // In-app and the Linux window icon.
  await render('app/assets/icon/promptly.png', 512);

  // Linux icon theme sizes, for the .deb and for the desktop file.
  for (const s of [16, 24, 32, 48, 64, 128, 256, 512]) {
    await render(`app/linux/icons/hicolor/${s}x${s}/apps/${ID}.png`, s);
  }

  // Windows: one .ico holding every size.
  const icoParts = [];
  for (const s of [16, 24, 32, 48, 64, 128, 256]) {
    icoParts.push(await render(`build/icons/win-${s}.png`, s));
  }
  execFileSync('convert', [...icoParts, out('app/windows/runner/resources/app_icon.ico')]);

  // Android: legacy launcher icons, adaptive foreground and monochrome layers.
  const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
  for (const [d, m] of Object.entries(densities)) {
    const res = `app/android/app/src/main/res/mipmap-${d}`;
    await render(`${res}/ic_launcher.png`, 48 * m);
    await render(`${res}/ic_launcher_foreground.png`, 108 * m, { background: 'none', scale: 0.62 });
    await render(`${res}/ic_launcher_monochrome.png`, 108 * m, { background: 'none', scale: 0.62, glyphColor: '#FFFFFF' });
  }
  fs.writeFileSync(
    out('app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml'),
    `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
`,
  );
  fs.writeFileSync(
    out('app/android/app/src/main/res/values/ic_launcher_background.xml'),
    `<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#0E1116</color>
</resources>
`,
  );

  // macOS and iOS sets, ready for when those builds happen. iOS icons carry
  // no transparency: the system rounds the corners itself.
  for (const s of [16, 32, 64, 128, 256, 512, 1024]) {
    await render(`app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${s}.png`, s);
  }
  const ios = {
    'Icon-App-20x20@1x': 20, 'Icon-App-20x20@2x': 40, 'Icon-App-20x20@3x': 60,
    'Icon-App-29x29@1x': 29, 'Icon-App-29x29@2x': 58, 'Icon-App-29x29@3x': 87,
    'Icon-App-40x40@1x': 40, 'Icon-App-40x40@2x': 80, 'Icon-App-40x40@3x': 120,
    'Icon-App-60x60@2x': 120, 'Icon-App-60x60@3x': 180,
    'Icon-App-76x76@1x': 76, 'Icon-App-76x76@2x': 152, 'Icon-App-83.5x83.5@2x': 167,
    'Icon-App-1024x1024@1x': 1024,
  };
  for (const [name, s] of Object.entries(ios)) {
    await render(`app/ios/Runner/Assets.xcassets/AppIcon.appiconset/${name}.png`, s, { background: 'square' });
  }

  await browser.close();
  fs.rmSync(path.join(root, 'build'), { recursive: true, force: true });
  console.log('icons rendered');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
