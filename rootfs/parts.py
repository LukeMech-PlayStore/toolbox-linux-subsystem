"""Run by build.sh: which part of the rootfs (see config.yaml) gets what.

  parts.py split <config.json> <work dir>
      Reads <part>.apt / <part>.pip (what each part needs, dependencies included) and writes
      <part>.apt.own / <part>.pip.own (what goes into it) and <part>.ancestors (the parts it
      builds on). A package goes to the one part needing it that doesn't build on another one
      needing it too; needed by parts apart, it goes to the part they all build on.

  parts.py reachable <dpkg status> <closure file> <excluded,...> <package>...
      Prints the packages of <closure file> (apt-cache's, one per line) the <package>s still need
      without the excluded ones (a part's exclude, e.g. a driver only ever loaded when it's there):
      those and what only they needed go.

  parts.py linked <prefix> <dpkg status> <files.tsv> <prune regex> <config.json> <work dir>
      What the parts' own packages really use of their dependencies (Termux's declare a lot only
      their tools, or their building, need: FFmpeg's pull in libtiff, X11, cairo, Python, ...).
      A part uses its own packages (<part>.roots: their programs and data, their libraries when
      linked) and what pip added for it (<part>.pip.files), what those link (DT_NEEDED, all the
      way down) and the interpreters its scripts start with. A dependency package without libraries or programs of its own (data,
      fonts, modules in a subfolder of lib/) comes with the used one depending on it. So:
      - <part>.apt is narrowed down to the packages it uses
      - <work dir>/unused.txt gets the libraries and programs (lib/*, bin/* of a dependency) no
        part uses, relative to <prefix>: those of a package aren't exported
      <files.tsv>: "package<TAB>file" for every file of the installed packages (dpkg -L).
"""
import json
import os
import re
import struct
import sys


def load(path):
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    # config.yaml's packages: the core and the parts building on it
    packages = config.get("packages") or {}
    if "core" not in packages:
        sys.exit("::error::config.yaml has no core under packages")
    extensions = {name: part for name, part in packages.items() if name != "core"}
    parts = ["core"] + list(extensions)
    requires = {"core": []}
    for name, ext in extensions.items():
        requires[name] = (ext or {}).get("requires") or []
        for r in requires[name]:
            # In order: what a part builds on is set up (and checked) before it
            if r not in parts[: parts.index(name)]:
                sys.exit(f"::error::{name} requires {r}, which isn't a part listed before it")
    return extensions, parts, requires


def ancestors(part, requires):
    if part == "core":
        return set()
    seen = {"core"}
    todo = list(requires[part])
    while todo:
        p = todo.pop()
        if p not in seen:
            seen.add(p)
            todo += requires[p]
    return seen


def read_lines(path):
    if not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as f:
        return {line.strip() for line in f if line.strip()}


def split(config_path, work):
    _, parts, requires = load(config_path)
    anc = {p: ancestors(p, requires) for p in parts}

    for kind in ("apt", "pip"):
        need = {p: read_lines(os.path.join(work, f"{p}.{kind}")) for p in parts}
        own = {p: [] for p in parts}
        for item in sorted(set().union(*need.values())):
            needers = {p for p in parts if item in need[p]}
            # Those building on another one needing it get it from there
            needers = {p for p in needers if not (anc[p] & needers)}
            if len(needers) == 1:
                owner = needers.pop()
            else:
                # The most specific part they all build on
                common = set.intersection(*(anc[p] for p in needers))
                owner = next(c for c in common if not any(c in anc[o] for o in common))
            own[owner].append(item)
        for p in parts:
            with open(os.path.join(work, f"{p}.{kind}.own"), "w", encoding="utf-8") as f:
                f.write("".join(f"{i}\n" for i in own[p]))

    for p in parts:
        # Nearest first
        order = [a for a in parts if a in anc[p]][::-1]
        with open(os.path.join(work, f"{p}.ancestors"), "w", encoding="utf-8") as f:
            f.write("".join(f"{a}\n" for a in order))


def read_status(path):
    """Installed packages in dpkg's status file: name -> (dependency groups, what it provides)."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    packages = {}
    for stanza in text.split("\n\n"):
        fields = {}
        key = None
        for line in stanza.splitlines():
            if line[:1].isspace() and key:
                fields[key] += " " + line.strip()
            elif ":" in line:
                key, value = line.split(":", 1)
                fields[key] = value.strip()
        if "Package" not in fields or "installed" not in fields.get("Status", ""):
            continue

        def names(value):
            # "a (>= 1) | b, c" -> [[a, b], [c]]; versions and arch qualifiers dropped
            return [[re.sub(r"[ (:].*", "", alt.strip()) for alt in group.split("|")]
                    for group in value.split(",") if group.strip()]

        groups = names(fields.get("Depends", "")) + names(fields.get("Pre-Depends", ""))
        provides = [alt[0] for alt in names(fields.get("Provides", ""))]
        packages[fields["Package"]] = (groups, provides)
    return packages


def reachable(status, closure_file, excluded, *roots):
    packages = read_status(status)
    closure = read_lines(closure_file)
    gone = {e for e in excluded.split(",") if e}
    providers = {}
    for name in closure:
        for virtual in packages.get(name, ([], []))[1]:
            providers.setdefault(virtual, []).append(name)

    def resolve(alt):
        if alt in closure:
            return [alt]
        return providers.get(alt, [])

    seen = set()
    todo = [r for r in roots if r in closure]
    while todo:
        name = todo.pop()
        if name in seen or name in gone:
            continue
        seen.add(name)
        for group in packages.get(name, ([], []))[0]:
            # The first alternative that's installed (as apt picked it), unless it's excluded: then the next
            options = [p for alt in group for p in resolve(alt)]
            kept = [p for p in options if p not in gone]
            if kept:
                todo.append(kept[0])
    print("".join(f"{n}\n" for n in sorted(seen)), end="")


def elf_needed(path):
    """The DT_NEEDED names of an ELF file (32 or 64-bit, little endian: every Android ABI), None if it isn't one."""
    with open(path, "rb") as f:
        if f.read(4) != b"\x7fELF":
            return None
        data = b"\x7fELF" + f.read()
    is64 = data[4] == 2
    if is64:
        phoff, = struct.unpack_from("<Q", data, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
        phdr, dyn_entry = "<IIQQQQQQ", "<qQ"
    else:
        phoff, = struct.unpack_from("<I", data, 0x1C)
        phentsize, phnum = struct.unpack_from("<HH", data, 0x2A)
        phdr, dyn_entry = "<IIIIIIII", "<iI"
    loads, dynamic = [], None
    for i in range(phnum):
        fields = struct.unpack_from(phdr, data, phoff + i * phentsize)
        if is64:
            p_type, _, p_offset, p_vaddr, _, p_filesz, _, _ = fields
        else:
            p_type, p_offset, p_vaddr, _, p_filesz, _, _, _ = fields
        if p_type == 1:  # PT_LOAD
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:  # PT_DYNAMIC
            dynamic = (p_offset, p_filesz)
    if not dynamic:
        return []
    entries = []
    step = struct.calcsize(dyn_entry)
    for offset in range(dynamic[0], dynamic[0] + dynamic[1], step):
        tag, value = struct.unpack_from(dyn_entry, data, offset)
        if tag == 0:
            break
        entries.append((tag, value))
    # DT_STRTAB is an address: the file offset is that of the segment holding it
    strtab = next((value - vaddr + offset for tag, value in entries if tag == 5
                   for vaddr, offset, size in loads if vaddr <= value < vaddr + size), None)
    if strtab is None:
        return []
    return [data[strtab + value:data.index(b"\0", strtab + value)].decode() for tag, value in entries if tag == 1]


def own_file(path):
    """A package's own library or program (lib/* or bin/*, not in a subfolder): only there when used."""
    return re.match(r"(lib|bin)/[^/]+$", path) is not None


def linked(prefix, status, files_tsv, prune, config_path, work):
    _, parts, requires = load(config_path)
    anc = {p: ancestors(p, requires) for p in parts}
    packages = read_status(status)
    pruned = re.compile(prune)
    files = {}
    with open(files_tsv, encoding="utf-8") as f:
        for line in f:
            package, path = line.rstrip("\n").split("\t", 1)
            if not path.startswith(prefix + "/"):
                continue
            path = path[len(prefix) + 1:]
            full = os.path.join(prefix, path)
            if (os.path.islink(full) or os.path.isfile(full)) and not pruned.match(path):
                files.setdefault(package, []).append(path)
    closure = {p: read_lines(os.path.join(work, f"{p}.apt")) for p in parts}
    # Every part's libraries: one linked from outside a part's tree would be missing at runtime
    # (what's left out on purpose isn't any part's: Android's own libraries, an excluded package)
    in_parts = set().union(*closure.values())
    any_lib = {path[4:]: package for package, paths in files.items() if package in in_parts
               for path in paths if path.startswith("lib/") and own_file(path)}
    errors = []

    used_anywhere, candidates, narrowed = set(), set(), {}
    for p in parts:
        # What it runs with: its packages and those of the parts it builds on
        scope = closure[p].union(*(closure[a] for a in anc[p]))
        owner = {path: package for package in scope for path in files.get(package, [])}
        libs = {path[4:]: path for path in owner if path.startswith("lib/") and own_file(path)}
        providers = {}
        for name in scope:
            for virtual in packages.get(name, ([], []))[1]:
                providers.setdefault(virtual, []).append(name)

        def has_own(package):
            return any(own_file(path) for path in files.get(package, []))

        used, reached = set(), set()
        todo = []

        def use(package):
            if package in used:
                return
            used.add(package)
            # Its data and modules in subfolders come along; its libraries and programs when reached
            todo.extend(path for path in files.get(package, []) if not own_file(path))
            # And what it depends on that has no libraries or programs of its own
            for group in packages.get(package, ([], []))[0]:
                for alt in group:
                    dep = next(iter([alt] if alt in scope else providers.get(alt, [])), None)
                    if dep and dep in scope:
                        if not has_own(dep):
                            use(dep)
                        break

        for package in read_lines(os.path.join(work, f"{p}.roots")):
            use(package)
            # Its programs too; its libraries only when linked (libjpeg-turbo's libjpeg for Pillow,
            # not libturbojpeg)
            todo.extend(path for path in files.get(package, []) if path.startswith("bin/"))
        todo.extend(read_lines(os.path.join(work, f"{p}.pip.files")))
        while todo:
            path = todo.pop()
            if path in reached or pruned.match(path):
                continue
            reached.add(path)
            if path in owner:
                use(owner[path])
            full = os.path.join(prefix, path)
            if os.path.islink(full):
                target = os.path.relpath(os.path.realpath(full), os.path.realpath(prefix))
                if not target.startswith(".."):
                    todo.append(target)
                continue
            if not os.path.isfile(full):
                continue
            needed = elf_needed(full)
            if needed is not None:
                # What Android has (libc.so, liblog.so, ...) isn't in the prefix
                todo.extend(libs[name] for name in needed if name in libs)
                errors.extend(f"::error::{path} ({p}) links {name}, which is {any_lib[name]}'s: not in {p} "
                              f"or what it builds on (built against what another part brought? see pip_libs)"
                              for name in needed if name not in libs and name in any_lib)
                continue
            with open(full, "rb") as f:
                first = f.readline(256)
            if first.startswith(b"#!"):
                # "#!$PREFIX/bin/python3" or "#!$PREFIX/bin/env python3"
                words = first[2:].decode("utf-8", "replace").split()
                if words and words[0].startswith(prefix + "/bin/"):
                    program = words[0][len(prefix) + 1:]
                    if program == "bin/env" and len(words) > 1:
                        program = "bin/" + words[1]
                    todo.append(program)

        narrowed[p] = closure[p] & used
        used_anywhere |= reached
        candidates |= {path for package in used for path in files.get(package, []) if own_file(path)}

    if errors:
        sys.exit("\n".join(sorted(set(errors))))
    unused = candidates - used_anywhere
    for p in parts:
        # Only packages something of which ships (not one all of whose files are pruned or unused,
        # e.g. Python's gdbm, or one with none, e.g. vulkan-icd): no part lists what it doesn't hold
        ships = {n for n in narrowed[p] if any(path not in unused for path in files.get(n, []))}
        with open(os.path.join(work, f"{p}.apt"), "w", encoding="utf-8") as f:
            f.write("".join(f"{n}\n" for n in sorted(ships)))
    with open(os.path.join(work, "unused.txt"), "w", encoding="utf-8") as f:
        f.write("".join(f"{path}\n" for path in sorted(unused)))


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"split": split, "reachable": reachable, "linked": linked}[command](*args)
