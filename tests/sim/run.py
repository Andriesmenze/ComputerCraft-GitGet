"""Run the GitGet simulator tests (tests/sim/test_*.lua) under LuaJIT.

fakes.lua is a small model of CC: Tweaked (fs with drives and CC's space
accounting, http, term, read, peripheral/disk, shell) plus a fake GitHub (REST
API, raw.githubusercontent.com and the device login). It runs the real
programs/gitget.lua. LuaJIT is the closest match to CC's Cobalt VM: Lua 5.1
semantics and setfenv.

    pip install lupa
    python tests/sim/run.py                        # all test files
    python tests/sim/run.py test_gitget.lua        # one file
    python tests/sim/run.py test_gitget.lua disk   # only tests whose name contains "disk"
"""
import os
import sys

from lupa import luajit21 as lj

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.environ.get("GITGET_REPO") or os.path.join(HERE, "..", ".."))


def program_files(root):
    """The files that run on a CC computer: programs/ and the CraftOS-PC harness."""
    files = []
    for sub in ("programs", os.path.join("tests", "craftos")):
        for dirpath, _, names in os.walk(os.path.join(root, sub)):
            for name in names:
                if name.endswith(".lua"):
                    files.append(os.path.relpath(os.path.join(dirpath, name), root).replace("\\", "/"))
    return sorted(files)


def run_file(path, name_filter):
    lua = lj.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
    lua.execute("package.path = ... .. '/?.lua;' .. package.path", HERE.replace("\\", "/"))
    g = lua.globals()
    g.REPO = REPO.replace("\\", "/")
    g.HERE = HERE.replace("\\", "/")
    g.FILES = lua.table_from(program_files(REPO))
    g.FILTER = name_filter
    with open(path, encoding="utf-8") as f:
        src = f.read()
    run = lua.eval("function(src, name) local f, e = loadstring(src, '@' .. name) if not f then error(e) end return f() end")
    return run(src, os.path.basename(path))


def main():
    sys.stdout.reconfigure(errors="backslashreplace")
    which = sys.argv[1] if len(sys.argv) > 1 else ""
    name_filter = sys.argv[2] if len(sys.argv) > 2 else ""
    files = [which] if which else sorted(f for f in os.listdir(HERE) if f.startswith("test_") and f.endswith(".lua"))
    failed = False
    for f in files:
        print("===== " + f, flush=True)
        failed = run_file(os.path.join(HERE, f), name_filter) or failed
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
