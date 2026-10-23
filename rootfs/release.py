"""Run by build.yml: what a release ships of each part of the rootfs (see config.yaml).

  release.py sizes <stage dir> <archives dir> <manifests dir>
      After an ABI's parts are compressed: prints, per part, its size unpacked and as an archive
      and what it holds (components-<part>.txt from build.sh), as JSON.

  release.py merge <tag> <config.json> <current dir> <manifests dir> <previous dir> <out dir> <proot dir> <proot.json>
      Each part gets a fingerprint: what goes into it (its merged manifest, its config entry and
      script, the settings and build scripts every part shares). A part whose fingerprint the
      previous release has, or whose files came out the same as there for every ABI (e.g. the
      build scripts changed, but not what it gets), keeps that release's archives and version,
      byte for byte: the app (and Play) only updates the parts that changed. The others get <tag>
      as their version and this build's archives. Packed differently than there (pack.sh), a part
      with the same files keeps its version (the app has nothing to unpack again) but gets this
      build's archives.
      PRoot ships with the core (the app's core module), so it's part of the core's fingerprint: a
      new PRoot or talloc version (or NDK, or build script or patch) is a new core version, with this
      build's PRoot; a core keeping its version keeps the previous release's PRoot too.
      A part built for some ABIs only (its abis in config.yaml) is in those alone, and in their
      libparts.json.so alone.
      <config.json>: config.yaml as JSON (its abis and packages). <current dir>: <arch>/<lib> and
      sizes-<arch>.json of this build (arch: the abi's termux name). <previous dir>: the previous
      release's parts.json and its archives in <abi>/<lib> (both may be missing: then all is new).
      <proot dir>: this build's PRoot, <abi>/lib*.so (build-proot.yml). <proot.json>: what it was
      built of, {"ref", "talloc", "ndk"}.
      Writes <out dir>/<abi>/<lib>, <out dir>/parts.json (the release's, for the next one),
      <out dir>/<abi>/libparts.json.so (the app's: that ABI's alone, without the hashes) and
      <out dir>/changed.txt (the parts with a new version, one per line).
"""
import hashlib
import json
import os
import shutil
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
# What every part is built with (not this script: it only picks what ships)
SHARED_SCRIPTS = ["build.sh", "parts.py", "pip-files.py", "rebuild-16k.sh", "termux-build.sh"]
# How PRoot is built (proot/): its scripts and patches
PROOT_SRC = os.path.join(HERE, "..", "proot")


def lib_of(part):
    return f"libpackage-{part}.tar.xz.so"


# What the app knows of the parts (parts.json, one ABI's), in each ABI's folder with the archives
PARTS_LIB = "libparts.json.so"


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


def proot_of(info_path):
    """What PRoot is built of: its and talloc's versions, the NDK, and its build scripts and patches."""
    with open(info_path, encoding="utf-8") as f:
        info = json.load(f)
    h = hashlib.sha256()
    patches = sorted(p for p in os.listdir(os.path.join(PROOT_SRC, "patches")) if p.endswith(".patch"))
    for name in ["build.sh", "ndk-setup.sh"] + [f"patches/{p}" for p in patches]:
        h.update(f"\0{name}\0".encode() + read_file(os.path.join(PROOT_SRC, name)))
    return {"ref": info["ref"], "talloc": info["talloc"], "ndk": info["ndk"], "build": h.hexdigest()}


def proot_libs(proot_dir, abi):
    """PRoot and its loaders as built for an ABI (libproot.so, libproot-loader*.so)."""
    return sorted(n for n in os.listdir(os.path.join(proot_dir, abi)) if n.startswith("lib") and n.endswith(".so"))


def sources(config):
    """The parts' sources built here, not Termux's packages (a part's source: its config section, rootfs/<source>/)."""
    return {e["source"] for e in (config.get("packages") or {}).values() if e and e.get("source")}


def fingerprint(part, config, manifest, proot=None):
    """What decides a part's files: same fingerprint, same archive (the core's: and PRoot)."""
    h = hashlib.sha256()
    entry = (config.get("packages") or {}).get(part)
    source = entry.get("source") if entry else None
    # What every part is built with (build_packages; not the ABIs, nothing of a part, nor PRoot's
    # settings: "latest" says nothing, the core gets what PRoot was built of; nor what a part built
    # here is built of, which is its own)
    shared = {k: v for k, v in config.items() if k not in ("packages", "abis", "proot") and k not in sources(config)}
    h.update(json.dumps({"part": part, "entry": entry or {}, "shared": shared}, sort_keys=True).encode())
    h.update(b"\0manifest\0" + manifest.encode())
    if proot:
        h.update(b"\0proot\0" + json.dumps(proot, sort_keys=True).encode())
    if source:
        # Built here: of its config section and its build's files, not Termux's build scripts
        h.update(b"\0source\0" + json.dumps(config.get(source), sort_keys=True).encode())
        folder = os.path.join(HERE, source)
        files = sorted(os.path.relpath(os.path.join(root, n), folder).replace(os.sep, "/")
                       for root, _, names in os.walk(folder) for n in names)
        for name in files:
            h.update(f"\0{source}/{name}\0".encode() + read_file(os.path.join(folder, name)))
        return h.hexdigest()
    for script in SHARED_SCRIPTS + ([entry["script"]] if entry and entry.get("script") else []):
        h.update(f"\0{script}\0".encode() + read_file(os.path.join(HERE, script)))
    return h.hexdigest()


def packing():
    """How the archives are made of a part's files (not what's in them): a change repacks every part."""
    return hashlib.sha256(read_file(os.path.join(HERE, "pack.sh"))).hexdigest()


# Differs in every release's core, the rest being the same (see build.sh)
OWN_VERSION = {"core": {"etc/image-version"}}


def content(archive, part):
    """What an archive unpacks to: its files, links and folders with their modes (not their times)."""
    # Read once, front to back (a stream: going back in xz decompresses again from the start), each
    # member hashed as it comes; in name order after, as the archive's order isn't the files'
    members = {}
    with tarfile.open(archive, "r|xz") as tar:
        for m in tar:
            name = m.name.removeprefix("./")
            if name in OWN_VERSION.get(part, ()):
                continue
            h = hashlib.sha256(f"\0{name}\0{m.type!r}\0{m.mode:o}\0{m.linkname}\0".encode())
            if m.isfile():
                f = tar.extractfile(m)
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            members[name] = h.digest()
    h = hashlib.sha256()
    for name in sorted(members):
        h.update(members[name])
    return h.hexdigest()


def merge(tag, config_path, current, manifests, previous, out, proot_dir, proot_info):
    with open(config_path, encoding="utf-8") as f:
        full = json.load(f)
    config = full
    # The build's (termux) arch -> Android ABI (jniLibs folder)
    abis = {v["termux"]: abi for abi, v in full["abis"].items()}
    extensions = {name: part for name, part in (config.get("packages") or {}).items() if name != "core"}
    parts = ["core"] + list(extensions)

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
    packed = packing()
    proot = proot_of(proot_info)
    for part in parts:
        # The ABIs it's built for (its abis, else all), the build's arch -> ABI
        only = (extensions.get(part) or {}).get("abis")
        part_abis = {arch: abi for arch, abi in abis.items() if not only or abi in only}
        manifest = "\n".join(read_lines(os.path.join(manifests, f"manifest-{part}.txt")))
        # PRoot ships with the core: a new one is a new core
        own_proot = proot if part == "core" else None
        fp = fingerprint(part, config, manifest, own_proot)
        lib = lib_of(part)
        # What ships with it in each ABI's folder (the core: PRoot), kept along with it or not
        extras = {abi: proot_libs(proot_dir, abi) if own_proot else [] for abi in part_abis.values()}
        prev = prev_index.get(part)
        complete = (
            prev is not None
            and set(prev.get("abis", {})) == set(part_abis.values())
            and all(os.path.exists(os.path.join(previous, abi, name))
                    for abi in part_abis.values() for name in [lib] + extras[abi])
            # Built with the same PRoot (earlier releases don't say: the core is new)
            and prev.get("proot") == own_proot
        )
        same_input = complete and prev.get("hash") == fp
        # Earlier releases have no packing: all were packed otherwise
        same_packing = complete and prev.get("packing") == packed
        # Repacked, the same input isn't enough: the archive shipped is this build's, so its files are compared
        same_files = complete and not (same_input and same_packing) and all(
            content(os.path.join(previous, abi, lib), part) == content(os.path.join(current, arch, lib), part)
            for arch, abi in part_abis.items()
        )
        reuse = same_packing and (same_input or same_files)
        repacked = not reuse and same_files
        for arch, abi in part_abis.items():
            os.makedirs(os.path.join(out, abi), exist_ok=True)
            source = os.path.join(previous, abi, lib) if reuse else os.path.join(current, arch, lib)
            shutil.copyfile(source, os.path.join(out, abi, lib))
            # Its version kept, so is PRoot (built of the same, but maybe not byte for byte)
            for name in extras[abi]:
                source = os.path.join(previous if reuse or repacked else proot_dir, abi, name)
                shutil.copyfile(source, os.path.join(out, abi, name))
        if repacked:
            # Its version stays (the same files), its sizes are this build's archives'
            entry = {
                "version": prev["version"],
                "hash": fp,
                "abis": {abi: built[arch][part] for arch, abi in part_abis.items()},
            }
            print(f"{part}: same files, repacked, keeps {prev['version']}")
        elif reuse:
            entry = dict(prev)
            # Known by what goes into it now, for the next release
            entry["hash"] = fp
            # What it holds as this build lists it (the list isn't in the archive: e.g. now all its
            # packages, where earlier releases listed only its own); sizes stay the archive's
            entry["abis"] = {abi: {**prev["abis"][abi], "components": built[arch][part]["components"]}
                             for arch, abi in part_abis.items()}
            print(f"{part}: {'same files' if same_files else 'unchanged'}, keeps {prev['version']}")
        else:
            entry = {
                "version": tag,
                "hash": fp,
                "abis": {abi: built[arch][part] for arch, abi in part_abis.items()},
            }
            changed.append(part)
            print(f"{part}: {prev['version'] if prev else 'new'} -> {tag}")
        entry["packing"] = packed
        if own_proot:
            entry["proot"] = own_proot
            # First of what the core holds, one entry: talloc is linked into it, no package of its own
            # (earlier releases listed it apart, after the rest)
            for abi in part_abis.values():
                listed = [c for c in entry["abis"][abi]["components"] if not c.startswith(("proot ", "talloc "))]
                entry["abis"][abi]["components"] = [
                    f"proot {own_proot['ref'].removeprefix('v')}_talloc-{own_proot['talloc']}"] + listed
        # What it builds on is the config's, always (it's no archive's)
        entry["requires"] = [] if part == "core" else (extensions[part] or {}).get("requires") or []
        entry["lib"] = lib
        index[part] = entry

    with open(os.path.join(out, "parts.json"), "w", encoding="utf-8") as f:
        json.dump({"release": tag, "parts": index}, f, indent=2)
        f.write("\n")
    # The app's: per ABI, next to its archives (a native library, so each device gets only its own),
    # just what the app reads of each part
    for abi in abis.values():
        own = {
            part: {
                "version": entry["version"],
                "requires": entry["requires"],
                "abis": {abi: entry["abis"][abi]},
            }
            for part, entry in index.items()
            if abi in entry["abis"]
        }
        with open(os.path.join(out, abi, PARTS_LIB), "w", encoding="utf-8") as f:
            json.dump({"release": tag, "parts": own}, f, separators=(",", ":"))
    with open(os.path.join(out, "changed.txt"), "w", encoding="utf-8") as f:
        f.write("".join(f"{p}\n" for p in changed))


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"sizes": sizes, "merge": merge}[command](*args)
