"""Builds the Greenfields Windows installer: dist/<version>/GreenfieldsSetup.msi

    python tools/build_msi.py                    # the version in Greenfields.toc
    python tools/build_msi.py --zip dist/1.2.1/Greenfields-1.2.1.zip
    python tools/build_msi.py --version 1.2.2    # override (testing upgrades); the TOC is untouched

What it does:
  1. stages the addon exactly as the release zip has it (the same zip_dir() release.py uses, or
     the --zip you give it) and the updater exactly as GreenfieldsUpdater.zip has it (CRLF line
     endings, updater.json pointing at this repo's releases)
  2. runs `dotnet build` on installer/Greenfields.Installer.wixproj. WiX v5 and its extensions
     come from NuGet on the first build; all you need installed is the .NET SDK (6 or newer):
         winget install Microsoft.DotNet.SDK.8
  3. copies the MSI to dist/<version>/GreenfieldsSetup.msi

Build files go in dist/_msi_build/ (gitignored). The installer's art is committed in
installer/art/; repaint it with  python -P tools/make_msi_art.py.
tools/release.py calls build() for every release.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import release  # noqa: E402  (zip_dir, build_updater_zip, check_addon_zip: one packaging truth)

INSTALLER = os.path.join(ROOT, "installer")
PROJECT = os.path.join(INSTALLER, "Greenfields.Installer.wixproj")
BUILD = os.path.join(ROOT, "dist", "_msi_build")
STAGE = os.path.join(BUILD, "stage")
MSI_NAME = "GreenfieldsSetup.msi"
ART = ("crest.ico", "hero_welcome.bmp", "hero_finish.bmp", "hero_oops.bmp",
       "page_setup.bmp", "page_inuse.bmp", "page_progress.bmp", "page_maint.bmp")
# Package.wxs lists the updater files by name (they need a registry key path, being per-user)
UPDATER_FILES = {"GreenfieldsUpdater.ps1", "updater.json", "README.txt", "Update Greenfields.cmd",
                 "Turn On Auto Updates.cmd", "Turn Off Auto Updates.cmd"}
DOTNET_HELP = ("the .NET SDK isn't installed (or `dotnet` isn't on PATH). Install it once with\n"
               "    winget install Microsoft.DotNet.SDK.8\n"
               "then open a new terminal and run this again. WiX itself downloads on the first build.")


class BuildError(Exception):
    pass


def fail(msg):
    raise BuildError(msg)


def read_config_repo():
    try:
        with open(release.CONFIG, encoding="utf-8-sig") as f:
            repo = str(json.load(f).get("repo") or "").strip()
    except (OSError, ValueError):
        return None
    if "OWNER" in repo or not re.match(r"^[\w.-]+/[\w.-]+$", repo):
        return None
    return repo


def extract(zip_path, prefix, dest):
    """Unpacks the entries under prefix/ into dest (zip paths were checked when the zip was made)."""
    names = []
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if not info.filename.startswith(prefix + "/") or info.filename.endswith("/"):
                continue
            rel = info.filename[len(prefix) + 1:]
            if not rel or ".." in rel.split("/") or rel.startswith("/") or ":" in rel:
                fail("odd path in %s: %s" % (os.path.basename(zip_path), info.filename))
            target = os.path.join(dest, *rel.split("/"))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(z.read(info))
            names.append(rel)
    return names


def stage(version, addon_zip=None, updater_zip=None):
    """dist/_msi_build/stage/{addon,updater}: exactly what the release zips hold (the zips
    release.py just made when it passes them, otherwise fresh ones made the same way)."""
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    os.makedirs(STAGE)
    if not addon_zip:
        addon_zip = os.path.join(STAGE, "Greenfields.zip")
        release.zip_dir(release.ADDON, addon_zip, "Greenfields")
    release.check_addon_zip(addon_zip, version)
    addon = extract(addon_zip, "Greenfields", os.path.join(STAGE, "addon"))

    repo = read_config_repo()
    if not updater_zip:
        manifest = ("https://github.com/%s/releases/latest/download/latest.json" % repo) if repo else \
            "https://github.com/OWNER/REPO/releases/latest/download/latest.json"
        updater_zip = os.path.join(STAGE, "GreenfieldsUpdater.zip")
        release.build_updater_zip(updater_zip, manifest)
    updater = set(extract(updater_zip, "GreenfieldsUpdater", os.path.join(STAGE, "updater")))
    if updater != UPDATER_FILES:
        fail("the updater's files changed (%s). List them in installer/Package.wxs (UpdaterFiles) and "
             "in UPDATER_FILES in tools/build_msi.py" % ", ".join(sorted(updater ^ UPDATER_FILES)))
    return len(addon), repo


def find_dotnet():
    exe = shutil.which("dotnet")
    if not exe:
        for p in (os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "dotnet", "dotnet.exe"),):
            if os.path.exists(p):
                exe = p
    if not exe:
        fail(DOTNET_HELP)
    r = subprocess.run([exe, "--list-sdks"], capture_output=True, text=True)
    sdks = [l.split()[0] for l in r.stdout.splitlines() if l.strip()]
    if not any(int(s.split(".")[0]) >= 6 for s in sdks if s[:1].isdigit()):
        fail("found dotnet but no .NET SDK 6 or newer (%s). %s" % (", ".join(sdks) or "none", DOTNET_HELP))
    return exe


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def build(version, out_dir, addon_zip=None, updater_zip=None, verbose=False):
    """Builds the MSI for `version` into out_dir and returns its path (BuildError on failure)."""
    if not release.vkey(version):
        fail("the MSI version must look like 1.2.3 (got %r)" % version)
    missing = [a for a in ART if not os.path.exists(os.path.join(INSTALLER, "art", a))]
    if missing:
        fail("installer/art is missing %s - run:  python -P tools/make_msi_art.py" % ", ".join(missing))
    dotnet = find_dotnet()
    count, repo = stage(version, addon_zip, updater_zip)
    help_url = "https://github.com/%s" % repo if repo else "https://github.com/blazegorex/greenfields-addon"

    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1",
               DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1", MSBUILDDISABLENODEREUSE="1")
    cmd = [dotnet, "build", PROJECT, "-c", "Release", "-nologo", "-v:" + ("normal" if verbose else "minimal"),
           "-p:GfVersion=" + version, "-p:GfStage=" + STAGE + os.sep, "-p:GfHelpUrl=" + help_url]
    print("> dotnet build installer/Greenfields.Installer.wixproj (version %s, %d addon files)" % (version, count))
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
    out = ((r.stdout or "") + (r.stderr or "")).strip().splitlines()
    warnings = [l for l in out if ": warning " in l]
    if r.returncode != 0:
        print("\n".join(out[-60:]))
        fail("the installer didn't build (dotnet build exit %d)" % r.returncode)
    for w in sorted(set(warnings)):
        print("  " + w.strip())

    built = None
    for dirpath, _, files in os.walk(os.path.join(BUILD, "bin", "Greenfields.Installer")):
        if MSI_NAME in files:
            p = os.path.join(dirpath, MSI_NAME)
            if not built or os.path.getmtime(p) > os.path.getmtime(built):
                built = p
    if not built:
        fail("dotnet build finished but no %s turned up under dist/_msi_build/bin" % MSI_NAME)
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, MSI_NAME)
    try:
        shutil.copyfile(built, dest)
    except PermissionError:
        fail("%s is open somewhere (an installer window still running it?). Close that and run this again"
             % os.path.relpath(dest, ROOT))
    print("  %s: %d KB, sha256 %s" % (os.path.relpath(dest, ROOT), os.path.getsize(dest) // 1024, sha256(dest)[:16]))
    return dest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", help="MSI version (default: the TOC version)")
    ap.add_argument("--zip", help="the addon zip to package (default: zip Greenfields/ like release.py)")
    ap.add_argument("--out", help="output folder (default: dist/<version>)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    version = (args.version or release.read_toc_version()).strip().lstrip("vV")
    zip_path = os.path.abspath(args.zip) if args.zip else None
    if args.version and not zip_path:
        # a version other than the TOC's: stage a copy of the addon whose TOC says that version
        zip_path = os.path.join(BUILD, "override", "Greenfields-%s.zip" % version)
        os.makedirs(os.path.dirname(zip_path), exist_ok=True)
        tmp = os.path.join(BUILD, "override", "src")
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
        shutil.copytree(release.ADDON, os.path.join(tmp, "Greenfields"))
        toc = os.path.join(tmp, "Greenfields", "Greenfields.toc")
        text = release.read_text(toc)
        with open(toc, "wb") as f:
            f.write(re.sub(r"(?m)^(##\s*Version:[ \t]*)\S+", lambda m: m.group(1) + version, text).encode("utf-8"))
        release.zip_dir(os.path.join(tmp, "Greenfields"), zip_path, "Greenfields")
    out = os.path.abspath(args.out) if args.out else os.path.join(ROOT, "dist", version)
    try:
        build(version, out, zip_path, verbose=args.verbose)
    except BuildError as e:
        print("MSI BUILD STOPPED: %s" % e)
        sys.exit(1)


if __name__ == "__main__":
    main()
