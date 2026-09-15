#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages(ps: with ps; [ requests zstandard brotli ])" -p nix imagemagick librsvg
"""Index desktop entries by reading them out of the binary cache.

Get desktop entries and icons for Hydra-cached packages.
This complements `packages.json`, which only has info from `makeDesktopItem`.

It works in two phases:

  A. For each store path, fetch `<hash>.ls` -- a small compressed JSON listing
     of the NAR's file tree -- and look for `share/applications/*.desktop`.
     Cheap: a few KB per package, no NAR download.
  B. Fetch the NAR of these `*.desktop` files and extract them. Write their icons
     to `--icon-dir`, with content hashes for name for deduplication. By not
     using a derivation for this, space may be saved by not having to keep all
     package NARs in-store.

Every package is reported with a `status`, because the ways of finding nothing
are not equivalent and must not be conflated:

  `indexed`     entries were read.
  `no-entries`  built, and it genuinely ships none.
  `not-built`   no `.ls` in the cache. Results exist only for revisions Hydra
                has already built and pushed, so on a fresh revision this is the
                common case; check the summary before treating a run as
                complete.
  `unresolved`  desktop files exist but could not be read, e.g. a symlink whose
                target is not in the cache.

Merging with `packages.json`:

    This index reads what a package ships, including the entries nixpkgs takes
    verbatim from upstream and evaluation therefore cannot see, so it wins
    wherever it found any:

        indexed = json.load(open("desktop-entries.json"))["packages"]
        merged = json.load(open("packages.json"))["packages"]
        for attr, package in merged.items():
            entries = indexed.get(attr, {}).get("desktopEntries")
            package["desktopEntries"] = entries or package.get("desktopEntries", [])

Usage:

    # index everything (long: one request per store path in phase A)
    ./desktop-entries-index.py --icon-dir icons --output desktop-entries.json

    # index just selected attributes
    ./desktop-entries-index.py keepassxc vlc krita

    # trimmed the way a consumer serving icons to browsers wants them: only
    # formats a browser draws, rasters at one size, vectors kept below 16 KB
    ./desktop-entries-index.py --icon-dir icons --icon-extensions png,svg \\
        --icon-pixel-size 64 --icon-colors 256 --icon-svg-max-bytes 16384 \\
        --output desktop-entries.json
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

import requests

# Overridable through `--cache-url` and `--store-dir`, for a private binary
# cache or a Nix installed under another prefix.
DEFAULT_CACHE_URL = "https://cache.nixos.org"

DEFAULT_STORE_DIR = "/nix/store"

APPLICATIONS_DIR = "share/applications"

# Where an icon named by a desktop entry may be found, per the icon theme spec.
ICON_DIRS = ("share/icons", "share/pixmaps")

# The formats the icon theme spec allows, overridable through
# `--icon-extensions`. XPM is in the spec yet no browser reads it, so a consumer
# serving browsers wants `--icon-pixel-size`, which converts rasters to PNG.
DEFAULT_ICON_EXTENSIONS = (".png", ".svg", ".xpm")

# Hex digits of an image's digest naming its file: 128 bits, far past collision
# risk at this scale, and short enough to read.
ICON_NAME_LENGTH = 32

# Nothing is re-rendered unless asked for, since what an icon should be is the
# consumer's business. It does pay where wanted: over the largest icon each of 71
# packages ships, `--icon-pixel-size 64 --icon-colors 256` turns 2.3 MB into 82 KB.
DEFAULT_ICON_PIXEL_SIZE = 0

DEFAULT_ICON_COLORS = 0

# Above this a vector is rasterized anyway, being traced artwork rather than an
# icon. Over 60 upstream scalable icons, gzipped: keeping every one costs 136 KB,
# a 16384 ceiling 96 KB while keeping 87% scalable, rasterizing the lot 73 KB.
DEFAULT_ICON_SVG_MAX_BYTES = 0

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
ENTRY_CACHE = "entries-2"

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


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def store_dir_prefix(store_dir):
    """The store directory as paths under it spell it, i.e. with a trailing slash."""
    return store_dir.rstrip("/") + "/"


def store_hash(store_path, store_dir):
    """<store dir>/<hash>-name[/...] -> <hash>"""
    rest = store_path[len(store_dir_prefix(store_dir)) :]
    return rest.split("/", 1)[0].split("-", 1)[0]


def decompress(data, compression):
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


def split_semicolons(value):
    return [item for item in value.split(";") if item != ""]


def parse_desktop_file(text):
    """Extract the indexable fields of a `.desktop` file's main section.

    Mirrors the schema `pkgs/top-level/desktop-entries.nix` emits. `strict=False`
    tolerates the duplicate keys and repeated sections that occur in the wild.
    Every locale the file carries is kept; trimming them is the consumer's call.
    """
    parser = configparser.ConfigParser(
        strict=False,
        interpolation=None,
        delimiters=("=",),
        comment_prefixes=("#",),
    )
    # Keys are case-sensitive in the desktop entry spec.
    parser.optionxform = str
    try:
        parser.read_string(text)
    except configparser.Error:
        return None
    if not parser.has_section("Desktop Entry"):
        return None
    section = parser["Desktop Entry"]

    localized = {}
    for key in section:
        match = LOCALIZED_KEY.match(key)
        if match is None:
            continue
        field = LOCALIZED_FIELDS[match.group(1)]
        value = section.get(key)
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


def walk_listing(node, prefix=""):
    """Yield `(inner path, node)` for everything below a `.ls` tree node."""
    if node.get("type") != "directory":
        return
    for name, child in node.get("entries", {}).items():
        path = f"{prefix}/{name}" if prefix else name
        yield path, child
        yield from walk_listing(child, path)


def icon_rank(path):
    """Sort key over the files that could supply one icon name, best first.

    A vector wins because it stays one, and among rasters the largest downscales
    best. `-symbolic` icons are monochrome toolbar glyphs, never an
    application's own, so they lose to anything else.
    """
    size = re.search(r"/(\d+)x\1/", path)
    return ("symbolic" in path, not path.endswith(".svg"), -int(size.group(1)) if size else 0)


def render_icon(data, suffix, pixel_size, colors, svg_max_bytes):
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


def find_nixpkgs():
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
    path=None, nixpkgs=None, store_dir=DEFAULT_STORE_DIR, systems=DEFAULT_EVAL_SYSTEMS
):
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
                os.path.join(nixpkgs, "ci/eval/outpaths.nix"),
                "--arg",
                "systems",
                json.dumps([system.strip() for system in systems.split(",") if system.strip()]),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    result = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        paths = []
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
        cache_dir,
        icon_dir=None,
        icon_extensions=DEFAULT_ICON_EXTENSIONS,
        icon_pixel_size=DEFAULT_ICON_PIXEL_SIZE,
        icon_colors=DEFAULT_ICON_COLORS,
        icon_svg_max_bytes=DEFAULT_ICON_SVG_MAX_BYTES,
        cache_url=DEFAULT_CACHE_URL,
        store_dir=DEFAULT_STORE_DIR,
    ):
        self.cache_url = cache_url.rstrip("/")
        self.store_dir = store_dir_prefix(store_dir)
        self.cache_dir = pathlib.Path(cache_dir)
        self.icon_dir = pathlib.Path(icon_dir) if icon_dir else None
        self.icon_extensions = tuple(icon_extensions)
        self.icon_pixel_size = icon_pixel_size
        self.icon_colors = icon_colors
        self.icon_svg_max_bytes = icon_svg_max_bytes
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
        (self.cache_dir / "ls").mkdir(parents=True, exist_ok=True)
        self.entry_cache.mkdir(parents=True, exist_ok=True)
        if self.icon_dir is not None:
            self.icon_dir.mkdir(parents=True, exist_ok=True)
        self.local = threading.local()

    @property
    def session(self):
        # requests.Session is not thread-safe; give each worker its own.
        if not hasattr(self.local, "session"):
            self.local.session = requests.Session()
        return self.local.session

    def get(self, name, timeout=120):
        """Fetch a cache object, or None on 404."""
        response = self.session.get(f"{self.cache_url}/{name}", timeout=timeout)
        if response.status_code == 404:
            return None
        response.raise_for_status()
        return response

    # -- phase A ----------------------------------------------------------

    def listing(self, path_hash):
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

    def desktop_files(self, store_path):
        """-> [`.desktop` name], or None if the path is not in the cache."""
        listing = self.listing(store_hash(store_path, self.store_dir))
        if listing is None:
            return None
        node = listing.get("root", {})
        for component in APPLICATIONS_DIR.split("/"):
            if node.get("type") != "directory":
                return []
            node = node.get("entries", {}).get(component, {})
        if node.get("type") != "directory":
            return []
        return sorted(name for name in node.get("entries", {}) if name.endswith(".desktop"))

    def resolve(self, path):
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

    def icon_paths(self, path_hash, icon):
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

    # -- phase B ----------------------------------------------------------

    def read_icon(self, path_hash, icon, member):
        """-> the name of the file written for an entry's icon, or None.

        Only icons in the same NAR as the desktop file are read. That still
        covers wrapper packages, which symlink the entry and its icon out of the
        same wrapped output; an icon genuinely elsewhere would cost a second NAR
        download, and is left to the consumer's theme fallback.

        The image goes to `--icon-dir` as a file named after its own contents,
        so one image is one file however many packages ship it, and a name
        changes only when the image does.
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
                name = hashlib.sha256(image).hexdigest()[:ICON_NAME_LENGTH] + extension
                target = self.icon_dir / name
                if not target.exists():
                    # Several workers reach the same image at once, and a
                    # consumer reads the file: swap it in whole or not at all.
                    handle, partial = tempfile.mkstemp(dir=self.icon_dir)
                    with os.fdopen(handle, "wb") as file:
                        file.write(image)
                    # `mkstemp` opens private; these are files to be served.
                    os.chmod(partial, 0o644)
                    os.replace(partial, target)
                return name
        return None

    def cached(self, known, inner):
        """Whether a cached entry can be served as it stands.

        `--icon-dir` is an output rather than part of the cache, so a run
        pointed at a fresh directory has to read its images again; otherwise the
        index would name files that are not there.
        """
        if inner not in known:
            return False
        entry = known[inner]
        if entry is None or self.icon_dir is None or not entry.get("iconFile"):
            return True
        return (self.icon_dir / entry["iconFile"]).exists()

    def fetch_entries(self, path_hash, inner_paths):
        """-> {inner path: parsed entry} for one NAR, icons written out."""
        cached = self.entry_cache / f"{path_hash}.json"
        known = json.loads(cached.read_text()) if cached.exists() else {}
        wanted = [inner for inner in inner_paths if not self.cached(known, inner)]
        if not wanted:
            return {inner: known[inner] for inner in inner_paths if known[inner] is not None}

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

            def member(inner):
                extracted = subprocess.run(
                    NIX + ["nar", "cat", str(nar_path), inner], capture_output=True
                )
                return extracted.stdout if extracted.returncode == 0 else None

            for inner in wanted:
                data = member(inner)
                entry = parse_desktop_file(data.decode("utf-8", "replace")) if data else None
                if entry is not None:
                    entry["iconFile"] = self.read_icon(path_hash, entry["icon"], member)
                known[inner] = entry

        cached.write_text(json.dumps(known))
        return {inner: known[inner] for inner in inner_paths if known[inner] is not None}


def run_pool(jobs, function, items, label):
    """Map `function` over `items` concurrently, reporting progress."""
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(function, item): item for item in items}
        for done, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            results[futures[future]] = future.result()
            if done % 500 == 0 or done == len(items):
                log(f"  {label} {done}/{len(items)}")
    return results


def main():
    parser = argparse.ArgumentParser(
        description="Index desktop entries by reading them out of the binary cache.",
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
    parser.add_argument("--jobs", type=int, default=32, help="concurrent requests in phase A")
    parser.add_argument(
        "--nar-jobs", type=int, default=4, help="concurrent NAR downloads in phase B"
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
        args.cache_url,
        args.store_dir,
    )

    log("phase A: listing NAR contents ...")
    flagged = run_pool(args.jobs, scanner.desktop_files, store_paths, "listed")

    log("phase A: resolving symlinked entries ...")
    targets = [
        f"{path}/{APPLICATIONS_DIR}/{name}"
        for path, names in flagged.items()
        for name in names or []
    ]
    resolved = run_pool(args.jobs, scanner.resolve, targets, "resolved")

    by_nar = {}
    for target in targets:
        if resolved[target] is not None:
            by_nar.setdefault(resolved[target][0], set()).add(resolved[target][1])

    log(f"phase B: fetching {len(by_nar)} NARs holding desktop entries ...")
    contents = run_pool(
        args.nar_jobs,
        lambda path_hash: scanner.fetch_entries(path_hash, sorted(by_nar[path_hash])),
        sorted(by_nar),
        "fetched",
    )

    packages = {}
    for attr, paths in outpaths.items():
        entries = []
        # Which file in `--icon-dir` serves each icon name, held per package
        # because its entries commonly share one icon.
        icons = {}
        for path in paths:
            for name in flagged[path] or []:
                location = resolved[f"{path}/{APPLICATIONS_DIR}/{name}"]
                if location is not None:
                    entry = contents.get(location[0], {}).get(location[1])
                    if entry is not None:
                        entry = dict(entry)
                        icon_file = entry.pop("iconFile", None)
                        if icon_file is not None:
                            icons[entry["icon"]] = icon_file
                        entries.append(entry)
        if entries:
            status = "indexed"
        elif any(flagged[path] is None for path in paths):
            # At least one output is not in the cache
            status = "not-built"
        elif any(flagged[path] for path in paths):
            status = "unresolved"
        else:
            status = "no-entries"
        packages[attr] = {"status": status, "desktopEntries": entries, "icons": icons}

    all_entries = [entry for package in packages.values() for entry in package["desktopEntries"]]
    summary = {
        status: sum(1 for package in packages.values() if package["status"] == status)
        for status in ("indexed", "no-entries", "not-built", "unresolved")
    }
    summary["entries"] = len(all_entries)
    summary["named-icons"] = len({entry["icon"] for entry in all_entries if entry["icon"]})
    summary["icons"] = len(
        {file for package in packages.values() for file in package["icons"].values()}
    )
    log(f"summary: {summary}")

    document = json.dumps({"version": "2", "summary": summary, "packages": packages}, indent=2)
    if args.output == "-":
        print(document)
    else:
        pathlib.Path(args.output).write_text(document)


if __name__ == "__main__":
    main()
