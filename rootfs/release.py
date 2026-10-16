"""Run by build-rootfs.yml: what a release ships of each part of the rootfs (see config.yaml).

  release.py sizes <stage dir> <archives dir> <manifests dir>
      After an ABI's parts are compressed: prints, per part, its size unpacked and as an archive
      and what it holds (components-<part>.txt from build.sh), as JSON.

  release.py merge <tag> <config.json> <current dir> <manifests dir> <previous dir> <out dir>
      Each part gets a fingerprint: what goes into it (its merged manifest, its config entry and
      script, the settings and build scripts every part shares). A part whose fingerprint the
      previous release has keeps that release's archives and version, byte for byte: the app (and
      Play) only updates the parts that changed. The others get <tag> as their version and this
      build's archives.
      <config.json>: config.yaml as JSON (its abis and packages). <current dir>: <arch>/<lib> and
      sizes-<arch>.json of this build (arch: the abi's termux name). <previous dir>: the previous
      release's parts.json and its archives in <abi>/<lib> (both may be missing: then all is new).
      Writes <out dir>/<abi>/<lib>, <out dir>/parts.json (the release's, also shipped to the app)
      and <out dir>/changed.txt (the parts with a new version, one per line).
"""
import hashlib
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# What every part is built with (not this script: it only picks what ships)
SHARED_SCRIPTS = ["build.sh", "parts.py", "pip-files.py", "libandroid-utimes.sh"]


def lib_of(part):
    return "librootfs.tar.xz.so" if part == "base" else f"libpackage-{part}.tar.xz.so"


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def unpacked_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            full = os.path.join(root, name)
            if not os.path.islink(full):
                total += os.path.getsize(full)
    return total


def sizes(stage, archives, manifests):
    out = {}
    for part in sorted(os.listdir(stage)):
        if not os.path.isdir(os.path.join(stage, part)):
            continue
        out[part] = {
            "size": unpacked_size(os.path.join(stage, part)),
            "archive": os.path.getsize(os.path.join(archives, lib_of(part))),
            "components": read_lines(os.path.join(manifests, f"components-{part}.txt")),
        }
    print(json.dumps(out, indent=2))


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def fingerprint(part, config, manifest):
    """What decides a part's files: same fingerprint, same archive."""
    h = hashlib.sha256()
    entry = config.get("base") if part == "base" else (config.get("extensions") or {}).get(part)
    shared = {k: v for k, v in config.items() if k not in ("base", "extensions")}
    h.update(json.dumps({"part": part, "entry": entry or {}, "shared": shared}, sort_keys=True).encode())
    h.update(b"\0manifest\0" + manifest.encode())
    for script in SHARED_SCRIPTS + ([entry["script"]] if entry and entry.get("script") else []):
        h.update(f"\0{script}\0".encode() + read_file(os.path.join(HERE, script)))
    return h.hexdigest()


def merge(tag, config_path, current, manifests, previous, out):
    with open(config_path, encoding="utf-8") as f:
        full = json.load(f)
    config = full["packages"]
    # The build's (termux) arch -> Android ABI (jniLibs folder)
    abis = {v["termux"]: abi for abi, v in full["abis"].items()}
    extensions = config.get("extensions") or {}
    parts = ["base"] + list(extensions)

    built = {}
    for arch in abis:
        with open(os.path.join(current, f"sizes-{arch}.json"), encoding="utf-8") as f:
            built[arch] = json.load(f)

    prev_index = {}
    prev_path = os.path.join(previous, "parts.json") if previous else ""
    if prev_path and os.path.exists(prev_path):
        with open(prev_path, encoding="utf-8") as f:
            prev_index = json.load(f).get("parts", {})

    index = {}
    changed = []
    for part in parts:
        manifest = "\n".join(read_lines(os.path.join(manifests, f"manifest-{part}.txt")))
        fp = fingerprint(part, config, manifest)
        lib = lib_of(part)
        prev = prev_index.get(part)
        reuse = (
            prev is not None
            and prev.get("hash") == fp
            and set(prev.get("abis", {})) == set(abis.values())
            and all(os.path.exists(os.path.join(previous, abi, lib)) for abi in abis.values())
        )
        for arch, abi in abis.items():
            os.makedirs(os.path.join(out, abi), exist_ok=True)
            source = os.path.join(previous, abi, lib) if reuse else os.path.join(current, arch, lib)
            shutil.copyfile(source, os.path.join(out, abi, lib))
        if reuse:
            entry = dict(prev)
            print(f"{part}: unchanged, keeps {prev['version']}")
        else:
            entry = {
                "version": tag,
                "hash": fp,
                "abis": {abi: built[arch][part] for arch, abi in abis.items()},
            }
            changed.append(part)
            print(f"{part}: {prev['version'] if prev else 'new'} -> {tag}")
        # What it builds on is the config's, always (it's no archive's)
        entry["requires"] = [] if part == "base" else (extensions[part] or {}).get("requires") or []
        entry["lib"] = lib
        index[part] = entry

    with open(os.path.join(out, "parts.json"), "w", encoding="utf-8") as f:
        json.dump({"release": tag, "parts": index}, f, indent=2)
        f.write("\n")
    with open(os.path.join(out, "changed.txt"), "w", encoding="utf-8") as f:
        f.write("".join(f"{p}\n" for p in changed))


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"sizes": sizes, "merge": merge}[command](*args)
