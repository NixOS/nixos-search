#!/usr/bin/env node
// Writes the AppStream screenshots out of Elasticsearch as static files, one
// per `screenshot` document. Writes `<SCREENSHOTS_OUT_DIR>/<screenshot_file>`
// for every channel in `NIXOS_CHANNELS` (default output dir:
// `public/screenshots`). See `lib/image-assets.mjs` for how and when the files
// are written.
//
// A package carries two names per screenshot: the thumbnail a result list
// shows, and the larger copy a reader who opens it gets. Both are documents of
// this one type, so both are written here.

import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { writeImages } from "./lib/image-assets.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

await writeImages({
    label: "screenshots",
    type: "screenshot",
    fileField: "screenshot_file",
    dataField: "screenshot_data",
    outDir:
        process.env.SCREENSHOTS_OUT_DIR ||
        join(__dirname, "../public/screenshots"),
});
