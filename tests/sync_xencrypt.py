"""Copy XEncrypt's apis/xEncrypt.lua into the bundled copy in programs/gitget.lua.

The copy sits between the lines "-- xEncrypt.lua begins" and "-- xEncrypt.lua
ends" and must stay byte-identical; tests/sim/test_sources.lua checks it.

    python tests/sync_xencrypt.py                  # from ../XEncrypt
    python tests/sync_xencrypt.py path/to/xEncrypt.lua

A new global function in xEncrypt.lua also has to be added to the "local"
line above the begin marker, or it leaks into _G when the copy loads.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BEGIN = "-- xEncrypt.lua begins\n"
END = "-- xEncrypt.lua ends\n"


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "..", "XEncrypt", "apis", "xEncrypt.lua")
    with open(source, newline="") as f:
        lib = f.read()
    if not lib.endswith("\n"):
        lib += "\n"
    path = os.path.join(REPO, "programs", "gitget.lua")
    with open(path, newline="") as f:
        program = f.read()
    start = program.index(BEGIN) + len(BEGIN)
    end = program.index(END, start)
    if program[start:end] == lib:
        print("programs/gitget.lua already has this xEncrypt.lua")
        return
    with open(path, "w", newline="") as f:
        f.write(program[:start] + lib + program[end:])
    print("Copied " + source + " into programs/gitget.lua")


if __name__ == "__main__":
    main()
