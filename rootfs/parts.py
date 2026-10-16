"""Run by build.sh: which part of the rootfs (see config.yaml) gets what.

  parts.py split <config.json> <work dir>
      Reads <part>.apt / <part>.pip (what each part needs, dependencies included) and writes
      <part>.apt.own / <part>.pip.own (what goes into it) and <part>.ancestors (the parts it
      builds on). A package goes to the one part needing it that doesn't build on another one
      needing it too; needed by parts apart, it goes to the part they all build on.
"""
import json
import os
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


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"split": split}[command](*args)
