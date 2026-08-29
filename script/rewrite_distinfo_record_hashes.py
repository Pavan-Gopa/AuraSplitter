#!/usr/bin/env python3
"""Rewrite PEP 376 RECORD hashes after codesign mutates native extensions.

mlx-audio-io verifies `_core*.so` against dist-info RECORD at import. Developer
ID signing (and hardened runtime) changes Mach-O bytes, so a copied wheel's
RECORD no longer matches. This script walks a site-packages tree and updates
sha256/size entries to the files that are actually on disk.
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
from pathlib import Path


def sha256_record_digest(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def rewrite_record_file(record_path: Path) -> int:
    site_packages = record_path.parent.parent
    try:
        raw = record_path.read_text(encoding="utf-8")
    except OSError:
        return 0

    reader = csv.reader(io.StringIO(raw))
    rows: list[list[str]] = []
    updated = 0

    for row in reader:
        if not row:
            rows.append(row)
            continue
        relpath = row[0]
        hash_field = row[1] if len(row) > 1 else ""
        size_field = row[2] if len(row) > 2 else ""

        if not hash_field.lower().startswith("sha256="):
            rows.append(row)
            continue

        target = site_packages / relpath
        if not target.is_file():
            rows.append(row)
            continue

        data = target.read_bytes()
        digest = sha256_record_digest(data)
        size = len(data)
        expected = hash_field.split("=", 1)[1]
        if expected == digest and (not size_field or size_field == str(size)):
            rows.append(row)
            continue

        rows.append([relpath, f"sha256={digest}", str(size)])
        updated += 1

    if updated:
        lines = []
        for row in rows:
            if not row:
                lines.append("")
                continue
            path = row[0]
            hash_field = row[1] if len(row) > 1 else ""
            size_field = row[2] if len(row) > 2 else ""
            if hash_field:
                lines.append(f"{path},{hash_field},{size_field}")
            else:
                lines.append(f"{path},,{size_field}")
        text = "\n".join(lines)
        if raw.endswith("\n"):
            text = text.rstrip("\n") + "\n"
        try:
            record_path.chmod(record_path.stat().st_mode | 0o200)
        except OSError:
            pass
        record_path.write_text(text, encoding="utf-8")
    return updated


def rewrite_site_packages(site_packages: Path) -> int:
    root = Path(site_packages)
    if not root.is_dir():
        raise FileNotFoundError(f"site-packages not found: {root}")
    updated = 0
    for record in sorted(root.glob("*.dist-info/RECORD")):
        updated += rewrite_record_file(record)
    return updated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "site_packages",
        type=Path,
        help="Path to site-packages inside the app bundle",
    )
    args = parser.parse_args(argv)
    updated = rewrite_site_packages(args.site_packages)
    print(f"Updated {updated} RECORD hash(es) under {args.site_packages}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
