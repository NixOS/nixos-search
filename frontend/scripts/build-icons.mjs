#!/usr/bin/env node
// Writes the desktop entry icons out of Elasticsearch as static files, one per
// `icon` document. Writes `<ICONS_OUT_DIR>/<icon_file>` for every channel in
// `NIXOS_CHANNELS` (default output dir: `public/icons`). See
// `lib/image-assets.mjs` for how and when the files are written.

import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { writeImages } from "./lib/image-assets.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

await writeImages({
    label: "icons",
    type: "icon",
    fileField: "icon_file",
    dataField: "icon_data",
    outDir: process.env.ICONS_OUT_DIR || join(__dirname, "../public/icons"),
});
