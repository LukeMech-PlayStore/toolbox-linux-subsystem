"""Run by build.sh: what pip installed, as the rootfs parts need it.

  pip-files.py closure <requirement>...  the distributions they need (theirs included), Name==Version
  pip-files.py files <Name==Version>...   those distributions' files, relative to $PREFIX
  pip-files.py top <requirement>...       the requirements' own distributions, "Name Version"
"""
import os
import sys
from importlib.metadata import distribution

from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.utils import canonicalize_name


def closure(reqs):
    seen, dists = set(), {}
    todo = [Requirement(r) for r in reqs]
    while todo:
        req = todo.pop()
        key = (canonicalize_name(req.name), frozenset(req.extras))
        # pip only installs them (a build package, see config.yaml)
        if key in seen or key[0] == "pip":
            continue
        seen.add(key)
        dist = distribution(req.name)
        dists[canonicalize_name(dist.metadata["Name"])] = dist
        for r in dist.requires or []:
            dep = Requirement(r)
            # Only what applies here, with the extras asked for
            if dep.marker and not any(dep.marker.evaluate({"extra": e}) for e in (req.extras or {""})):
                continue
            todo.append(dep)
    return dists.values()


def name(dist):
    return f"{dist.metadata['Name']}=={dist.version}"


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    prefix = os.environ["PREFIX"]
    if command == "closure":
        print("\n".join(sorted(name(d) for d in closure(args))))
    elif command == "top":
        for r in args:
            d = distribution(Requirement(r).name)
            print(f"{d.metadata['Name']} {d.version}")
    elif command == "files":
        for arg in args:
            d = distribution(arg.split("==")[0])
            for f in d.files or []:
                path = os.path.normpath(str(d.locate_file(f)))
                if path.startswith(prefix + "/"):
                    print(os.path.relpath(path, prefix))
