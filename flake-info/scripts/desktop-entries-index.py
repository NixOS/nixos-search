#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages(ps: with ps; [ requests zstandard brotli ])"
#!nix-shell -p nix imagemagick librsvg
"""Index desktop entries and AppStream metadata by reading the binary cache.

Get desktop entries, icons and screenshots for Hydra-cached packages.
This complements `packages.json`, which only has info from `makeDesktopItem`.

It works in three phases:

  A. For each store path, fetch `<hash>.ls` -- a small compressed JSON listing
     of the NAR's file tree -- and look for `share/applications/*.desktop` and
     the AppStream metadata in `share/metainfo` and `share/appdata`.
     Cheap: a few KB per package, no NAR download.
  B. Fetch the NAR of these files and extract them. Write their icons
     to `--icon-dir`, with content hashes for name for deduplication. By not
     using a derivation for this, space may be saved by not having to keep all
     package NARs in-store.
  C. AppStream names its screenshots as URLs on the upstream project's own
     hosting, not as files in the NAR. Download each one once and write it to
     `--screenshot-dir`, named by content like the icons. A screenshot can be
     written twice: a thumbnail for a result list, and a larger copy for a
     visitor who opens it.

Every package is reported with a `status`, because the ways of finding nothing
are not equivalent and must not be conflated:

  `indexed`     entries or components were read.
  `no-entries`  built, and it genuinely ships none.
  `not-built`   no `.ls` in the cache. Results exist only for revisions Hydra
                has already built and pushed, so on a fresh revision this is the
                common case; check the summary before treating a run as
                complete.
  `unresolved`  files exist but could not be read, e.g. a symlink whose
                target is not in the cache.

Merging with `packages.json`:

    This index reads what a package ships, including the entries nixpkgs takes
    verbatim from upstream and evaluation therefore cannot see, so it wins
    wherever it found any. AppStream metadata is only ever read here: nixpkgs
    ships it verbatim from upstream and never constructs it.

        indexed = json.load(open("desktop-entries.json"))["packages"]
        merged = json.load(open("packages.json"))["packages"]
        for attr, package in merged.items():
            found = indexed.get(attr, {})
            entries = found.get("desktopEntries")
            package["desktopEntries"] = entries or package.get("desktopEntries", [])
            package["screenshots"] = found.get("screenshots", [])

Usage:

    # index everything (long: one request per store path in phase A)
    ./desktop-entries-index.py --icon-dir icons --output desktop-entries.json

    # index just selected attributes
    ./desktop-entries-index.py keepassxc vlc krita

    # trimmed the way a consumer serving images to browsers wants them: only
    # formats a browser draws, rasters at one size, vectors kept below 16 KB,
    # and screenshots as thumbnails small enough for a result list
    ./desktop-entries-index.py --icon-dir icons --icon-extensions png,svg \\
        --icon-pixel-size 64 --icon-colors 256 --icon-svg-max-bytes 16384 \\
        --screenshot-dir screenshots --screenshot-pixel-size 224 \\
        --screenshot-quality 82 --screenshot-large-pixel-size 752 \\
        --screenshot-large-quality 80 --output desktop-entries.json
"""

import argparse
import bz2
import concurrent.futures
import configparser
import hashlib
import json
import lzma
import os
import pathlib
import posixpath
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from collections.abc import Callable, Hashable, Iterator, Sequence
from typing import Any, NotRequired, TypedDict, cast
from xml.etree import ElementTree

import requests

# Overridable through `--cache-url` and `--store-dir`, for a private binary
# cache or a Nix installed under another prefix.
DEFAULT_CACHE_URL = "https://cache.nixos.org"

DEFAULT_STORE_DIR = "/nix/store"

APPLICATIONS_DIR = "share/applications"

# Where a package ships its AppStream metadata. `share/metainfo` is the current
# location; `share/appdata` is the pre-1.0 one, which packages that have not
# moved their file still use. Both hold `<component>` documents, under either
# the `.metainfo.xml` or the older `.appdata.xml` spelling.
METAINFO_DIRS = ("share/metainfo", "share/appdata")

# What is read out of each directory phase A looks in.
SCANNED_DIRS: dict[str, str] = {
    APPLICATIONS_DIR: ".desktop",
    **dict.fromkeys(METAINFO_DIRS, ".xml"),
}

# Where an icon named by a desktop entry may be found, per the icon theme spec.
ICON_DIRS = ("share/icons", "share/pixmaps")

# The formats the icon theme spec allows, overridable through
# `--icon-extensions`. XPM is in the spec yet no browser reads it, so a consumer
# serving browsers wants `--icon-pixel-size`, which converts rasters to PNG.
DEFAULT_ICON_EXTENSIONS = (".png", ".svg", ".xpm")

# Hex digits of an image's digest naming its file: 128 bits, far past collision
# risk at this scale, and short enough to read.
IMAGE_NAME_LENGTH = 32

# Nothing is re-rendered unless asked for, since what an icon should be is the
# consumer's business. It does pay where wanted: over the largest icon each of 71
# packages ships, `--icon-pixel-size 64 --icon-colors 256` turns 2.3 MB into 82 KB.
DEFAULT_ICON_PIXEL_SIZE = 0

DEFAULT_ICON_COLORS = 0

# Above this a vector is rasterized anyway, being traced artwork rather than an
# icon. Over 60 upstream scalable icons, gzipped: keeping every one costs 136 KB,
# a 16384 ceiling 96 KB while keeping 87% scalable, rasterizing the lot 73 KB.
DEFAULT_ICON_SVG_MAX_BYTES = 0

# Screenshots are mirrored as they ship unless a size is asked for. A width of
# 224 matches what Flathub serves as its smallest thumbnail. Across the 2835
# screenshots of `nixos-unstable`, one averages 5 KB at that width, against the
# 278 KB of the source image upstream serves.
DEFAULT_SCREENSHOT_PIXEL_SIZE = 0

# The WebP quality to re-render a screenshot at, or 0 to mirror the source
# image. At 224 pixels wide, 82 costs half of what the same image costs as a
# PNG quantized to 256 colors, at a size where neither shows its artifacts.
DEFAULT_SCREENSHOT_QUALITY = 0

# The width of a second, larger copy of each screenshot, or 0 for no such copy.
# A thumbnail shows which application a result is, but it is too small to read
# an interface in, thus a consumer that lets a visitor open a screenshot needs a
# larger image than its result list shows. 752 is what Flathub serves as its
# large thumbnail. One averages 29 KB at that width, thus all 2835 screenshots
# of `nixos-unstable` together are 82 MB.
DEFAULT_SCREENSHOT_LARGE_PIXEL_SIZE = 0

# The WebP quality of that larger copy. Lower than the thumbnail's, because an
# image this size holds its detail over a coarser quantization than a thumbnail,
# whose few pixels each carry more of the picture.
DEFAULT_SCREENSHOT_LARGE_QUALITY = 0

# How many screenshots to keep per package, best first, or 0 for every one. A
# package that has screenshots has 2.66 of them on average, thus keeping all of
# them costs less than three times what keeping only the first one costs.
DEFAULT_SCREENSHOTS_PER_PACKAGE = 0

# A screenshot is fetched from whatever host the upstream project put it on, so
# neither the response size nor the time it takes is bounded by anything this
# script controls.
SCREENSHOT_TIMEOUT = 30

DEFAULT_SCREENSHOT_MAX_BYTES = 16 * 1024 * 1024

# What a screenshot may be mirrored as without re-rendering. AppStream allows
# any raster format; these are the ones every browser draws.
SCREENSHOT_EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp")

# What a screenshot may be read from, which is wider: a format no browser draws
# is still worth fetching when it is about to be re-rendered to WebP.
SCREENSHOT_READ_EXTENSIONS = (*SCREENSHOT_EXTENSIONS, ".gif", ".avif")

CONTENT_TYPE_EXTENSIONS = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/avif": ".avif",
}

# The attribute AppStream localizes its captions with.
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"

# Translated keys, e.g. `Name[de]`, under this schema's names. Of the spec's
# `lang_COUNTRY.ENCODING@MODIFIER` locale syntax only `lang` is required.
LOCALIZED_FIELDS = {
    "Name": "desktopName",
    "GenericName": "genericName",
    "Comment": "comment",
    "Keywords": "keywords",
    "Icon": "icon",
}

LOCALIZED_KEY = re.compile(rf"^({'|'.join(LOCALIZED_FIELDS)})\[([^\]]+)\]$")

# Parsed entries are cached under this name plus the icon settings, since those
# change the images stored alongside them. Bump the number when the entry shape
# changes, so an older run's cache cannot serve entries missing the new fields.
ENTRY_CACHE = "entries-3"

# Mirrored screenshots are cached under this name plus the settings they were
# rendered with. Bump the number when the record shape changes, as for entries.
SCREENSHOT_CACHE = "screenshots-3"

# How much of a screenshot to read at a time, so that an image over
# `--screenshot-max-bytes` is abandoned rather than held whole.
CHUNK_SIZE = 64 * 1024

# `nix nar cat` is still behind the experimental gate.
NIX = ["nix", "--extra-experimental-features", "nix-command"]

# How many symlinks to follow before giving up on an entry.
MAX_SYMLINK_DEPTH = 8

DEFAULT_CACHE_DIR = (
    pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache"))
    / "desktop-entries-index"
)

# `ci/eval/outpaths.nix` evaluates every supported system by default, which needs
# more memory than a CI runner has. One system is enough for an index keyed by
# attribute path, since entries do not differ per system.
DEFAULT_EVAL_SYSTEMS = "x86_64-linux"


# One node of a `.ls` file tree: `entries` holds the children of a directory,
# `target` the destination of a symlink.
type Node = dict[str, Any]

# A whole `.ls` listing, whose `root` is the NAR's top-level node.
type Listing = dict[str, Any]


class DesktopEntry(TypedDict):
    """The indexable fields of one `.desktop` file.

    Mirrors the schema `pkgs/top-level/desktop-entries.nix` emits. `iconFile`
    names the image written to `--icon-dir`; it is held per entry while
    scanning and lifted to the package before output.
    """

    type: str | None
    desktopName: str | None
    genericName: str | None
    comment: str | None
    icon: str | None
    keywords: list[str]
    mimeTypes: list[str]
    categories: list[str]
    noDisplay: bool
    localized: dict[str, dict[str, str | list[str]]]
    iconFile: NotRequired[str | None]


class Screenshot(TypedDict):
    """One image out of an AppStream component's `<screenshots>`.

    `url` is where upstream hosts it, kept as the provenance of an image this
    index redistributes. `file` names the thumbnail written to
    `--screenshot-dir`, and is None when no directory was given or the image
    could not be read. `largeFile` names the larger copy beside it, and is None
    where `--screenshot-large-pixel-size` asked for none.
    """

    url: str
    caption: str | None
    localized: dict[str, str]
    file: NotRequired[str | None]
    largeFile: NotRequired[str | None]


# What phase C wrote for one screenshot URL: the thumbnail, then the larger copy
# where one was asked for.
type ScreenshotFiles = tuple[str, str | None]


class Component(TypedDict):
    """The indexable fields of one AppStream `<component>`.

    Only the fields no other source has. A component's name, summary and
    categories repeat what its `<launchable>` desktop entry already carries,
    which this index reads directly; its screenshots are carried nowhere else.
    """

    id: str | None
    screenshots: list[Screenshot]


# What one file in a NAR parsed to. Which of the two it is follows from the
# path, so the two are cached side by side under the path that produced them.
type Parsed = DesktopEntry | Component


class Package(TypedDict):
    """One attribute path's result: see the module docstring for `status`."""

    status: str
    desktopEntries: list[dict[str, Any]]
    icons: dict[str, str]
    componentIds: list[str]
    screenshots: list[Screenshot]


def log(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def store_dir_prefix(store_dir: str) -> str:
    """The store directory as paths under it spell it, i.e. with a trailing slash."""
    return store_dir.rstrip("/") + "/"


def store_hash(store_path: str, store_dir: str) -> str:
    """<store dir>/<hash>-name[/...] -> <hash>"""
    rest = store_path[len(store_dir_prefix(store_dir)) :]
    return rest.split("/", 1)[0].split("-", 1)[0]


def decompress(data: bytes, compression: str) -> bytes:
    """Decompress a cache object according to its advertized compression."""
    if compression in ("none", "identity", ""):
        return data
    if compression == "zstd":
        import zstandard

        # NARs carry no content-size header, hence the streaming reader.
        return zstandard.ZstdDecompressor().stream_reader(data).read()
    if compression == "xz":
        return lzma.decompress(data)
    if compression == "bzip2":
        return bz2.decompress(data)
    if compression == "br":
        import brotli

        return brotli.decompress(data)
    raise ValueError(f"unsupported compression: {compression}")


def split_semicolons(value: str) -> list[str]:
    return [item for item in value.split(";") if item != ""]


class CaseSensitiveParser(configparser.ConfigParser):
    """A parser that keeps key case, as the desktop entry spec requires."""

    def optionxform(self, optionstr: str) -> str:
        return optionstr


def parse_desktop_file(text: str) -> DesktopEntry | None:
    """Extract the indexable fields of a `.desktop` file's main section.

    Mirrors the schema `pkgs/top-level/desktop-entries.nix` emits. `strict=False`
    tolerates the duplicate keys and repeated sections that occur in the wild.
    Every locale the file carries is kept; trimming them is the consumer's call.
    """
    parser = CaseSensitiveParser(
        strict=False,
        interpolation=None,
        delimiters=("=",),
        comment_prefixes=("#",),
    )
    try:
        parser.read_string(text)
    except configparser.Error:
        return None
    if not parser.has_section("Desktop Entry"):
        return None
    section = parser["Desktop Entry"]

    localized: dict[str, dict[str, str | list[str]]] = {}
    for key in section:
        match = LOCALIZED_KEY.match(key)
        if match is None:
            continue
        field = LOCALIZED_FIELDS[match.group(1)]
        value = section[key]
        # A localized `Icon` names a different icon rather than translating one,
        # so only the unlocalized name is resolved to an image.
        localized.setdefault(match.group(2), {})[field] = (
            split_semicolons(value) if field == "keywords" else value
        )

    return {
        "type": section.get("Type"),
        "desktopName": section.get("Name"),
        "genericName": section.get("GenericName"),
        "comment": section.get("Comment"),
        "icon": section.get("Icon"),
        "keywords": split_semicolons(section.get("Keywords", "")),
        "mimeTypes": split_semicolons(section.get("MimeType", "")),
        "categories": split_semicolons(section.get("Categories", "")),
        "noDisplay": section.get("NoDisplay", "") == "true",
        "localized": localized,
    }


def parse_metainfo(text: str) -> Component | None:
    """What one AppStream file says, or None if it says nothing indexable.

    Only an upstream `<component>` document is read. A `<components>` catalog is
    a distribution's own index over many packages, which a package has no
    business shipping, and the remaining AppStream root elements describe no
    application.

    Only the fields nothing else carries are taken; see [Component].
    """
    try:
        root = ElementTree.fromstring(text)
    except ElementTree.ParseError:
        return None
    if root.tag != "component":
        return None

    found = root.findall("./screenshots/screenshot")
    screenshots: list[Screenshot] = []
    # `type="default"` marks the screenshot that stands for the application, so
    # it leads; the rest keep the order upstream wrote them in.
    for _, element in sorted(
        enumerate(found), key=lambda pair: (pair[1].get("type") != "default", pair[0])
    ):
        images = element.findall("image")
        # A source image is the one upstream uploaded. Upstream files commonly
        # give no type at all, in which case the first image is that one.
        source = next(
            (image for image in images if image.get("type") == "source"),
            images[0] if images else None,
        )
        if source is None:
            continue
        url = (source.text or "").strip()
        if urllib.parse.urlparse(url).scheme not in ("http", "https"):
            continue

        caption: str | None = None
        localized: dict[str, str] = {}
        for node in element.findall("caption"):
            value = "".join(node.itertext()).strip()
            if not value:
                continue
            locale = node.get(XML_LANG)
            if locale is None:
                caption = value
            else:
                localized[locale] = value
        screenshots.append({"url": url, "caption": caption, "localized": localized})

    identifier = (root.findtext("id") or "").strip()
    # Pre-1.0 components are identified by their desktop file, suffix and all.
    # Dropping it gives the name every other catalog knows the component by,
    # which is what makes the id worth indexing: it joins a nixpkgs package to
    # the same application in Flathub or GNOME Software.
    identifier = identifier.removesuffix(".desktop")
    if not identifier and not screenshots:
        return None
    return {"id": identifier or None, "screenshots": screenshots}


def screenshot_suffix(url: str, content_type: str | None) -> str | None:
    """The file extension to read a downloaded screenshot as, or None.

    `magick` picks its reader by extension, so a URL that names no format falls
    back to what the server said it served.
    """
    suffix = posixpath.splitext(urllib.parse.urlparse(url).path)[1].lower()
    if suffix in SCREENSHOT_READ_EXTENSIONS:
        return suffix
    media_type = (content_type or "").split(";")[0].strip().lower()
    return CONTENT_TYPE_EXTENSIONS.get(media_type)


def render_screenshot(
    data: bytes, suffix: str, pixel_size: int, quality: int
) -> tuple[bytes, str] | None:
    """-> `(bytes, extension)` for one screenshot, or None if it cannot be read.

    An image is mirrored as it ships unless re-rendering was asked for, which is
    what keeps a mirror of the whole corpus to a size an index can hold: across
    the screenshots of `nixos-unstable`, a 224 pixel wide thumbnail averages
    5 KB against the 278 KB of the source image it was made from.
    """
    if not pixel_size and not quality:
        return (data, suffix) if suffix in SCREENSHOT_EXTENSIONS else None

    with tempfile.TemporaryDirectory() as workdir:
        source = pathlib.Path(workdir) / f"screenshot{suffix}"
        # WebP, because a screenshot is a photograph of an interface: it holds
        # more colors than a palette format keeps small, and every browser
        # released since 2020 draws it.
        target = pathlib.Path(workdir) / "screenshot.webp"
        source.write_bytes(data)

        # `[0]` takes the first frame: an animated screenshot would otherwise
        # write one file per frame and none under the name asked for.
        command = ["magick", f"{source}[0]", "-strip"]
        if pixel_size:
            # Width alone, because a screenshot is not square and its aspect
            # ratio is what makes it recognizable at thumbnail size. `>` keeps
            # an image that is already narrower at its own width, since
            # upscaling one costs bytes and shows no more of the interface.
            command += ["-resize", f"{pixel_size}x>"]
        if quality:
            command += ["-quality", str(quality)]
        command.append(str(target))

        if subprocess.run(command, capture_output=True).returncode != 0 or not target.exists():
            return None
        return (target.read_bytes(), ".webp")


def walk_listing(node: Node, prefix: str = "") -> Iterator[tuple[str, Node]]:
    """Yield `(inner path, node)` for everything below a `.ls` tree node."""
    if node.get("type") != "directory":
        return
    for name, child in node.get("entries", {}).items():
        path = f"{prefix}/{name}" if prefix else name
        yield path, child
        yield from walk_listing(child, path)


def icon_rank(path: str) -> tuple[bool, bool, int]:
    """Sort key over the files that could supply one icon name, best first.

    A vector wins because it stays one, and among rasters the largest downscales
    best. `-symbolic` icons are monochrome toolbar glyphs, never an
    application's own, so they lose to anything else.
    """
    size = re.search(r"/(\d+)x\1/", path)
    return ("symbolic" in path, not path.endswith(".svg"), -int(size.group(1)) if size else 0)


def render_icon(
    data: bytes, suffix: str, pixel_size: int, colors: int, svg_max_bytes: int
) -> tuple[bytes, str] | None:
    """-> `(bytes, extension)` for one icon file, or None if it cannot be read.

    An icon is passed through as it ships unless re-rendering was asked for, and
    labeled with what it actually is. A vector stays one even then, drawing
    sharply at any size already: over 60 upstream scalable icons, a sixth came
    out larger once rasterized. Only `svg_max_bytes` overrides that.
    """
    if suffix == ".svg":
        if not svg_max_bytes or len(data) <= svg_max_bytes:
            return (data, ".svg")
    elif not pixel_size and not colors:
        return (data, suffix)

    with tempfile.TemporaryDirectory() as workdir:
        source = pathlib.Path(workdir) / f"icon{suffix}"
        target = pathlib.Path(workdir) / "icon.png"
        source.write_bytes(data)

        if suffix == ".svg":
            # `magick`'s own SVG renderer is markedly worse than librsvg at
            # icon sizes.
            rendered = pathlib.Path(workdir) / "rendered.png"
            command = ["rsvg-convert", str(source), "-o", str(rendered)]
            if pixel_size:
                command[1:1] = ["-w", str(pixel_size), "-h", str(pixel_size)]
            if subprocess.run(command, capture_output=True).returncode != 0:
                return None
            source = rendered

        command = ["magick", str(source), "-strip"]
        if pixel_size:
            command += ["-resize", f"{pixel_size}x{pixel_size}"]
        if colors:
            command += ["-colors", str(colors)]
        # `PNG8:` is a palette format, so it only applies once quantized.
        command.append(f"{'PNG8' if colors else 'PNG'}:{target}")

        if subprocess.run(command, capture_output=True).returncode != 0 or not target.exists():
            return None
        return (target.read_bytes(), ".png")


def find_nixpkgs() -> str:
    """A nixpkgs checkout, from `$NIXPKGS` or `NIX_PATH`.

    Resolved to a real path rather than left as `<nixpkgs>`: only
    `<nixpkgs/ci/eval/outpaths.nix>` is a valid lookup, never
    `<nixpkgs>/ci/eval/outpaths.nix`, so a path is what can be joined onto.
    """
    from_env = os.environ.get("NIXPKGS")
    if from_env:
        return from_env
    try:
        found = subprocess.run(
            ["nix-instantiate", "--find-file", "nixpkgs"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        found = ""
    if not found:
        raise SystemExit(
            "no nixpkgs to enumerate packages from: pass `--nixpkgs <path>`, put one "
            "on `NIX_PATH`, or skip the evaluation altogether by passing an existing "
            "`nix-env -qaP --out-path` dump to `--outpaths <file>`"
        )
    return found


def read_outpaths(
    path: str | None = None,
    nixpkgs: str | None = None,
    store_dir: str = DEFAULT_STORE_DIR,
    systems: str = DEFAULT_EVAL_SYSTEMS,
) -> dict[str, list[str]]:
    """attrpath -> [store path], as produced by `ci/eval/outpaths.nix`.

    That file documents itself as being called exactly this way.
    """
    if path is not None:
        text = pathlib.Path(path).read_text()
    else:
        nixpkgs = nixpkgs or find_nixpkgs()
        log("enumerating packages via ci/eval/outpaths.nix (this takes a while) ...")
        text = subprocess.run(
            [
                "nix-env",
                "-qaP",
                "--no-name",
                "--out-path",
                "-f",
                str(pathlib.Path(nixpkgs) / "ci/eval/outpaths.nix"),
                "--arg",
                "systems",
                json.dumps([system.strip() for system in systems.split(",") if system.strip()]),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    result: dict[str, list[str]] = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        paths: list[str] = []
        for chunk in " ".join(fields[1:]).replace(";", " ").split():
            # Outputs are printed as `outname=/nix/store/...`, the default one
            # unprefixed. Scan every one: entries land in secondary outputs too.
            _, _, store_path = chunk.rpartition("=")
            if store_path.startswith(store_dir_prefix(store_dir)):
                paths.append(store_path)
        if paths:
            result[fields[0]] = paths
    # Otherwise a `--store-dir` naming somewhere the outputs do not live reads
    # as a package set that happens to be empty.
    if text.strip() and not result:
        log(f"warning: no output path under {store_dir_prefix(store_dir)}; is --store-dir right?")
    return result


class Scanner:
    def __init__(
        self,
        cache_dir: str | pathlib.Path,
        icon_dir: str | pathlib.Path | None = None,
        icon_extensions: Sequence[str] = DEFAULT_ICON_EXTENSIONS,
        icon_pixel_size: int = DEFAULT_ICON_PIXEL_SIZE,
        icon_colors: int = DEFAULT_ICON_COLORS,
        icon_svg_max_bytes: int = DEFAULT_ICON_SVG_MAX_BYTES,
        screenshot_dir: str | pathlib.Path | None = None,
        screenshot_pixel_size: int = DEFAULT_SCREENSHOT_PIXEL_SIZE,
        screenshot_quality: int = DEFAULT_SCREENSHOT_QUALITY,
        screenshot_large_pixel_size: int = DEFAULT_SCREENSHOT_LARGE_PIXEL_SIZE,
        screenshot_large_quality: int = DEFAULT_SCREENSHOT_LARGE_QUALITY,
        screenshot_max_bytes: int = DEFAULT_SCREENSHOT_MAX_BYTES,
        cache_url: str = DEFAULT_CACHE_URL,
        store_dir: str = DEFAULT_STORE_DIR,
    ) -> None:
        self.cache_url = cache_url.rstrip("/")
        self.store_dir = store_dir_prefix(store_dir)
        self.cache_dir = pathlib.Path(cache_dir)
        self.icon_dir = pathlib.Path(icon_dir) if icon_dir else None
        self.icon_extensions = tuple(icon_extensions)
        self.icon_pixel_size = icon_pixel_size
        self.icon_colors = icon_colors
        self.icon_svg_max_bytes = icon_svg_max_bytes
        self.screenshot_dir = pathlib.Path(screenshot_dir) if screenshot_dir else None
        self.screenshot_pixel_size = screenshot_pixel_size
        self.screenshot_quality = screenshot_quality
        self.screenshot_large_pixel_size = screenshot_large_pixel_size
        self.screenshot_large_quality = screenshot_large_quality
        self.screenshot_max_bytes = screenshot_max_bytes
        # The listing cache is settings-independent; the entry cache is not.
        self.entry_cache = self.cache_dir / "-".join(
            [
                ENTRY_CACHE,
                "icons" if self.icon_dir else "no-icons",
                str(icon_pixel_size),
                str(icon_colors),
                str(icon_svg_max_bytes),
                *sorted(extension.lstrip(".") for extension in self.icon_extensions),
            ]
        )
        # Screenshots are keyed by their own URL, not by the package that names
        # them, so that one image serves every package that points at it.
        self.screenshot_cache = self.cache_dir / "-".join(
            [
                SCREENSHOT_CACHE,
                str(screenshot_pixel_size),
                str(screenshot_quality),
                str(screenshot_large_pixel_size),
                str(screenshot_large_quality),
            ]
        )
        (self.cache_dir / "ls").mkdir(parents=True, exist_ok=True)
        self.entry_cache.mkdir(parents=True, exist_ok=True)
        if self.icon_dir is not None:
            self.icon_dir.mkdir(parents=True, exist_ok=True)
        if self.screenshot_dir is not None:
            self.screenshot_dir.mkdir(parents=True, exist_ok=True)
            self.screenshot_cache.mkdir(parents=True, exist_ok=True)
        self.local = threading.local()

    @property
    def session(self) -> requests.Session:
        # requests.Session is not thread-safe; give each worker its own.
        if not hasattr(self.local, "session"):
            self.local.session = requests.Session()
        return self.local.session

    def get(self, name: str, timeout: int = 120) -> requests.Response | None:
        """Fetch a cache object, or None on 404."""
        response = self.session.get(f"{self.cache_url}/{name}", timeout=timeout)
        if response.status_code == 404:
            return None
        response.raise_for_status()
        return response

    # -- phase A ----------------------------------------------------------

    def listing(self, path_hash: str) -> Listing | None:
        """The NAR's file tree, or None if the path has not been built and pushed."""
        cached = self.cache_dir / "ls" / f"{path_hash}.json"
        if cached.exists():
            return json.loads(cached.read_text())

        response = self.get(f"{path_hash}.ls")
        if response is None:
            body = b"null"
        else:
            # `.ls` is served with `content-encoding: zstd`, which requests may
            # or may not have decoded depending on the urllib3 build, so key off
            # the magic number rather than the header.
            body = response.content
            if body[:4] == b"\x28\xb5\x2f\xfd":
                body = decompress(body, "zstd")

        cached.write_bytes(body)
        return json.loads(body)

    def indexed_files(self, store_path: str) -> list[str] | None:
        """-> [path within the output], or None if the path is not in the cache."""
        listing = self.listing(store_hash(store_path, self.store_dir))
        if listing is None:
            return None
        found: list[str] = []
        for directory, suffix in SCANNED_DIRS.items():
            node = listing.get("root", {})
            for component in directory.split("/"):
                if node.get("type") != "directory":
                    node = {}
                    break
                node = node.get("entries", {}).get(component, {})
            if node.get("type") != "directory":
                continue
            found += [
                f"{directory}/{name}"
                for name in sorted(node.get("entries", {}))
                if name.endswith(suffix)
            ]
        return found

    def resolve(self, path: str) -> tuple[str, str] | None:
        """-> `(hash, inner path)` of the regular file behind a path, or None.

        Wrapper packages -- `symlinkJoin`, `buildEnv`, the various wrapping
        hooks -- expose `share/applications/*.desktop` as symlinks into the
        wrapped package's output, which the wrapper's own NAR does not contain.
        """
        for _ in range(MAX_SYMLINK_DEPTH):
            if not path.startswith(self.store_dir):
                return None
            head, _, tail = path[len(self.store_dir) :].partition("/")
            components = tail.split("/") if tail else []

            listing = self.listing(head.split("-", 1)[0])
            if listing is None:
                return None

            node = listing.get("root", {})
            walked = self.store_dir + head
            index = 0
            while index < len(components) and node.get("type") == "directory":
                node = node.get("entries", {}).get(components[index])
                if node is None:
                    return None
                walked = f"{walked}/{components[index]}"
                index += 1
                if node.get("type") == "symlink":
                    break

            if node.get("type") == "regular" and index == len(components):
                return (head.split("-", 1)[0], "/" + "/".join(components))
            if node.get("type") != "symlink":
                return None

            # Retry the path by symlink (whether absolute or relative)
            target = node["target"]
            if not target.startswith("/"):
                target = posixpath.join(posixpath.dirname(walked), target)
            path = posixpath.join(posixpath.normpath(target), *components[index:])
        return None

    def icon_paths(self, path_hash: str, icon: str) -> list[str]:
        """Files in one NAR that could supply the icon named `icon`, best first.

        An entry's `Icon` is usually a bare theme name, meaningful only once
        resolved against a real tree; an absolute path is taken as given.
        """
        if icon.startswith("/"):
            if not icon.startswith(self.store_dir) or store_hash(icon, self.store_dir) != path_hash:
                return []
            return [icon[len(self.store_dir) :].partition("/")[2]]

        listing = self.listing(path_hash)
        if listing is None:
            return []
        matches = [
            path
            for path, node in walk_listing(listing.get("root", {}))
            if node.get("type") == "regular"
            and path.endswith(self.icon_extensions)
            and any(path.startswith(f"{directory}/") for directory in ICON_DIRS)
            and path.rsplit("/", 1)[-1].rsplit(".", 1)[0] == icon
        ]
        return sorted(matches, key=icon_rank)

    def store_image(self, image: bytes, extension: str, directory: pathlib.Path) -> str:
        """Write one image under a name taken from its own contents, and name it.

        One image is then one file however many packages ship it, and a name
        changes only when the image does.
        """
        name = hashlib.sha256(image).hexdigest()[:IMAGE_NAME_LENGTH] + extension
        target = directory / name
        if not target.exists():
            # Several workers reach the same image at once, and a consumer reads
            # the file: swap it in whole or not at all.
            handle, partial = tempfile.mkstemp(dir=directory)
            with os.fdopen(handle, "wb") as file:
                file.write(image)
            staged = pathlib.Path(partial)
            # `mkstemp` opens private; these are files to be served.
            staged.chmod(0o644)
            staged.replace(target)
        return name

    # -- phase B ----------------------------------------------------------

    def read_icon(
        self, path_hash: str, icon: str | None, member: Callable[[str], bytes | None]
    ) -> str | None:
        """-> the name of the file written for an entry's icon, or None.

        Only icons in the same NAR as the desktop file are read. That still
        covers wrapper packages, which symlink the entry and its icon out of the
        same wrapped output; an icon genuinely elsewhere would cost a second NAR
        download, and is left to the consumer's theme fallback.
        """
        if not icon or self.icon_dir is None:
            return None
        for inner in self.icon_paths(path_hash, icon):
            data = member(f"/{inner}")
            if data is None:
                continue
            suffix = f".{inner.rsplit('.', 1)[-1]}".lower()
            rendered = render_icon(
                data,
                suffix,
                self.icon_pixel_size,
                self.icon_colors,
                self.icon_svg_max_bytes,
            )
            if rendered is not None:
                image, extension = rendered
                return self.store_image(image, extension, self.icon_dir)
        return None

    def cached(self, known: dict[str, Parsed | None], inner: str) -> bool:
        """Whether a cached file can be served as it stands.

        `--icon-dir` is an output rather than part of the cache, so a run
        pointed at a fresh directory has to read its images again; otherwise the
        index would name files that are not there. Screenshots are not read
        here, so an AppStream file is always served from the cache.
        """
        if inner not in known:
            return False
        parsed = known[inner]
        if parsed is None or self.icon_dir is None or not inner.endswith(".desktop"):
            return True
        icon_file = cast(DesktopEntry, parsed).get("iconFile")
        if not icon_file:
            return True
        return (self.icon_dir / icon_file).exists()

    def fetch_entries(self, path_hash: str, inner_paths: list[str]) -> dict[str, Parsed]:
        """-> {inner path: what it says} for one NAR, icons written out."""
        cached = self.entry_cache / f"{path_hash}.json"
        known: dict[str, Parsed | None] = json.loads(cached.read_text()) if cached.exists() else {}
        wanted = [inner for inner in inner_paths if not self.cached(known, inner)]
        if not wanted:
            return {
                inner: entry for inner in inner_paths if (entry := known.get(inner)) is not None
            }

        narinfo = self.get(f"{path_hash}.narinfo")
        if narinfo is None:
            return {}
        fields = dict(line.partition(": ")[::2] for line in narinfo.text.splitlines())

        nar = self.get(fields["URL"])
        if nar is None:
            return {}

        with tempfile.TemporaryDirectory() as workdir:
            nar_path = pathlib.Path(workdir) / "package.nar"
            nar_path.write_bytes(decompress(nar.content, fields.get("Compression", "xz")))

            def member(inner: str) -> bytes | None:
                extracted = subprocess.run(
                    [*NIX, "nar", "cat", str(nar_path), inner], capture_output=True
                )
                return extracted.stdout if extracted.returncode == 0 else None

            for inner in wanted:
                data = member(inner)
                text = data.decode("utf-8", "replace") if data else None
                parsed: Parsed | None = None
                if text is not None and inner.endswith(".desktop"):
                    entry = parse_desktop_file(text)
                    if entry is not None:
                        entry["iconFile"] = self.read_icon(path_hash, entry["icon"], member)
                    parsed = entry
                elif text is not None:
                    parsed = parse_metainfo(text)
                known[inner] = parsed

        cached.write_text(json.dumps(known))
        return {inner: entry for inner in inner_paths if (entry := known.get(inner)) is not None}

    # -- phase C ----------------------------------------------------------

    def fetch_screenshot(self, url: str) -> ScreenshotFiles | None:
        """-> the files written for one screenshot URL, or None.

        AppStream points at the upstream project's own hosting, which an index
        cannot refer its readers to: the image has to be mirrored. The result is
        cached by URL, so a rerun over a corpus whose images have not moved
        costs no downloads at all.
        """
        if self.screenshot_dir is None:
            return None
        digest = hashlib.sha256(url.encode()).hexdigest()[:IMAGE_NAME_LENGTH]
        record = self.screenshot_cache / f"{digest}.json"
        if record.exists():
            files = json.loads(record.read_text())
            # `--screenshot-dir` is an output, not part of the cache; a run
            # pointed at a fresh directory has to fetch the image again.
            if files is None:
                return None
            name, large = files
            if all((self.screenshot_dir / kept).exists() for kept in files if kept):
                return name, large
        written = self.download_screenshot(url)
        record.write_text(json.dumps(written))
        return written

    def download_screenshot(self, url: str) -> ScreenshotFiles | None:
        """Fetch, re-render and store one screenshot; -> its files, or None.

        One download serves both copies: the thumbnail a result list shows, and
        the larger one a visitor who opens it gets.
        """
        if self.screenshot_dir is None:
            return None
        try:
            response = self.session.get(url, timeout=SCREENSHOT_TIMEOUT, stream=True)
            response.raise_for_status()
            data = b""
            for chunk in response.iter_content(CHUNK_SIZE):
                data += chunk
                if len(data) > self.screenshot_max_bytes:
                    log(f"warning: screenshot over --screenshot-max-bytes: {url}")
                    return None
        except requests.RequestException as error:
            log(f"warning: could not fetch screenshot {url}: {error}")
            return None

        suffix = screenshot_suffix(url, response.headers.get("content-type"))
        if suffix is None:
            return None
        rendered = render_screenshot(
            data, suffix, self.screenshot_pixel_size, self.screenshot_quality
        )
        if rendered is None:
            log(f"warning: could not read screenshot {url}")
            return None
        image, extension = rendered
        name = self.store_image(image, extension, self.screenshot_dir)

        large: str | None = None
        if self.screenshot_large_pixel_size or self.screenshot_large_quality:
            enlarged = render_screenshot(
                data,
                suffix,
                self.screenshot_large_pixel_size,
                self.screenshot_large_quality,
            )
            if enlarged is not None:
                # A source narrower than both widths is kept twice at its own
                # width, once per quality, since neither render may enlarge it.
                # Such an image is small, thus the second copy costs little.
                enlarged_image, enlarged_extension = enlarged
                large = self.store_image(enlarged_image, enlarged_extension, self.screenshot_dir)
        return name, large


def run_pool[Item: Hashable, Result](
    jobs: int, function: Callable[[Item], Result], items: Sequence[Item], label: str
) -> dict[Item, Result]:
    """Map `function` over `items` concurrently, reporting progress."""
    results: dict[Item, Result] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(function, item): item for item in items}
        for done, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            results[futures[future]] = future.result()
            if done % 500 == 0 or done == len(items):
                log(f"  {label} {done}/{len(items)}")
    return results


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Index desktop entries and AppStream data from the binary cache.",
        epilog="Results only cover revisions Hydra has already built; see the module docstring.",
    )
    parser.add_argument("attrs", nargs="*", help="only index these attribute paths (default: all)")
    parser.add_argument(
        "--nixpkgs", help="path to the nixpkgs checkout (default: `$NIXPKGS`, else `NIX_PATH`)"
    )
    parser.add_argument(
        "--eval-systems",
        default=DEFAULT_EVAL_SYSTEMS,
        help="comma-separated systems to enumerate packages for",
    )
    parser.add_argument("--outpaths", help="read `nix-env -qaP --out-path` output from this file")
    parser.add_argument("--output", default="-", help="write the JSON index here (default: stdout)")
    parser.add_argument(
        "--cache-url", default=DEFAULT_CACHE_URL, help="binary cache to read NARs and listings from"
    )
    parser.add_argument(
        "--store-dir", default=DEFAULT_STORE_DIR, help="store directory the output paths live under"
    )
    parser.add_argument(
        "--cache-dir", default=DEFAULT_CACHE_DIR, help="local cache, keyed by store hash"
    )
    parser.add_argument(
        "--icon-dir",
        help="write entry icons here, as files named after their own contents, "
        "which the index then refers to by name; omit to index no images",
    )
    parser.add_argument(
        "--icon-extensions",
        default=",".join(DEFAULT_ICON_EXTENSIONS),
        help="comma-separated icon file extensions to look for",
    )
    parser.add_argument(
        "--icon-pixel-size",
        type=int,
        default=DEFAULT_ICON_PIXEL_SIZE,
        help="re-render raster icons to this many pixels, or 0 to keep their own size",
    )
    parser.add_argument(
        "--icon-colors",
        type=int,
        default=DEFAULT_ICON_COLORS,
        help="quantize raster icons to this many colours, or 0 to leave them alone",
    )
    parser.add_argument(
        "--icon-svg-max-bytes",
        type=int,
        default=DEFAULT_ICON_SVG_MAX_BYTES,
        help="rasterize vector icons larger than this, or 0 to keep every one",
    )
    parser.add_argument(
        "--screenshot-dir",
        help="mirror AppStream screenshots here, as files named after their own "
        "contents, which the index then refers to by name; omit to index no images",
    )
    parser.add_argument(
        "--screenshot-pixel-size",
        type=int,
        default=DEFAULT_SCREENSHOT_PIXEL_SIZE,
        help="re-render screenshots to this many pixels wide, or 0 to mirror them as they are",
    )
    parser.add_argument(
        "--screenshot-quality",
        type=int,
        default=DEFAULT_SCREENSHOT_QUALITY,
        help="re-render screenshots as WebP at this quality, or 0 to mirror them as they are",
    )
    parser.add_argument(
        "--screenshot-large-pixel-size",
        type=int,
        default=DEFAULT_SCREENSHOT_LARGE_PIXEL_SIZE,
        help="also keep a copy of each screenshot this many pixels wide, or 0 to keep none",
    )
    parser.add_argument(
        "--screenshot-large-quality",
        type=int,
        default=DEFAULT_SCREENSHOT_LARGE_QUALITY,
        help="render that larger copy as WebP at this quality",
    )
    parser.add_argument(
        "--screenshots-per-package",
        type=int,
        default=DEFAULT_SCREENSHOTS_PER_PACKAGE,
        help="keep at most this many screenshots per package, or 0 to keep every one",
    )
    parser.add_argument(
        "--screenshot-max-bytes",
        type=int,
        default=DEFAULT_SCREENSHOT_MAX_BYTES,
        help="skip screenshots larger than this",
    )
    parser.add_argument("--jobs", type=int, default=32, help="concurrent requests in phase A")
    parser.add_argument(
        "--nar-jobs", type=int, default=4, help="concurrent NAR downloads in phase B"
    )
    parser.add_argument(
        "--screenshot-jobs", type=int, default=16, help="concurrent downloads in phase C"
    )
    args = parser.parse_args()

    outpaths = read_outpaths(args.outpaths, args.nixpkgs, args.store_dir, args.eval_systems)
    if args.attrs:
        wanted = set(args.attrs)
        # Attribute paths are suffixed with the system, e.g. `vlc.x86_64-linux`.
        outpaths = {
            attr: paths
            for attr, paths in outpaths.items()
            if attr in wanted or attr.rsplit(".", 1)[0] in wanted
        }
        missing = wanted - set(outpaths) - {attr.rsplit(".", 1)[0] for attr in outpaths}
        if missing:
            log(f"warning: not found in outpaths: {', '.join(sorted(missing))}")

    store_paths = sorted({path for paths in outpaths.values() for path in paths})
    log(f"{len(outpaths)} attributes, {len(store_paths)} distinct store paths")

    icon_extensions = tuple(
        f".{extension.strip().lstrip('.').lower()}"
        for extension in args.icon_extensions.split(",")
        if extension.strip()
    )
    scanner = Scanner(
        args.cache_dir,
        args.icon_dir,
        icon_extensions,
        args.icon_pixel_size,
        args.icon_colors,
        args.icon_svg_max_bytes,
        args.screenshot_dir,
        args.screenshot_pixel_size,
        args.screenshot_quality,
        args.screenshot_large_pixel_size,
        args.screenshot_large_quality,
        args.screenshot_max_bytes,
        args.cache_url,
        args.store_dir,
    )

    log("phase A: listing NAR contents ...")
    flagged = run_pool(args.jobs, scanner.indexed_files, store_paths, "listed")

    log("phase A: resolving symlinked files ...")
    targets = [f"{path}/{inner}" for path, inners in flagged.items() for inner in inners or []]
    resolved = run_pool(args.jobs, scanner.resolve, targets, "resolved")

    by_nar: dict[str, set[str]] = {}
    for target in targets:
        location = resolved[target]
        if location is not None:
            by_nar.setdefault(location[0], set()).add(location[1])

    log(f"phase B: fetching {len(by_nar)} NARs holding indexable files ...")
    contents = run_pool(
        args.nar_jobs,
        lambda path_hash: scanner.fetch_entries(path_hash, sorted(by_nar[path_hash])),
        sorted(by_nar),
        "fetched",
    )

    packages: dict[str, Package] = {}
    for attr, paths in outpaths.items():
        entries: list[dict[str, Any]] = []
        # Which file in `--icon-dir` serves each icon name, held per package
        # because its entries commonly share one icon.
        icons: dict[str, str] = {}
        component_ids: list[str] = []
        screenshots: list[Screenshot] = []
        for path in paths:
            for inner in flagged[path] or []:
                location = resolved[f"{path}/{inner}"]
                if location is None:
                    continue
                found = contents.get(location[0], {}).get(location[1])
                if found is None:
                    continue
                if inner.endswith(".desktop"):
                    entry = cast(DesktopEntry, found)
                    icon_file = entry.get("iconFile")
                    icon = entry["icon"]
                    if icon_file is not None and icon is not None:
                        icons[icon] = icon_file
                    # A copy, because several attributes can share one NAR entry.
                    copied = dict(entry)
                    copied.pop("iconFile", None)
                    entries.append(copied)
                    continue
                component = cast(Component, found)
                identifier = component["id"]
                if identifier is not None and identifier not in component_ids:
                    component_ids.append(identifier)
                for shot in component["screenshots"]:
                    # A package that ships both AppStream directories describes
                    # the same images twice.
                    if all(shot["url"] != kept["url"] for kept in screenshots):
                        screenshots.append(shot)
        if args.screenshots_per_package:
            screenshots = screenshots[: args.screenshots_per_package]
        if entries or component_ids or screenshots:
            status = "indexed"
        elif any(flagged[path] is None for path in paths):
            # At least one output is not in the cache
            status = "not-built"
        elif any(flagged[path] for path in paths):
            status = "unresolved"
        else:
            status = "no-entries"
        packages[attr] = {
            "status": status,
            "desktopEntries": entries,
            "icons": icons,
            "componentIds": component_ids,
            "screenshots": screenshots,
        }

    if args.screenshot_dir:
        urls = sorted(
            {shot["url"] for package in packages.values() for shot in package["screenshots"]}
        )
        log(f"phase C: mirroring {len(urls)} screenshots ...")
        mirrored = run_pool(args.screenshot_jobs, scanner.fetch_screenshot, urls, "mirrored")
        for package in packages.values():
            kept: list[Screenshot] = []
            for shot in package["screenshots"]:
                files = mirrored.get(shot["url"])
                if files is None:
                    # An image that cannot be mirrored is dropped: the index
                    # only names screenshots it can serve.
                    continue
                shot["file"], shot["largeFile"] = files
                kept.append(shot)
            package["screenshots"] = kept

    all_entries = [entry for package in packages.values() for entry in package["desktopEntries"]]
    all_shots = [shot for package in packages.values() for shot in package["screenshots"]]
    summary: dict[str, int] = {
        status: sum(1 for package in packages.values() if package["status"] == status)
        for status in ("indexed", "no-entries", "not-built", "unresolved")
    }
    summary["entries"] = len(all_entries)
    summary["named-icons"] = len({entry["icon"] for entry in all_entries if entry["icon"]})
    summary["icons"] = len(
        {file for package in packages.values() for file in package["icons"].values()}
    )
    summary["components"] = len(
        {identifier for package in packages.values() for identifier in package["componentIds"]}
    )
    summary["screenshots"] = len(all_shots)
    summary["screenshot-images"] = len({file for shot in all_shots if (file := shot.get("file"))})
    log(f"summary: {summary}")

    document = json.dumps({"version": "3", "summary": summary, "packages": packages}, indent=2)
    if args.output == "-":
        print(document)
    else:
        pathlib.Path(args.output).write_text(document)


if __name__ == "__main__":
    main()
