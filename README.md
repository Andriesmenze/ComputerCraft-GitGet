# GitGet

Downloads a GitHub repository, or one folder or file of it, onto a [CC: Tweaked](https://tweaked.cc) (ComputerCraft) computer or a floppy disk. Public repositories need nothing. Private ones use a GitHub device login: you approve a short code on your phone or PC, and no token or password is ever typed into or stored on the computer.

## Installation

On the computer, type:

```
wget https://raw.githubusercontent.com/Andriesmenze/ComputerCraft-GitGet/main/programs/gitget.lua
```

That saves `gitget.lua`, so from then on the command is just `gitget`. To get a repository straight away, without installing GitGet first:

```
wget run https://raw.githubusercontent.com/Andriesmenze/ComputerCraft-GitGet/main/programs/gitget.lua get owner/repo
```

To update GitGet later, run `gitget update` (`wget` refuses to overwrite a file).

## Requirements

- CC: Tweaked with the `http` API turned on (the default).
- The server must allow `api.github.com` and `raw.githubusercontent.com` (the default allows them), and `github.com` for logging in.

## Usage

```
gitget get <owner>/<repo>[@ref][:path] [target] [--disk] [--login] [--force] [--client-id <id>]
gitget update
gitget help
```

| Example | What it does |
| --- | --- |
| `gitget get octocat/Spoon-Knife` | The whole repository, default branch, into `Spoon-Knife/` |
| `gitget get octocat/Spoon-Knife myfolder` | The same, into `myfolder/` |
| `gitget get owner/repo@v1.2` | A tag, branch or commit |
| `gitget get owner/repo:apis` | Only the `apis` folder, into `apis/` |
| `gitget get owner/repo:programs/miner.lua` | Only that file, into `miner.lua` |
| `gitget get owner/repo --disk` | Onto a floppy disk (asks which one when there are several) |
| `gitget get owner/private-repo` | Asks whether to log in when GitHub can't find the repository |
| `gitget get owner/private-repo --login` | Logs in first |

A `https://github.com/owner/repo` URL works in place of `owner/repo`.

- **Target:** the default is the repository's name, or the last part of the `:path`, in the current folder. With `--disk` the target is on the disk.
- **Existing files:** if the target folder isn't empty, GitGet asks before going on (`--force` skips the question). Files with the same name are replaced, and other files in the folder are left alone.
- **Skipped entries:** symbolic links, submodules and files whose names CC can't save (with `"*:<>?|\` in them) are skipped, and GitGet tells you about them.

## Private repositories: logging in

GitHub returns "not found" for a private repository until you log in, so GitGet asks:

```
GitHub can't find you/secret: it doesn't exist, or it is private.
Log in to GitHub and try again? (y/n) y
```

The screen then shows something like this:

```
Log in to GitHub

1. On your phone or PC, open
   https://github.com/login/device
2. Enter this code:

   ABCD-1234

3. Approve GitGet.
```

Open the page, type the code and approve. The download then starts by itself.

**Before your first login,** the GitGet GitHub App must be installed on the repositories you want it to read: open https://github.com/apps/gitget-for-computercraft/installations/new and choose the repositories. If it isn't installed on a repository, GitGet still can't find it after the login and shows that link.

### Security notes

- **No token is stored.** The token lives in the program's memory for that one download only. It is never shown, saved, or written to the settings. The next private download asks you to log in again.
- **Limited access.** The token comes from a GitHub App with read-only access to repository contents, and only to the repositories you installed it on. It expires after 8 hours even if someone copied it.
- **Sent only to the API.** The token goes only to `api.github.com`. Public downloads never carry one.
- **Trust the server.** A Minecraft server makes the HTTP requests for its computers, so its operator could see the token. Only log in on servers you trust.
- **Revoking access.** You can see and revoke GitGet's access at https://github.com/settings/apps/authorizations.

### Your own GitHub App

You can also use GitGet with a GitHub App of your own, for example on a GitHub organisation.

1. Open https://github.com/settings/apps/new (or the organisation's settings, under Developer settings, then GitHub Apps).
2. Fill in the app:
   - **GitHub App name:** any name.
   - **Homepage URL:** any URL, for example this repository's.
   - **Callback URL:** leave it empty.
   - **Expire user authorization tokens:** leave it ticked.
   - **Enable Device Flow:** tick it.
   - **Webhook:** untick Active.
   - **Repository permissions:** set Contents to Read-only. Metadata becomes read-only by itself.
   - **Where can this GitHub App be installed?** "Only on this account" is enough for yourself.
3. Click **Create GitHub App**. Copy the **Client ID** shown at the top of the app's page. It is not a secret, and GitGet does not need a client secret.
4. Use **Install App** to install it on the repositories GitGet should read.
5. Download with `gitget get owner/repo --client-id <Client ID>`.

## Rate limits

Without logging in, GitHub allows 60 API requests an hour per IP address. That IP address is the Minecraft server's, so everyone on the server shares the limit. GitGet uses three API requests per download (one more for each folder level in a `:path`) and fetches the files themselves from `raw.githubusercontent.com`, which doesn't count. Logged in, the limit is 5,000 an hour. When the limit is used up, GitGet tells you when it resets.

## How it works

1. **Resolving the version.** GitGet asks the GitHub API for the repository (and its default branch) and turns the branch, tag or commit into a commit ID. Everything after that is downloaded from that commit, so a push during the download can't mix two versions.
2. **Listing the files.** It lists the files with the git trees API. For a `:path` it walks down to that folder first, so a folder of a big repository doesn't need the whole repository's list.
3. **Checking before writing.** Before writing anything, it checks every destination: no folder where a file goes, no file where a folder goes, and enough free space. The space check counts CC's 500-byte minimum per file and folder, plus room for one checked copy.
4. **Downloading in binary mode.** Every file is downloaded in binary mode, so images and non-ASCII text arrive byte for byte. Public files come from `raw.githubusercontent.com`; private ones come from the git blobs API with the token.
5. **Writing safely.** Each file is written to `<name>.gitget-new`, read back and compared, and only then moved over the old file. On a full disk the old file stays as it was. Older CC versions cut writes short without an error, which the read-back catches. If a download stops part-way, GitGet says how many files were saved, and running the same command again finishes the job.

## Files

| File | What it is |
| --- | --- |
| `programs/gitget.lua` | The whole program, the only file a computer needs |
| `tests/sim/` | Simulator suite: a small CC: Tweaked model with a fake GitHub (`fakes.lua`), the scenarios (`test_gitget.lua`), and static checks on the source (`test_sources.lua`) |
| `tests/craftos/` | Live suite: GitGet on CraftOS-PC against the real GitHub |

## Running the tests

The simulator suite runs on desktop LuaJIT through [lupa](https://pypi.org/project/lupa/). CI runs it on every push and pull request.

```
pip install lupa
python tests/sim/run.py
```

The live suite runs GitGet on [CraftOS-PC](https://www.craftos-pc.cc) against the real GitHub. It downloads a whole public repository, one folder of CC: Tweaked onto a floppy, and a single file, then compares every file with GitHub's own blob IDs. It needs CraftOS-PC, the GitHub CLI (`gh`, logged in) and internet access:

```
python tests/craftos/run.py
```

A login has to be approved by a person, so private repositories are tested by hand:

1. Install the app on a private repository.
2. In CraftOS-PC, run `gitget get <owner>/<private repo> --login`.
3. Approve the code, then check the files.

## Licence

GNU General Public License v3.0, see [LICENSE](LICENSE).
