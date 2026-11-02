#!/usr/bin/env python3
"""Shrink oversized manga images by re-encoding them as lossy WebP.

Strategy:
  - Only touches --formats files (default: png only, since PNG sources
    are lossless and re-encoding them is visually free) above --min-size
    (default 1 MB).
  - Re-encodes with cwebp at -q 90 -sharp_yuv (visually lossless for
    manga line art and screentones; verified by eye on library samples).
  - Keeps the ICC color profile so color pages don't shift.
  - Never downscales — pixel dimensions are preserved.
  - Only replaces the original when the WebP is at least --min-saving
    percent smaller (default 20%); otherwise the original is kept.
  - Originals are moved into a hidden backup folder inside the library
    (invisible to Manga-reader, same volume so the move is instant).
    Delete that folder once you've verified everything looks right.
  - Bookmarks/progress in Manga-reader are stored as page indices, and
    foo.png -> foo.webp keeps the same sort position, so nothing breaks.

Usage:
  ./shrink_manga.py ~/Manga --dry-run          # report what would happen
  ./shrink_manga.py ~/Manga --sample 20        # convert 20 files as a trial
  ./shrink_manga.py ~/Manga                    # full run
  ./shrink_manga.py ~/Manga --min-size 0.5     # more aggressive sweep
"""

import argparse
import concurrent.futures
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BACKUP_DIRNAME = ".shrink_originals"
SKIPLIST_NAME = ".shrink_skiplist"


def load_skiplist(root: Path):
    """Files previously evaluated and kept (not worth converting / failed),
    as {relpath: size}. Re-evaluated if the file's size changes."""
    skip = {}
    try:
        for line in (root / SKIPLIST_NAME).read_text().splitlines():
            size, _, rel = line.partition("\t")
            if rel:
                skip[rel] = int(size)
    except (OSError, ValueError):
        pass
    return skip


def save_skiplist(root: Path, skip: dict):
    lines = [f"{size}\t{rel}" for rel, size in sorted(skip.items())]
    (root / SKIPLIST_NAME).write_text("\n".join(lines) + "\n")


def image_dims(path: Path):
    """Width/height from JPEG or PNG headers without decoding. (None, None)
    if the header can't be parsed."""
    import struct
    try:
        with open(path, "rb") as f:
            data = f.read(200000)
    except OSError:
        return None, None
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        w, h = struct.unpack(">II", data[16:24])
        return w, h
    if data[:2] == b"\xff\xd8":
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seglen = struct.unpack(">H", data[i + 2:i + 4])[0]
            i += 2 + seglen
    return None, None


def find_candidates(root: Path, min_bytes: int, exts: set,
                    min_bpp: float = 0, min_mpx: float = 0):
    need_dims = min_bpp > 0 or min_mpx > 0
    for dirpath, dirnames, filenames in os.walk(root):
        # never descend into our own backup folder
        dirnames[:] = [d for d in dirnames if d != BACKUP_DIRNAME]
        for name in filenames:
            if Path(name).suffix.lower() in exts:
                p = Path(dirpath) / name
                try:
                    size = p.stat().st_size
                except OSError:
                    continue
                if size < min_bytes:
                    continue
                if need_dims:
                    w, h = image_dims(p)
                    if not w:
                        continue
                    if min_bpp and size / (w * h) < min_bpp:
                        continue
                    if min_mpx and w * h < min_mpx * 1e6:
                        continue
                yield p, size


def convert_one(src: Path, size: int, root: Path, quality: int,
                min_saving: float, dry_run: bool, max_height: int = 0):
    """Returns (status, src, old_size, new_size)."""
    dst = src.with_suffix(".webp")
    if dst.exists():
        return ("skip_exists", src, size, 0)

    resize = []
    if max_height:
        _, h = image_dims(src)
        if h and h > max_height:
            resize = ["-resize", "0", str(max_height)]

    fd, tmp = tempfile.mkstemp(suffix=".webp", dir=str(src.parent),
                               prefix=".tmp_shrink_")
    os.close(fd)
    tmp = Path(tmp)
    try:
        result = subprocess.run(
            ["cwebp", "-quiet", "-q", str(quality), "-sharp_yuv", "-m", "6",
             "-metadata", "icc", *resize, str(src), "-o", str(tmp)],
            capture_output=True, text=True)
        if result.returncode != 0 or not tmp.exists() or tmp.stat().st_size < 1024:
            return ("encode_failed", src, size, 0)

        new_size = tmp.stat().st_size
        if new_size > size * (1 - min_saving):
            return ("not_worth_it", src, size, new_size)

        if dry_run:
            return ("would_convert", src, size, new_size)

        # move original into the hidden backup mirror, then rename webp in
        backup = root / BACKUP_DIRNAME / src.relative_to(root)
        backup.parent.mkdir(parents=True, exist_ok=True)
        src.rename(backup)
        tmp.rename(dst)
        tmp = None
        return ("converted", src, size, new_size)
    finally:
        if tmp is not None and tmp.exists():
            tmp.unlink()


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", type=Path, help="library root, e.g. ~/Manga")
    ap.add_argument("--min-size", type=float, default=1.0,
                    help="only process images at least this many MB (default 1.0)")
    ap.add_argument("--formats", default="png",
                    help="comma-separated extensions to process (default: png; "
                         "PNG->WebP is lossless-source so visually free)")
    ap.add_argument("--quality", type=int, default=90,
                    help="WebP quality (default 90)")
    ap.add_argument("--min-saving", type=float, default=20,
                    help="replace only if at least this %% smaller (default 20)")
    ap.add_argument("--min-bpp", type=float, default=0,
                    help="only process files above this bytes-per-pixel "
                         "(0 = no filter); catches wasteful encodes while "
                         "sparing efficiently-encoded spreads")
    ap.add_argument("--min-megapixels", type=float, default=0,
                    help="only process files with at least this many "
                         "megapixels (0 = no filter)")
    ap.add_argument("--max-height", type=int, default=0,
                    help="downscale to this pixel height if taller "
                         "(0 = never resize)")
    ap.add_argument("--sample", type=int, default=0,
                    help="only process the first N candidates (trial run)")
    ap.add_argument("--dry-run", action="store_true",
                    help="encode + measure but change nothing")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    root = args.root.expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"not a directory: {root}")
    min_bytes = int(args.min_size * 1024 * 1024)
    min_saving = args.min_saving / 100
    exts = {"." + e.strip().lstrip(".").lower()
            for e in args.formats.split(",") if e.strip()}

    skiplist = load_skiplist(root)
    candidates = sorted(
        ((p, s) for p, s in find_candidates(root, min_bytes, exts,
                                            args.min_bpp, args.min_megapixels)
         if skiplist.get(str(p.relative_to(root))) != s),
        key=lambda t: -t[1])  # biggest first
    if args.sample:
        candidates = candidates[:args.sample]
    total_in = sum(s for _, s in candidates)
    print(f"{len(candidates)} candidates >= {args.min_size} MB "
          f"({human(total_in)} total){' [DRY RUN]' if args.dry_run else ''}")

    stats = {}
    saved = 0
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futures = [ex.submit(convert_one, p, s, root, args.quality,
                             min_saving, args.dry_run, args.max_height)
                   for p, s in candidates]
        for fut in concurrent.futures.as_completed(futures):
            status, src, old, new = fut.result()
            stats[status] = stats.get(status, 0) + 1
            if status in ("converted", "would_convert"):
                saved += old - new
            elif status in ("not_worth_it", "encode_failed") and not args.dry_run:
                # remember the verdict so weekly reruns don't re-encode
                # (or re-download, for cloud libraries) the same files
                skiplist[str(src.relative_to(root))] = old
            done += 1
            if done % 100 == 0 or done == len(futures):
                print(f"  {done}/{len(futures)} processed, "
                      f"saved so far: {human(saved)}", flush=True)
            if status == "encode_failed":
                print(f"  !! encode failed: {src}", file=sys.stderr)

    if not args.dry_run and skiplist:
        save_skiplist(root, skiplist)

    print("\nresults:")
    for k, v in sorted(stats.items()):
        print(f"  {k}: {v}")
    print(f"total space {'that would be ' if args.dry_run else ''}saved: {human(saved)}")
    if not args.dry_run and stats.get("converted"):
        print(f"\noriginals kept in {root / BACKUP_DIRNAME}")
        print("verify a few series in Manga-reader, then reclaim the space with:")
        print(f"  rm -rf '{root / BACKUP_DIRNAME}'")


if __name__ == "__main__":
    main()
