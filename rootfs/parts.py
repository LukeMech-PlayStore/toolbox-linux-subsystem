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
"""
import json
import os
import re
import sys


def load(path):
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    extensions = config.get("extensions") or {}
    parts = ["base"] + list(extensions)
    requires = {"base": []}
    for name, ext in extensions.items():
        if name == "base":
            sys.exit("::error::An extension can't be called base")
        requires[name] = (ext or {}).get("requires") or []
        for r in requires[name]:
            # In order: what an extension builds on is set up (and checked) before it
            if r not in parts[: parts.index(name)]:
                sys.exit(f"::error::{name} requires {r}, which isn't an extension listed before it")
    return extensions, parts, requires


def ancestors(part, requires):
    if part == "base":
        return set()
    seen = {"base"}
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


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"split": split, "reachable": reachable}[command](*args)
