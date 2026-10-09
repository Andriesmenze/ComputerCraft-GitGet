"""Run GitGet on real CraftOS-PC (the CC: Tweaked ROM), headless, against the
real GitHub, and check every downloaded file byte for byte.

The computer (live_startup.lua as its startup) runs these, anonymously:

  1. gitget get octocat/Spoon-Knife                     (a whole public repo)
  2. gitget get cc-tweaked/CC-Tweaked@<branch>:<rom>/programs/fun fun --disk
                                                        (one folder of a big repo, onto a floppy)
  3. gitget get octocat/Hello-World:README              (a single file)
  4. gitget get octocat/no-such-repo-gitget-test        (not found; declines the login)
  5. gitget login --save                                (a dummy login in memory, saved
                                                        with a passphrase)
  6. gitget get octocat/Hello-World:README --login      (after a restart: a wrong, then the
                                                        right passphrase; GitHub rejects the
                                                        dummy token, so the file is deleted)

Each downloaded file's git blob SHA-1 is compared with the tree GitHub lists
for the commit GitGet reported, read with `gh api` (so it doesn't use up
the anonymous rate limit).

With --private, it instead downloads one private repository with --login and
prints the login code as soon as GitGet shows it; a person approves it at
https://github.com/login/device (the GitGet app must be installed on the repo):

    python tests/craftos/run.py
    python tests/craftos/run.py --private owner/repo

Needs CraftOS-PC (set CRAFTOS_PC to CraftOS-PC_console.exe if it is not in
C:\\Program Files\\CraftOS-PC\\), the GitHub CLI and internet access. GitGet
makes about 25 anonymous API requests (GitHub allows 60 an hour per address).
Work files go to the system temp folder (gitget-craftos/).
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

EXE = os.environ.get("CRAFTOS_PC", r"C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe")
HERE = os.path.dirname(os.path.abspath(__file__))
DUMMY_APP = "Iv1.gitgetdummy"
PASSPHRASE = "a long test passphrase"
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
WORK = os.path.join(tempfile.gettempdir(), "gitget-craftos")
ROM_FUN = "projects/core/src/main/resources/data/computercraft/lua/rom/programs/fun"


def gh(path):
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def lua(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list):
        return "{" + ", ".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ", ".join("[" + lua(k) + "] = " + lua(x) for k, x in v.items()) + "}"
    raise TypeError(v)


def blob_sha(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


# Characters CC:Tweaked does not allow in file names (BAD_NAME in gitget.lua).
BAD_NAME = re.compile(r'[\x00-\x1f\x7f"*:<>?|\\]')


def tree(repo, sha, path=""):
    """{relative path: blob sha} for the files under path at commit sha that GitGet
    downloads: blobs, without symbolic links (mode 120000) or names CC can't save."""
    t = gh("repos/%s/git/trees/%s?recursive=1" % (repo, sha))
    prefix = path + "/" if path else ""
    return {e["path"][len(prefix):]: e["sha"] for e in t["tree"]
            if e["type"] == "blob" and e["mode"] != "120000" and e["path"].startswith(prefix)
            and not BAD_NAME.search(e["path"][len(prefix):])}


def main():
    if not os.path.exists(EXE):
        sys.exit("CraftOS-PC not found at %s (set CRAFTOS_PC)" % EXE)
    private = None
    if sys.argv[1:2] == ["--private"]:
        if len(sys.argv) < 3:
            sys.exit("usage: run.py --private owner/repo")
        private = sys.argv[2]
        steps = [{"args": ["get", private, "--login"]}]
    else:
        cc_branch = gh("repos/cc-tweaked/CC-Tweaked")["default_branch"]
        steps = [
        {"args": ["get", "octocat/Spoon-Knife"]},
        {"args": ["get", "cc-tweaked/CC-Tweaked@%s:%s" % (cc_branch, ROM_FUN), "fun", "--disk"]},
        {"args": ["get", "octocat/Hello-World:README"]},
        {"args": ["get", "octocat/no-such-repo-gitget-test"], "answers": ["n"]},
        {"args": ["login", "--save", "--client-id", DUMMY_APP], "keep": DUMMY_APP,
         "answers": ["y", PASSPHRASE, PASSPHRASE]},
        {"args": ["get", "octocat/Hello-World:README", "hw", "--login", "--client-id", DUMMY_APP],
         "forget": True, "answers": ["not the passphrase", PASSPHRASE]},
        ]
    shutil.rmtree(WORK, ignore_errors=True)
    c0 = os.path.join(WORK, "computer", "0")
    os.makedirs(c0)
    os.makedirs(os.path.join(WORK, "computer", "disk", "1"))
    shutil.copyfile(os.path.join(REPO, "programs", "gitget.lua"), os.path.join(c0, "gitget.lua"))
    shutil.copyfile(os.path.join(HERE, "live_startup.lua"), os.path.join(c0, "startup.lua"))
    with open(os.path.join(c0, "live_cfg.lua"), "w") as f:
        f.write("return " + lua({"steps": steps}))
    log_path = os.path.join(c0, "live.log")
    proc = subprocess.Popen([EXE, "--headless", "-d", WORK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + (960 if private else 300)
    shown = False
    while proc.poll() is None and time.time() < deadline:
        if private and not shown and os.path.exists(log_path):
            m = re.search(r"^\s+([A-Z0-9]{4}-[A-Z0-9]{4})\s*$", open(log_path, encoding="latin-1").read(), re.M)
            if m:
                print("LOGIN CODE %s: approve it at https://github.com/login/device" % m.group(1), flush=True)
                shown = True
        time.sleep(1)
    if proc.poll() is None:
        proc.kill()
        print("CraftOS-PC did not exit (timeout)")
    log = open(log_path, encoding="latin-1").read() if os.path.exists(log_path) else ""
    parts = re.split(r"^=== STEP \d+\n", log, flags=re.M)[1:]
    took = [int(t) for t in re.findall(r"^=== TOOK (\d+) ms$", log, flags=re.M)]
    failures = []

    def check(cond, what):
        print(("PASS  " if cond else "FAIL  ") + what)
        if not cond:
            failures.append(what)

    check("=== DONE" in log, "the run finished")
    check("HARNESS ERROR" not in log, "no program crashed")

    def compare(step, repo, path, local_root, single=None):
        out = parts[step] if step < len(parts) else ""
        m = re.search(r"from \S+@\S+ \(([0-9a-f]{7})\)", out)
        check(m is not None and "ERROR:" not in out, "step %d downloaded (%s)" % (step + 1, repo))
        if not m:
            print("      " + out.strip().replace("\n", "\n      "))
            return
        full = gh("repos/%s/commits/%s" % (repo, m.group(1)))["sha"]
        want = tree(repo, full, path)
        if single:
            want = {single: tree(repo, full, os.path.dirname(path))[os.path.basename(path)]}
        got = {}
        for dirpath, _, names in os.walk(local_root):
            for n in names:
                p = os.path.join(dirpath, n)
                rel = os.path.relpath(p, local_root).replace("\\", "/")
                if single and rel != single:
                    continue
                with open(p, "rb") as f:
                    got[rel] = blob_sha(f.read())
        check(got == want, "step %d: %d files match GitHub byte for byte" % (step + 1, len(want)))
        if got != want:
            print("      missing: %s" % sorted(set(want) - set(got)))
            print("      extra:   %s" % sorted(set(got) - set(want)))
            print("      differ:  %s" % sorted(k for k in want if k in got and got[k] != want[k]))

    if private:
        out = parts[0] if parts else ""
        check("Logged in." in out, "the device login succeeded")
        compare(0, private, "", os.path.join(c0, private.split("/")[1]))
        print("%d failed" % len(failures))
        if failures:
            print("Log: " + log_path)
            sys.exit(1)
        shutil.rmtree(WORK, ignore_errors=True)
        return
    compare(0, "octocat/Spoon-Knife", "", os.path.join(c0, "Spoon-Knife"))
    compare(1, "cc-tweaked/CC-Tweaked", ROM_FUN, os.path.join(WORK, "computer", "disk", "1", "fun"))
    compare(2, "octocat/Hello-World", "README", c0, single="README")
    last = parts[3] if len(parts) > 3 else ""
    check("doesn't exist, or it is private" in last and "Nothing was downloaded" in last,
          "step 4: a missing repo offers the login and stops when declined")
    save = parts[4] if len(parts) > 4 else ""
    check("Saved to /.gitget_login" in save and "=== SAVED true" in save, "step 5: the login was saved")
    unlock = parts[5] if len(parts) > 5 else ""
    check("Wrong passphrase." in unlock and "Using your saved login" in unlock,
          "step 6: a wrong passphrase fails, the right one unlocks the saved login")
    check("no longer accepts that login" in unlock and "=== SAVED false" in unlock,
          "step 6: GitHub rejects the dummy token, and the saved login is deleted")
    if len(took) > 5:
        # PBKDF2 does not yield: stay well under CC's 7 second limit, also in
        # game (2 to 4 times slower than CraftOS-PC)
        check(took[4] < 4000 and took[5] < 6000, "steps 5 and 6 took %d and %d ms" % (took[4], took[5]))
    print("%d failed" % len(failures))
    if failures:
        print("Log: " + log_path)
        sys.exit(1)
    shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    main()
