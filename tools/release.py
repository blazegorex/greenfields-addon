"""Builds (and optionally publishes) a Greenfields release.

    python tools/release.py 1.0.1                 # version bump + checks + packages in dist/1.0.1
    python tools/release.py --bump patch          # same, next patch version
    python tools/release.py --rebuild             # package the current version again (no bump)
    python tools/release.py 1.0.1 --publish       # ...and publish it as a GitHub release
    python tools/release.py --rebuild --publish   # publish the current version / finish a publish
                                                  # that stopped half way

What it does, in order (any failure stops before anything is published, and a failure before
the release commit puts CHANGELOG.md, the TOC and Data/Changelog.lua back as they were):
  0. --publish: checks the setup first (GITHUB_TOKEN, a git repo on a branch with an 'origin'
     remote, the tag is free, the token can see the repo) so a bad setup changes nothing
  1. moves the "## Unreleased" notes in CHANGELOG.md (plus any --note) under the new version;
     everything else in the file is left exactly as written
  2. regenerates Greenfields/Data/Changelog.lua (the in-game "What's new") from CHANGELOG.md
  3. writes the version into Greenfields/Greenfields.toc (the single source of truth)
  4. runs tools/syntax_check.py and the full headless harness - must be clean
  5. packages dist/<v>/:
       Greenfields-<v>.zip        the addon (one Greenfields/ folder - what addon apps expect)
       GreenfieldsUpdater.zip     the guild's updater, pre-pointed at this repo's releases
       GreenfieldsUpdater.ps1     updater script (lets old updaters refresh themselves)
       latest.json                manifest the updater reads (version, url, sha256, notes)
       release.json               BigWigs-packager metadata so WowUp can track the repo
  6. --publish: commits (everything but build output) + tags + pushes the source, creates the
     GitHub release as a draft, uploads the files (latest.json last) and only then makes it the
     latest release, so updaters never see a half-uploaded one. Needs tools/release_config.json
     {"repo": "owner/name"} and a GITHUB_TOKEN environment variable (a fine-grained token with
     Contents: read/write on that repo).
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "Greenfields")
TOC = os.path.join(ADDON, "Greenfields.toc")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
CHANGELOG_LUA = os.path.join(ADDON, "Data", "Changelog.lua")
UPDATER = os.path.join(ROOT, "updater")
CONFIG = os.path.join(ROOT, "tools", "release_config.json")
VENV_PY = os.path.join(ROOT, "tools", ".venv", "Scripts", "python.exe")
INTERFACE = 16001                  # fallback when the TOC has no ## Interface line
MIN_UPDATER = "1.0.0"              # oldest updater that understands this manifest
API = "https://api.github.com"
UPLOADS = "https://uploads.github.com/"
ZIP_TIME = (2026, 1, 1, 0, 0, 0)   # fixed timestamps: same source -> byte-identical zips

VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
HEADING_RE = re.compile(r"^##[ \t]+\[?([^\]\s]+)\]?(?:[ \t]+[-–—][ \t]+\[?([^\]\s]+)\]?)?")
UNRELEASED_RE = re.compile(r"(?im)^##[ \t]+\[?unreleased\]?[ \t]*\r?$")
NEXT_HEADING_RE = re.compile(r"(?m)^##[ \t]")
DEFAULT_NOTE = "Bug fixes and polish."
CHANGELOG_INTRO = ("# Greenfields changelog\n\n"
                   "Add notes under **Unreleased** as you go; `tools/release.py` moves them under the new version.\n")

# files a release rewrites (and puts back if it stops before the release commit)
RELEASE_FILES = (CHANGELOG, CHANGELOG_LUA, TOC)
# what the release commit takes: everything except build output and local tooling
COMMIT_PATHSPEC = (".", ":(exclude)dist", ":(exclude)tools/.venv", ":(exclude)tools/harness/out",
                   ":(exclude)*__pycache__*")
# never shipped in a zip
JUNK_DIRS = {"__pycache__", "node_modules"}
JUNK_FILES = {"thumbs.db", "desktop.ini"}
JUNK_EXT = (".pyc", ".pyo", ".bak", ".tmp", ".swp", ".orig", ".rej", ".log")
UPDATER_EXT = (".ps1", ".cmd", ".txt", ".md")



def github_token():
    """GITHUB_TOKEN from the environment, else from the user's saved Windows variables
    (HKCU\\Environment), so a token set after this terminal started still works."""
    t = os.environ.get("GITHUB_TOKEN", "").strip()
    if t or os.name != "nt":
        return t
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            v, _ = winreg.QueryValueEx(k, "GITHUB_TOKEN")
            return str(v).strip()
    except OSError:
        return ""

def scrub(text):
    """Error text with credentials removed (tokens in remote URLs, the GITHUB_TOKEN itself)."""
    text = re.sub(r"(?i)(https?://)[^/\s@]+@", r"\1***@", str(text))
    token = github_token()
    if len(token) >= 8:
        text = text.replace(token, "***")
    return text


def die(msg):
    print("RELEASE STOPPED: " + scrub(msg))
    sys.exit(1)


def vkey(v):
    m = VERSION_RE.match(v or "")
    return tuple(int(x) for x in m.groups()) if m else None


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def read_text(path):
    """Exact file text (line endings untouched; a UTF-8 BOM is dropped)."""
    return read_bytes(path).decode("utf-8-sig")


def write_text(path, text):
    """Writes only when the content changes (keeps --rebuild from touching files)."""
    data = text.encode("utf-8")
    if os.path.exists(path) and read_bytes(path) == data:
        return False
    with open(path, "wb") as f:
        f.write(data)
    return True


def read_toc_version():
    for line in read_text(TOC).splitlines():
        m = re.match(r"^##\s*Version:[ \t]*(\S+)", line)
        if m:
            return m.group(1)
    die("no ## Version line in the TOC")


def read_toc_interface():
    m = re.search(r"(?m)^##\s*Interface:[ \t]*(\d+)", read_text(TOC))
    return int(m.group(1)) if m else INTERFACE


def write_toc_version(v):
    src = read_text(TOC)
    new, n = re.subn(r"(?m)^(##\s*Version:[ \t]*)\S+", lambda m: m.group(1) + v, src)
    if n != 1:
        die("couldn't update the TOC version (expected exactly one ## Version line, found %d)" % n)
    write_text(TOC, new)


def updater_version():
    src = read_text(os.path.join(UPDATER, "GreenfieldsUpdater.ps1"))
    m = re.search(r"\$UpdaterVersion\s*=\s*'(\d+\.\d+\.\d+)'", src)
    if not m:
        die("couldn't read $UpdaterVersion = 'x.y.z' from updater/GreenfieldsUpdater.ps1")
    return m.group(1)


# ----------------------------------------------------------------------------- changelog
def parse_changelog(text=None):
    """CHANGELOG.md -> [[version, date, [notes]]], newest first ('Unreleased' included).
    Notes are the bullet points ("- ", "* ", "+ ", nested ones too); an indented line right after
    a bullet continues it. Prose, ### sub-headings and <!-- comments --> aren't notes."""
    if text is None:
        if not os.path.exists(CHANGELOG):
            return []
        text = read_text(CHANGELOG)
    entries, cur, last, in_comment = [], None, None, False
    for line in text.splitlines():
        if in_comment or line.lstrip().startswith("<!--"):
            in_comment = "-->" not in line
            last = None
            continue
        m = HEADING_RE.match(line)
        if m:
            cur = [m.group(1), m.group(2), []]
            entries.append(cur)
            last = None
            continue
        if cur is None:
            continue
        m = re.match(r"^\s*[-*+][ \t]+(.*\S)", line)
        if m:
            cur[2].append(m.group(1))
            last = len(cur[2]) - 1
        elif last is not None and line[:1] in (" ", "\t") and line.strip():
            cur[2][last] += " " + line.strip()
        else:
            last = None
    return entries


def release_changelog(version, date, extra_notes):
    """Moves the Unreleased notes (plus --note extras) under a new "## <version> - <date>"
    heading and leaves an empty Unreleased on top. Nothing else in the file is touched.
    Returns the new version's notes."""
    text = read_text(CHANGELOG) if os.path.exists(CHANGELOG) else CHANGELOG_INTRO
    nl = "\r\n" if "\r\n" in text else "\n"
    m = UNRELEASED_RE.search(text)
    if m:
        head_end = m.end() - (1 if text[m.end() - 1:m.end()] == "\r" else 0)
        nxt = NEXT_HEADING_RE.search(text, m.end())
        end = nxt.start() if nxt else len(text)
        before, body, after = text[:head_end], text[m.end():end], text[end:]
    else:
        nxt = NEXT_HEADING_RE.search(text)
        if nxt:
            before, after = text[:nxt.start()] + "## Unreleased", text[nxt.start():]
        else:
            before, after = text.rstrip() + nl + nl + "## Unreleased", ""
        body = ""
    lines = body.splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    lines += ["- " + n.strip() for n in extra_notes if n.strip()]
    if not parse_changelog("## x\n" + "\n".join(lines))[0][2]:
        print("  (no notes under Unreleased - using \"%s\")" % DEFAULT_NOTE)
        lines.append("- " + DEFAULT_NOTE)
    section = "## %s - %s" % (version, date) + nl + nl + nl.join(lines) + nl
    out = before + nl + nl + section + (nl + after if after else "")
    write_text(CHANGELOG, out)
    return parse_changelog("## x\n" + "\n".join(lines))[0][2]


# typographic punctuation -> what the game fonts certainly have
ASCII_FOR = {"‘": "'", "’": "'", "‚": ",", "“": '"', "”": '"', "–": "-",
             "—": "-", "…": "...", " ": " ", "•": "-", "−": "-", "\t": " "}


def plain(note):
    """A note as plain game text: markdown links/bold/code unwrapped, typographic punctuation made
    ASCII, and anything WoW's fonts can't draw (emoji, CJK, control characters) dropped."""
    s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", note)
    s = re.sub(r"(\*\*|__)(.+?)\1", r"\2", s)
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = "".join(ASCII_FOR.get(ch, ch) for ch in s)
    s = "".join(ch for ch in s if 32 <= ord(ch) < 127 or 0xa1 <= ord(ch) <= 0xff)
    return re.sub(r"\s{2,}", " ", s).strip()


def lua_str(s):
    """A Lua 5.1 string literal. The generated file stays pure ASCII (other bytes become \\ddd),
    and '|' is doubled because WoW reads a single '|' as the start of an escape code."""
    out = []
    for b in s.encode("utf-8"):
        c = chr(b)
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "|":
            out.append("||")
        elif 32 <= b < 127:
            out.append(c)
        else:
            out.append("\\%03d" % b)
    return '"' + "".join(out) + '"'


def write_changelog_lua(entries):
    lines = ["--[[ Greenfields - Data/Changelog.lua",
             "     GENERATED by tools/release.py from CHANGELOG.md - edit CHANGELOG.md, not this file.",
             '     Newest first. Shown in game as "What\'s new" after an update. ]]', "",
             "local _, GF = ...", "", "GF.Changelog = {"]
    versions = sorted((e for e in entries if vkey(e[0])), key=lambda e: vkey(e[0]), reverse=True)
    for v, date, notes in versions[:20]:
        lines.append("    { v = %s, date = %s, notes = {" % (lua_str(v), lua_str(date or "")))
        for n in [p for p in (plain(n) for n in notes) if p][:12]:
            lines.append("        %s," % lua_str(n))
        lines.append("    } },")
    lines.append("}")
    write_text(CHANGELOG_LUA, "\n".join(lines) + "\n")


# ----------------------------------------------------------------------------- checks
def run_checks():
    py = VENV_PY if os.path.exists(VENV_PY) else sys.executable
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    for cmd in ([py, os.path.join(ROOT, "tools", "syntax_check.py")],
                [py, os.path.join(ROOT, "tools", "harness", "run.py"), "--scenario", "all"]):
        print("> " + " ".join(os.path.basename(c) for c in cmd))
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
        out = (r.stdout or "").strip().splitlines()
        print("\n".join(out[-12:] if r.returncode == 0 else out[-60:]))
        if r.returncode != 0:
            print((r.stderr or "")[-2000:])
            die("checks failed - fix them before releasing (or --skip-checks if you really must)")


# ----------------------------------------------------------------------------- packaging
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def shipped(name):
    low = name.lower()
    return not (name.startswith((".", "~")) or name.endswith("~") or low in JUNK_FILES or low.endswith(JUNK_EXT))


def zip_info(arcname):
    info = zipfile.ZipInfo(arcname, date_time=ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3                 # same bytes whichever OS builds it
    info.external_attr = 0o100644 << 16    # a plain rw-r--r-- file
    return info


def zip_dir(src_dir, zip_path, arc_root):
    """Deterministic zip: sorted entries, fixed timestamps, LF kept as authored, no junk."""
    names = []
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, dirnames, filenames in os.walk(src_dir):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in JUNK_DIRS)
            for name in sorted(filenames):
                if not shipped(name):
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, src_dir).replace(os.sep, "/")
                names.append(arc_root + "/" + rel)
                z.writestr(zip_info(names[-1]), read_bytes(full), compresslevel=9)
    return names


def check_addon_zip(zip_path, version):
    """The same rules the updater enforces, so a bad package dies here and not on guildies' PCs."""
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        bad = [n for n in names if not n.startswith("Greenfields/") or "\\" in n or ".." in n.split("/")]
        if bad or len(set(n.lower() for n in names)) != len(names):
            die("the addon zip has odd entries: %s" % ", ".join(bad[:5] or ["duplicate names"]))
        if "Greenfields/Greenfields.toc" not in names:
            die("the addon zip has no Greenfields/Greenfields.toc")
        toc = z.read("Greenfields/Greenfields.toc").decode("utf-8", "replace")
        m = re.search(r"(?m)^##\s*Version:[ \t]*(\S+)", toc)
        if not m or m.group(1) != version:
            die("the zipped TOC says %s, not %s" % (m.group(1) if m else "nothing", version))
    return len(names)


def crlf(data):
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


def build_updater_zip(zip_path, manifest_url):
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(UPDATER)):
            path = os.path.join(UPDATER, name)
            if (name.lower() == "updater.json" or not os.path.isfile(path) or not shipped(name)
                    or not name.lower().endswith(UPDATER_EXT)):
                continue
            data = read_bytes(path)
            if name.lower().endswith((".ps1", ".cmd")):
                try:
                    data.decode("ascii")
                except UnicodeDecodeError:
                    # PowerShell 5.1 reads BOM-less scripts as ANSI and cmd.exe chokes on UTF-8
                    die("updater/%s has non-ASCII characters - keep the updater scripts plain ASCII" % name)
            data = crlf(data)  # Windows tools, Windows line endings
            z.writestr(zip_info("GreenfieldsUpdater/" + name), data, compresslevel=9)
        cfg = json.dumps({"manifestUrl": manifest_url}, indent=2).encode("utf-8")
        z.writestr(zip_info("GreenfieldsUpdater/updater.json"), cfg, compresslevel=9)


def package(version, notes, repo, base_url):
    out = os.path.join(ROOT, "dist", version)
    os.makedirs(out, exist_ok=True)
    addon_zip = os.path.join(out, "Greenfields-%s.zip" % version)
    zip_dir(ADDON, addon_zip, "Greenfields")
    count = check_addon_zip(addon_zip, version)

    if base_url:
        asset_base = base_url.rstrip("/\\") + "/"
        manifest_url = asset_base + "latest.json"
        if not asset_base.lower().startswith("https://"):
            print("  note: the updater only trusts https:// addresses; this build is for local testing "
                  "(run it with -ManifestUrl %s)" % manifest_url)
    elif repo:
        asset_base = "https://github.com/%s/releases/download/v%s/" % (repo, version)
        manifest_url = "https://github.com/%s/releases/latest/download/latest.json" % repo
    else:
        asset_base = ""
        manifest_url = "https://github.com/OWNER/REPO/releases/latest/download/latest.json"

    ps1 = os.path.join(out, "GreenfieldsUpdater.ps1")
    with open(ps1, "wb") as f:
        f.write(crlf(read_bytes(os.path.join(UPDATER, "GreenfieldsUpdater.ps1"))))
    upd_zip = os.path.join(out, "GreenfieldsUpdater.zip")
    build_updater_zip(upd_zip, manifest_url)

    interface = read_toc_interface()
    manifest = {
        "name": "Greenfields",
        "version": version,
        "url": asset_base + os.path.basename(addon_zip),
        "sha256": sha256(addon_zip),
        "size": os.path.getsize(addon_zip),
        "published": datetime.date.today().isoformat(),
        "notes": [p for p in (plain(n) for n in notes) if p],
        "interface": interface,
        "minUpdater": MIN_UPDATER,
        "updater": {"version": updater_version(), "url": asset_base + "GreenfieldsUpdater.ps1", "sha256": sha256(ps1)},
    }
    with open(os.path.join(out, "latest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
    with open(os.path.join(out, "release.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"releases": [{"name": "Greenfields", "version": "v" + version,
                                 "filename": os.path.basename(addon_zip), "nolib": False,
                                 "metadata": [{"flavor": "mainline", "interface": interface}]}]}, f, indent=2)
    print("  %s: %d files" % (os.path.basename(addon_zip), count))
    return out, manifest


# ----------------------------------------------------------------------------- git
def git_try(*args):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")   # fail fast instead of an invisible prompt
    try:
        return subprocess.run(["git"] + list(args), cwd=ROOT, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", env=env)
    except FileNotFoundError:
        die("git isn't installed (or isn't on PATH)")


def git(*args):
    r = git_try(*args)
    if r.returncode != 0:
        die("git %s failed: %s" % (" ".join(args), (r.stderr or r.stdout).strip()))
    return r.stdout.strip()


def unshippable_ignored():
    """Files git ignores that the zips would still ship (the release would differ from the tag)."""
    out = git("status", "--porcelain", "--ignored", "--untracked-files=all", "--", "Greenfields", "updater")
    bad = []
    for line in out.splitlines():
        if not line.startswith("!! "):
            continue
        path = line[3:].strip().strip('"')
        parts = path.rstrip("/").split("/")
        if not any(p.startswith(".") or p in JUNK_DIRS for p in parts) and shipped(parts[-1]):
            bad.append(path)
    return bad


# ----------------------------------------------------------------------------- GitHub
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # never carry the token to another address; a redirect becomes an error


_opener = urllib.request.build_opener(_NoRedirect)
HTTP_HINTS = {401: " (GITHUB_TOKEN was rejected - expired or mistyped?)",
              403: " (the token needs Contents: read/write on this repo, or GitHub is rate limiting)",
              404: " (not found - check the repo name in tools/release_config.json and the token's repo access)"}


def gh_api(method, url, token, body=None, data=None, content_type="application/json"):
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "greenfields-release"}
    if data is not None:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    where = "%s %s" % (method, url.split("?")[0])
    try:
        with _opener.open(req, timeout=120) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read()[:400].decode("utf-8", "replace").strip()
        die("GitHub API %s -> %s%s %s" % (where, e.code, HTTP_HINTS.get(e.code, ""), detail))
    except (urllib.error.URLError, OSError) as e:
        die("couldn't reach GitHub (%s): %s" % (where, getattr(e, "reason", e)))
    try:
        return json.loads(raw.decode("utf-8")) if raw.strip() else {}
    except ValueError:
        die("GitHub API %s returned something that isn't JSON" % where)


def find_release(repo, tag, token):
    """The release for `tag`, drafts included (the tags/<tag> endpoint can't see drafts)."""
    for rel in gh_api("GET", "%s/repos/%s/releases?per_page=100" % (API, repo), token) or []:
        if isinstance(rel, dict) and rel.get("tag_name") == tag:
            return rel
    return None


# ----------------------------------------------------------------------------- publishing
def preflight(version, repo, rebuild):
    """Everything --publish needs, checked before any file changes."""
    token = github_token()
    if not token:
        die("set GITHUB_TOKEN to publish (see docs/RELEASING.md)")
    r = git_try("rev-parse", "--is-inside-work-tree")
    if r.returncode != 0 or r.stdout.strip() != "true":
        die("this folder isn't a git repository yet - see docs/RELEASING.md")
    if git_try("rev-parse", "-q", "--verify", "HEAD").returncode != 0:
        die("the git repo has no commits yet - commit and push the source once first (docs/RELEASING.md)")
    branch = git_try("symbolic-ref", "-q", "--short", "HEAD").stdout.strip()
    if not branch:
        die("git isn't on a branch (detached HEAD) - check out your branch first, e.g. git checkout main")
    if git_try("remote", "get-url", "origin").returncode != 0:
        die("no 'origin' remote - git remote add origin https://github.com/%s.git" % repo)
    tag = "v" + version
    r = git_try("rev-parse", "-q", "--verify", "refs/tags/" + tag)
    local_tag = r.stdout.strip() if r.returncode == 0 else None
    remote = git("ls-remote", "--tags", "origin", "refs/tags/" + tag)   # also proves origin is reachable
    remote_tag = remote.split()[0] if remote else None
    if local_tag or remote_tag:
        if not rebuild:
            die("tag %s already exists. If a release of %s stopped half way, finish it with "
                "--rebuild --publish; otherwise pick a newer version" % (tag, version))
        if local_tag and git("rev-parse", tag + "^{commit}") != git("rev-parse", "HEAD"):
            die("tag %s is on an older commit than HEAD - bump to a new version instead" % tag)
        if remote_tag and remote_tag != local_tag:
            die("origin already has a different %s tag - bump to a new version instead" % tag)
        if git("status", "--porcelain", "--", *COMMIT_PATHSPEC):
            die("files changed since %s was tagged - commit nothing new under an old tag; bump instead" % tag)
    stray = unshippable_ignored()
    if stray:
        die("git ignores files the zip would ship (the release wouldn't match the tag): " + ", ".join(stray[:8]))
    info = gh_api("GET", "%s/repos/%s" % (API, repo), token)
    if (info.get("permissions") or {}).get("push") is False:
        die("the GitHub account behind GITHUB_TOKEN can't push to %s" % repo)
    rel = find_release(repo, tag, token)
    if rel and not rebuild:
        die("GitHub already has a release for %s - use --rebuild --publish to finish it, or bump" % tag)
    return {"token": token, "branch": branch, "tag": tag, "tag_exists": bool(local_tag), "release": rel}


def publish(version, out, notes, repo, st, progress):
    token, tag = st["token"], st["tag"]
    progress["staged"] = True
    # git refuses to "add" paths that are both named and gitignored, so only name the
    # excludes that .gitignore doesn't already cover
    ignored = subprocess.run(["git", "check-ignore", "--no-index"] + [p.split(")", 1)[1] for p in COMMIT_PATHSPEC[1:] if "*" not in p],
                             cwd=ROOT, capture_output=True, text=True).stdout.split()
    spec = [p for p in COMMIT_PATHSPEC if p == "." or ("*" not in p and p.split(")", 1)[1] not in ignored)]
    git("add", "-A", "--", *spec)
    staged = git("diff", "--cached", "--name-only").splitlines()
    if staged and st["tag_exists"]:
        die("rebuilding %s changed %s - that wouldn't match the existing tag; bump to a new version instead"
            % (tag, ", ".join(staged[:5])))
    if staged:
        print("  committing: " + ", ".join(staged[:12]) + (" ..." if len(staged) > 12 else ""))
        git("commit", "-q", "-m", "Release " + tag)
    progress["committed"] = True  # from here on the bumped files are in git and stay as they are
    made_tag = False
    if not st["tag_exists"]:
        git("tag", "-a", tag, "-m", "Greenfields " + version)
        made_tag = True
    r = git_try("push", "origin", "HEAD:refs/heads/" + st["branch"], "refs/tags/" + tag)
    if r.returncode != 0:
        if made_tag:
            git_try("tag", "-d", tag)
        die("git push failed: %s\nNothing was published; the release commit is still here. Sort that out "
            "(often: git pull --rebase), then run:  python tools/release.py --rebuild --publish"
            % (r.stderr or r.stdout).strip())
    print("  pushed %s and %s" % (st["branch"], tag))

    resume = "\nThe tag is pushed; run  python tools/release.py --rebuild --publish  to finish the release."
    try:
        body = "\n".join("- " + n for n in notes) or "- " + DEFAULT_NOTE
        body += ("\n\n**Guildies:** run *Update Greenfields* (or turn on auto updates) and /reload in game."
                 "\n**First time?** Download `GreenfieldsUpdater.zip`, unzip it, double-click *Update Greenfields*.")
        rel = st["release"] or find_release(repo, tag, token)
        if not rel:
            # a draft stays invisible to releases/latest until every file is up
            rel = gh_api("POST", "%s/repos/%s/releases" % (API, repo), token,
                         {"tag_name": tag, "name": "Greenfields " + version, "body": body,
                          "draft": True, "prerelease": False})
        upload = str(rel.get("upload_url", "")).split("{")[0]
        if not upload.startswith(UPLOADS):
            die("GitHub gave an unexpected upload address: %s" % upload)
        existing = {a.get("name"): a.get("id") for a in rel.get("assets") or [] if isinstance(a, dict)}
        names = ["Greenfields-%s.zip" % version, "GreenfieldsUpdater.zip", "GreenfieldsUpdater.ps1",
                 "release.json", "latest.json"]  # latest.json last: updaters only see a complete release
        if "latest.json" in existing:  # a live manifest must never point at files being replaced
            gh_api("DELETE", "%s/repos/%s/releases/assets/%s" % (API, repo, existing.pop("latest.json")), token)
        for name in names:
            if existing.get(name):
                gh_api("DELETE", "%s/repos/%s/releases/assets/%s" % (API, repo, existing[name]), token)
            ctype = {"zip": "application/zip", "json": "application/json"}.get(name.rsplit(".", 1)[-1],
                                                                              "application/octet-stream")
            gh_api("POST", upload + "?name=" + urllib.parse.quote(name), token,
                   data=read_bytes(os.path.join(out, name)), content_type=ctype)
            print("  uploaded " + name)
        rel = gh_api("PATCH", "%s/repos/%s/releases/%s" % (API, repo, rel["id"]), token,
                     {"name": "Greenfields " + version, "body": body, "draft": False, "make_latest": "true"})
    except SystemExit:
        print(resume.strip())
        raise
    print("Published: " + str(rel.get("html_url", "")))


# ----------------------------------------------------------------------------- main
def main():
    try:
        sys.stdout.reconfigure(errors="replace")  # an odd character in output must not kill a release
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version", nargs="?", help="new version, e.g. 1.0.1")
    ap.add_argument("--bump", choices=["patch", "minor", "major"])
    ap.add_argument("--rebuild", action="store_true", help="package the current version without bumping")
    ap.add_argument("--note", action="append", default=[],
                    help="extra release note (repeatable); added to the CHANGELOG Unreleased notes")
    ap.add_argument("--skip-checks", action="store_true")
    ap.add_argument("--publish", action="store_true")
    ap.add_argument("--base-url", help="host the files somewhere other than GitHub (the URL they'll be served from)")
    args = ap.parse_args()

    config = {}
    if os.path.exists(CONFIG):
        try:
            config = json.loads(read_text(CONFIG))
        except ValueError as e:
            die("tools/release_config.json isn't valid JSON: %s" % e)
    repo = str(config.get("repo") or "").strip()
    if repo and ("OWNER" in repo or not re.match(r"^[\w.-]+/[\w.-]+$", repo)):
        repo = None
    if args.publish and not repo:
        die('set the GitHub repo in tools/release_config.json first, e.g. {"repo": "yourname/greenfields-addon"}')
    if args.publish and args.base_url:
        die("--base-url is for hosting elsewhere; --publish always uploads to GitHub - use one or the other")
    if args.rebuild and (args.version or args.bump):
        die("--rebuild packages the current version - leave out the version / --bump")
    if args.version and args.bump:
        die("give a version or --bump, not both")

    current = read_toc_version()
    if args.rebuild:
        version = current
    elif args.bump:
        if not vkey(current):
            die("the TOC version '%s' isn't like 1.2.3 - give the new version explicitly" % current)
        a, b, c = vkey(current)
        version = {"patch": "%d.%d.%d" % (a, b, c + 1), "minor": "%d.%d.0" % (a, b + 1),
                   "major": "%d.0.0" % (a + 1)}[args.bump]
    elif args.version:
        version = args.version.strip().lstrip("vV")
    else:
        die("give a version, --bump or --rebuild")
    if not vkey(version):
        die("version must look like 1.2.3 (got '%s')" % version)
    if not args.rebuild and vkey(current) and vkey(version) <= vkey(current):
        die("%s isn't newer than the current %s" % (version, current))

    entries = parse_changelog()
    if not args.rebuild and any(e[0] == version for e in entries):
        die("CHANGELOG.md already has a %s section - pick another version or remove it" % version)
    state = preflight(version, repo, args.rebuild) if args.publish else None

    snapshot = {p: (read_bytes(p) if os.path.exists(p) else None) for p in RELEASE_FILES}
    progress = {"staged": False, "committed": False}
    try:
        if args.rebuild:
            notes = next((e[2] for e in entries if e[0] == version), None) or list(args.note)
        else:
            notes = release_changelog(version, datetime.date.today().isoformat(), args.note)
            entries = parse_changelog()
        write_changelog_lua(entries)
        write_toc_version(version)
        print("Greenfields %s -> %s" % (current, version))

        if not args.skip_checks:
            run_checks()
        out, manifest = package(version, notes, repo, args.base_url)
        print("Packaged in %s (addon sha256 %s)" % (out, manifest["sha256"][:16]))
        if args.publish:
            publish(version, out, notes, repo, state, progress)
        else:
            print("Not published (add --publish when the repo is set up).")
    except BaseException:
        if not progress["committed"]:
            for path, data in snapshot.items():
                exists = os.path.exists(path)
                if data is None:
                    if exists:
                        os.remove(path)
                elif not exists or read_bytes(path) != data:
                    with open(path, "wb") as f:
                        f.write(data)
            if progress["staged"]:
                git_try("reset", "-q", "--", *[os.path.relpath(p, ROOT).replace(os.sep, "/") for p in RELEASE_FILES])
            print("(CHANGELOG.md, the TOC and Data/Changelog.lua are back as they were.)")
        raise


if __name__ == "__main__":
    main()
