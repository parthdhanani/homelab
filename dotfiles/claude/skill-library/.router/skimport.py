import os, sys, json, subprocess, shutil, tempfile, datetime
from pathlib import Path
from urllib.parse import urlparse

# Use absolute paths to avoid ambiguity
LIBRARY = Path.home() / ".claude/skill-library"
ROUTER = LIBRARY / ".router"
SOURCES_JSON = LIBRARY / ".sources.json"
BUILD_SCRIPT = ROUTER / "build-index.sh"

def init_sources():
    if not SOURCES_JSON.exists():
        SOURCES_JSON.parent.mkdir(parents=True, exist_ok=True)
        with open(SOURCES_JSON, 'w') as f:
            json.dump({}, f)

def add_source(name, url, path, type="github_tree"):
    init_sources()
    with open(SOURCES_JSON, 'r') as f:
        data = json.load(f)
    data[name] = {
        "url": url,
        "path": path,
        "type": type,
        "last_updated": datetime.date.today().isoformat()
    }
    with open(SOURCES_JSON, 'w') as f:
        json.dump(data, f, indent=2)

def parse_github_url(url):
    parts = urlparse(url).path.strip('/').split('/')
    if len(parts) < 2: return None, None
    user, repo = parts[0], parts[1]
    repo_url = f"https://github.com/{user}/{repo}"
    
    path = ""
    if "tree" in parts or "blob" in parts:
        idx = parts.index("tree") if "tree" in parts else parts.index("blob")
        path = "/".join(parts[idx+2:])
    
    return repo_url, path

def import_skill(url, custom_name=None):
    repo_url, subpath = parse_github_url(url)
    if not repo_url:
        print(f"Error: Could not parse GitHub URL: {url}")
        return False

    # Issue 6 Guard: Do not allow root-level imports without a specific path
    if not subpath:
        print("Error: No specific skill path provided in URL. Cannot import whole repository.")
        return False

    # Issue 5: Use dynamic temp dir
    tmp_dir_path = tempfile.mkdtemp(prefix="skimport-")
    tmp_dir = Path(tmp_dir_path)
    
    try:
        print(f"Cloning {repo_url}...")
        subprocess.run(["git", "clone", "--depth", "1", repo_url, str(tmp_dir)], check=True, capture_output=True)
        
        src_path = tmp_dir / subpath
        if not src_path.exists():
            print(f"Error: Path {subpath} not found in repository.")
            return False

        # If it's a file, move to parent
        if src_path.is_file() and src_path.suffix == ".md":
            src_path = src_path.parent

        if not (src_path / "SKILL.md").exists():
            print(f"Error: SKILL.md not found in {subpath}. Invalid skill.")
            return False

        skill_name = custom_name or src_path.name
        dest_path = LIBRARY / "custom" / skill_name
        
        if dest_path.exists():
            print(f"Skill {skill_name} already exists. Overwriting...")
            shutil.rmtree(dest_path)
        
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src_path, dest_path)
        
        add_source(skill_name, repo_url, subpath)
        print(f"Successfully imported {skill_name}")

        # Issue 1: Rebuild index after import
        if BUILD_SCRIPT.exists():
            print("Rebuilding skill index...")
            subprocess.run(["bash", str(BUILD_SCRIPT)], check=True)
        
        return True
    finally:
        shutil.rmtree(tmp_dir)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 skimport.py <github_url> [custom_name]")
        sys.exit(1)
    
    import_skill(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
