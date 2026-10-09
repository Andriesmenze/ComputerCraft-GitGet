# GitGet

Downloads a GitHub repository, or one folder or file of it, onto a [CC: Tweaked](https://tweaked.cc) (ComputerCraft) computer or a floppy disk. Public repositories need nothing. Private ones use a GitHub device login: you approve a short code on your phone or PC, and your GitHub password is never typed into the computer.

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
gitget get <owner>/<repo>[@ref][:path] [target] [--disk] [--login] [--save] [--force]
           [--all] [--skip <names>] [--client-id <id>]
gitget login [--save] [--client-id <id>]
gitget logout
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
| `gitget get owner/private-repo --save` | Logs in first and saves the login, so it survives a restart (see [Saving the login](#saving-the-login)) |
| `gitget get owner/repo --all` | Everything, including tests, docs and dot files |
| `gitget get owner/repo --skip *.md,img` | Also leaves out Markdown files and `img` folders |

A `https://github.com/owner/repo` URL works in place of `owner/repo`.

- **Target:** the default is the repository's name, or the last part of the `:path`, in the current folder. With `--disk` the target is on the disk.
- **Existing files:** if the target folder isn't empty, GitGet asks before going on (`--force` skips the question). Files with the same name are replaced, and other files in the folder are left alone.
- **Left out by default:** files and folders named `test`, `tests`, `spec`, `specs`, `doc` or `docs` (any case, at any depth), and everything whose name starts with a dot (`.github`, `.gitignore`, `.vscode`, ...). They are rarely needed on a computer and take space: every file costs at least 500 bytes. GitGet says how many files it left out; `--all` gets them too. A `:path` that names such a folder or file downloads it anyway (`owner/repo:docs`), but leaves out what lies below it as usual.
- **`--skip <names>`:** leaves out more, on top of the above (also with `--all`). Separate names with commas, or give `--skip` more than once. A name without `/` matches a file or folder of that name anywhere; a name with `/` matches that path from the top of the download (`--skip assets/big`). `*` stands for any characters except `/` (`--skip *.md`), and case is ignored.
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

GitGet keeps the login in the computer's memory until the computer shuts down or restarts, or the token is five minutes from expiring (it lasts 8 hours). Until then, private downloads on that computer need no new login. `gitget login` logs in ahead of time, and `gitget logout` forgets the login sooner.

### Saving the login

**Only do this on a single-player world or on a server whose operators you trust.**

A saved login survives restarts until the token expires (8 hours at most), locked with a passphrase you choose. There are two ways to save one:

- `gitget login --save`: logs in (or uses the login you already have) and saves it.
- `gitget get owner/private-repo --save`: the same, then downloads.

It goes like this:

```
> gitget login --save
You are logged in for the next 7 hours.

Only save your login on a single-player world or on a server whose operators you trust.
...
Save the login for the next 7 hours? (y/n) y
Passphrase (at least 8 characters): ********
Type it again: ********
Encrypting...
Saved to /.gitget_login for the next 7 hours. gitget logout deletes it.
```

After a restart, the next private download asks for the passphrase instead of a new login:

```
> gitget get you/secret
Looking up you/secret...
Passphrase of your saved GitHub login (Enter to skip): ********
Unlocking...
Using your saved login (gitget logout deletes it).
```

Press Enter to log in anew instead. Three wrong passphrases also fall back to a new login. When the token expires, GitGet deletes the file and you log in (and save) again.

- The token is encrypted with xEncrypt (ChaCha20 and HMAC-SHA256, from [ComputerCraft-XEncrypt](https://github.com/Andriesmenze/ComputerCraft-XEncrypt), bundled in `gitget.lua`). The key comes from your passphrase through PBKDF2 with 2000 rounds and a random salt. The app's client ID and the expiry time are authenticated with it, so changing either one makes the file unusable.
- **The passphrase is the only protection.** Whoever can copy the file can try passphrases on a fast PC, without limits and without you noticing. That includes the server's operators (the file is in the world save), anyone with access to the server's files, and every program on that computer. 2000 rounds is far below what real password storage uses, because CC's Lua is slow. Use a long passphrase that you use nowhere else.
- A leaked file is useless after the token expires, and you can revoke the login sooner (see the security notes).
- The file is deleted when it expires, when GitHub rejects the token, and by `gitget logout`.
- Drawing the salt saves xEncrypt's random seed to `/.xEncrypt.seed`. The seed is not secret by itself, but leave it where it is.

**Before your first login,** the GitGet GitHub App must be installed on the repositories you want it to read: open https://github.com/apps/gitget-for-computercraft/installations/new and choose the repositories. If it isn't installed on a repository, GitGet still can't find it after the login and shows that link.

### Security notes

- **No token is stored on disk unless you save it.** The token is never shown or written to the settings. It is kept in the computer's memory (`_G`) until the computer restarts, so it is gone after a reboot, a chunk unload or a server restart. Only `gitget login --save` writes it to a file, encrypted (see [Saving the login](#saving-the-login)).
- **Encrypting it in memory wouldn't help.** The key would have to be in memory next to it, where the same programs can read it.
- **Programs on the same computer can read it.** While the login is kept, any program running on that computer can read the token from `_G`, including code you just downloaded. Run `gitget logout` before running programs you don't trust, or on a computer other players use. Logging out forgets the token on the computer; it stays valid on GitHub until it expires, unless you revoke it (below).
- **Limited access.** The token comes from a GitHub App with read-only access to repository contents. It expires after 8 hours even if someone copied it.
- **Other GitGet users can't see your repositories.** A login acts as the person who approved it. Their token reaches only repositories that have the app installed *and* that they could already read on GitHub. So installing the app on your private repository doesn't let anyone else who logs in through GitGet see it.
- **Installing the app means trusting its owner.** A GitHub App's owner can create a private key for the app and use it to read every repository the app is installed on, without anyone logging in. GitGet itself never does this, and the GitGet app has no use for a private key. If you don't want to trust the owner of the shared app, create your own app (see [Your own GitHub App](#your-own-github-app)) and use it with `--client-id`.
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
| `tests/sync_xencrypt.py` | Copies XEncrypt's `apis/xEncrypt.lua` into the bundled copy in `gitget.lua` |

## Running the tests

The simulator suite runs on desktop LuaJIT through [lupa](https://pypi.org/project/lupa/). CI runs it on every push and pull request.

```
pip install lupa
python tests/sim/run.py
```

`gitget.lua` holds an unchanged copy of XEncrypt's `apis/xEncrypt.lua` between the lines `-- xEncrypt.lua begins` and `-- xEncrypt.lua ends`. The simulator suite compares it with `../XEncrypt` when that is checked out next to GitGet (CI skips this check). After a change to xEncrypt, copy it in with:

```
python tests/sync_xencrypt.py
```

The live suite runs GitGet on [CraftOS-PC](https://www.craftos-pc.cc) against the real GitHub. It downloads a whole public repository, one folder of CC: Tweaked onto a floppy, a single file, and this repository (whose tests and dot files must be left out), then compares every file with GitHub's own blob IDs. It also saves a dummy login with `gitget login --save`, then unlocks it after a simulated restart (a wrong passphrase first). GitHub rejects the dummy token, so the file must be deleted, and it times the passphrase steps. It needs CraftOS-PC, the GitHub CLI (`gh`, logged in) and internet access.

A run makes about 15 anonymous API requests, out of the 60 an hour GitHub allows per IP address. Before it starts, the runner checks how many are left; when fewer than 20 are, it waits for the limit to reset instead of failing part-way (`--no-wait` stops with a message instead):

```
python tests/craftos/run.py
```

A login has to be approved by a person, so private repositories are tested by hand:

1. Install the app on a private repository.
2. In CraftOS-PC, run `gitget get <owner>/<private repo> --login`.
3. Approve the code, then check the files.

## Licence

GNU General Public License v3.0, see [LICENSE](LICENSE).
