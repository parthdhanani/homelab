#!/usr/bin/env python3
"""
sync.py — Update externally-registered skills from .sources.json
Called by build-index.sh --update when .sources.json exists.

Usage: python3 sync.py <sources_json_path> <library_path>
"""
import os, sys, json, subprocess, shutil, tempfile, datetime
from pathlib import Path


def update_source(name, entry, library: Path) -> bool:
    """Pull latest version of a skill from its registered source."""
    url = entry.get("url") or entry.get("repo")
    path = entry.get("path") or entry.get("skills_path", "")
    prefix = entry.get("prefix", "")

    if not url:
        print(f"  ⚠ {name}: no URL, skipping")
        return False

    tmp_dir = Path(tempfile.mkdtemp(prefix=f"sync-{name}-"))
    try:
        print(f"  Syncing {name} from {url}...")
        result = subprocess.run(
            ["git", "clone", "--depth", "1", url, str(tmp_dir)],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  ⚠ {name}: clone failed — {result.stderr.strip()}")
            return False

        src = tmp_dir / path if path else tmp_dir

        if not src.exists():
            print(f"  ⚠ {name}: path '{path}' not found in repo")
            return False

        # If source path points directly to a skill dir (has SKILL.md)
        if (src / "SKILL.md").exists():
            dest = library / "custom" / (prefix + name)
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(src, dest)
            print(f"  ✓ {name} → custom/{prefix + name}")
            return True

        # If source path is a directory of skills (multiple SKILL.md subdirs)
        updated = 0
        for item in src.iterdir():
            if item.is_dir() and (item / "SKILL.md").exists():
                dest = library / "custom" / (prefix + item.name)
                if dest.exists():
                    shutil.rmtree(dest)
                shutil.copytree(item, dest)
                updated += 1
        if updated:
            print(f"  ✓ {name}: {updated} skill(s) updated")
            return True

        print(f"  ⚠ {name}: no SKILL.md found at '{path}'")
        return False

    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 sync.py <sources_json> <library_path>")
        sys.exit(1)

    sources_path = Path(sys.argv[1])
    library = Path(sys.argv[2])

    if not sources_path.exists():
        print(f"No sources file found at {sources_path}, nothing to sync.")
        sys.exit(0)

    with open(sources_path) as f:
        sources = json.load(f)

    if not sources:
        print("No external sources registered.")
        sys.exit(0)

    print(f"Syncing {len(sources)} external source(s)...")
    success, failed = 0, 0
    for name, entry in sources.items():
        if update_source(name, entry, library):
            success += 1
            # Update last_updated timestamp
            entry["last_updated"] = datetime.date.today().isoformat()
        else:
            failed += 1

    # Write back updated timestamps
    with open(sources_path, "w") as f:
        json.dump(sources, f, indent=2)

    print(f"\nSync complete: {success} updated, {failed} failed.")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
