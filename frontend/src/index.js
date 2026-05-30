"use strict";

require("./index.scss");
require("elm-keyboard-shortcut");

const { Elm } = require("./Main");

function normalizeTheme(value) {
    return value === "light" || value === "dark" ? value : "auto";
}

function applyTheme(theme) {
    if (theme === "auto") {
        delete document.documentElement.dataset.theme;
    } else {
        document.documentElement.dataset.theme = theme;
    }
}

const initialTheme = normalizeTheme(localStorage.getItem("theme"));
applyTheme(initialTheme);

const app = Elm.Main.init({
    flags: {
        elasticsearchMappingSchemaVersion: parseInt(
            process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION,
        ),
        elasticsearchUrl: process.env.ELASTICSEARCH_URL || "/backend",
        elasticsearchUsername:
            process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv",
        elasticsearchPassword:
            process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh",
        nixosChannels: JSON.parse(process.env.NIXOS_CHANNELS),
        theme: initialTheme,
    },
});

if (app.ports && app.ports.setTheme) {
    app.ports.setTheme.subscribe((value) => {
        const theme = normalizeTheme(value);
        try {
            localStorage.setItem("theme", theme);
        } catch (_) {}
        applyTheme(theme);
    });
}

if (app.ports && app.ports.copyToClipboard) {
    app.ports.copyToClipboard.subscribe((text) => {
        if (!text || !navigator.clipboard) return;
        navigator.clipboard.writeText(text).catch(() => {});
    });
}

document.addEventListener("DOMContentLoaded", function () {
    const shortcutEl = document.getElementById("shortcut-list-el");
    const searchInput = document.getElementById("search-query-input");
    // the shortcutEl is only used for focusing the search input.
    // disable it when the search input is focused so we can type normally.
    if (shortcutEl && searchInput) {
        searchInput.addEventListener("focus", () => {
            shortcutEl.disconnectedCallback();
        });
        searchInput.addEventListener("blur", () => {
            shortcutEl.connectedCallback();
        });
    }
});

// `j` / `k` move the selection between search result items, `Enter`
// activates the selected one. Selection is tracked with a class instead
// of browser focus, since the result `<li>`s are not focusable by default
// and the global `*:focus { outline-width: 0 }` rule would hide any focus
// ring anyway.
const SELECTED_CLASS = "result-selected";
let selectedResultId = null;

function isTypingTarget(target) {
    return (
        target &&
        target.matches &&
        target.matches(
            "input, textarea, select, [contenteditable=true], [contenteditable='']",
        )
    );
}

function applySelection() {
    document.querySelectorAll("." + SELECTED_CLASS).forEach((el) => {
        if (el.id !== selectedResultId) {
            el.classList.remove(SELECTED_CLASS);
        }
    });
    if (!selectedResultId) {
        return;
    }
    const el = document.getElementById(selectedResultId);
    if (el && !el.classList.contains(SELECTED_CLASS)) {
        el.classList.add(SELECTED_CLASS);
    }
}

// Elm's VDOM diff replaces the `class` attribute on re-render (e.g. when
// toggling a result's expanded view), which would otherwise wipe our
// `result-selected` class. Re-apply it whenever the DOM changes.
new MutationObserver(applySelection).observe(document.body, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["class"],
});

document.addEventListener("keydown", (event) => {
    if (event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) {
        return;
    }
    if (isTypingTarget(event.target)) {
        return;
    }

    if (event.key === "Enter") {
        if (!selectedResultId) {
            return;
        }
        const current = document.getElementById(selectedResultId);
        if (!current) {
            return;
        }
        // The toggle anchor on result titles is rendered with `href=""`
        // (a real `href` would be a navigation link, e.g. the flake source
        // URL shown alongside the title for flake results).
        const link =
            current.querySelector('a[href=""]') || current.querySelector("a");
        if (link) {
            event.preventDefault();
            link.click();
        }
        return;
    }

    if (event.key !== "j" && event.key !== "k") {
        return;
    }

    const items = Array.from(document.querySelectorAll('[id^="result-"]'));
    if (items.length === 0) {
        return;
    }

    const currentIndex = selectedResultId
        ? items.findIndex((el) => el.id === selectedResultId)
        : -1;

    let nextIndex;
    if (event.key === "j") {
        nextIndex =
            currentIndex < 0 ? 0 : Math.min(currentIndex + 1, items.length - 1);
    } else {
        nextIndex = currentIndex < 0 ? 0 : Math.max(currentIndex - 1, 0);
    }

    const next = items[nextIndex];
    selectedResultId = next.id;
    applySelection();
    event.preventDefault();
    next.scrollIntoView({ block: "nearest" });
});
