# remove-onedrive

One script that completely removes OneDrive from a fresh Windows 10/11 install
and puts your Desktop, Documents, Pictures, Music, Videos and Screenshots
folders back where they belong: `C:\Users\<you>\...`.

## Why this exists

Every new Windows PC ships with OneDrive. The moment you sign in with a
Microsoft account it turns on "Known Folder Backup" and silently moves your
Desktop, Documents and Pictures into `C:\Users\<you>\OneDrive\...`.

Uninstalling OneDrive from Settings **does not undo that**. Windows keeps
pointing at the OneDrive folders, so you get:

- `Location is not available – C:\Users\<you>\OneDrive\Desktop is unavailable`
  every time Explorer opens
- "Pictures" in Quick Access opening an empty OneDrive folder
- Screenshots and new files landing in `OneDrive\Pictures` instead of `Pictures`
- A dead "OneDrive - Personal" entry stuck in the Explorer sidebar

This script fixes all of it in one go.

## Quick start

1. Download or clone this repo.
2. Open PowerShell (no need for "Run as administrator"; the script asks for
   it when it needs it).
3. See what would change:

   ```powershell
   .\Remove-OneDrive.ps1 -CheckOnly
   ```

4. Do it:

   ```powershell
   .\Remove-OneDrive.ps1
   ```

5. Approve the UAC prompt, wait for the green "[ok]" report, then sign out and
   back in.

If PowerShell refuses to run the script ("running scripts is disabled"), run
this once first, in the same window:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## What it does, step by step

| Step | Action | Why |
|------|--------|-----|
| 1 | Kills every OneDrive process | Files and registry keys can't be removed while it runs |
| 2 | Runs `OneDriveSetup.exe /uninstall` for the per-user **and** machine-wide installs, and removes the Store package if present | Newer Windows builds install OneDrive under `Program Files` for all users; the Settings uninstaller only removes one of them |
| 3 | Rewrites the "User Shell Folders" and "Shell Folders" registry values for Desktop, Documents, Pictures, Music, Videos, Screenshots and Camera Roll to `%USERPROFILE%\...` and creates those folders | This is the part Settings never does. It's what causes the "Location is not available" error |
| 4 | Moves any file still inside `C:\Users\<you>\OneDrive` to the matching local folder | So nothing is lost. If a file of the same name already exists locally, the OneDrive one is kept as `name (from OneDrive).ext` |
| 5 | Removes the "OneDrive - Personal" sidebar node, the `Run` startup entry, the OneDrive scheduled update tasks and the `OneDrive` / `OneDriveConsumer` environment variables | Leftovers that keep OneDrive showing in Explorer and relaunching at sign-in |
| 6 | Sets the `DisableFileSyncNGSC` policy and removes `OneDriveSetup` from the Default user profile | Stops Windows Update and new user accounts from bringing it back |
| 7 | Deletes `C:\Users\<you>\OneDrive`, `%LOCALAPPDATA%\Microsoft\OneDrive`, `%ProgramData%\Microsoft OneDrive`, `C:\OneDriveTemp` and the Program Files folders | Clean machine |
| 8 | Restarts Explorer and prints a verification report | So you can see it worked without rebooting |

## Options

| Switch | Effect |
|--------|--------|
| `-CheckOnly` | Report only. Changes nothing, needs no admin rights. |
| `-KeepFiles` | Rescue files into the local folders but leave the `OneDrive` folder in place so you can look through it yourself. |
| `-SkipUninstall` | Leave the OneDrive program installed; only fix the folder locations and Explorer. |

## What it does NOT do

- **It never touches your OneDrive cloud account.** Anything you had synced is
  still at [onedrive.live.com](https://onedrive.live.com). Only the local copy
  on this PC is removed, and every file in it is moved to the local user
  folders first.
- It only fixes the **currently signed-in user**. Run it once per account if
  the PC has several.
- It doesn't remove OneDrive from Microsoft Office's "recent places" list.
  Those entries fade out on their own.

## Verifying it worked

Open a new Explorer window. You should see:

- No "Location is not available" dialog
- No "OneDrive - Personal" in the left sidebar
- Pictures / Desktop / Documents in Quick Access opening `C:\Users\<you>\...`

Or just run `.\Remove-OneDrive.ps1 -CheckOnly` again and look for red `[bad]`
lines. There should be none.

## Undoing it

Install OneDrive again from
[microsoft.com/microsoft-365/onedrive/download](https://www.microsoft.com/microsoft-365/onedrive/download),
then delete the policy key so it's allowed to run:

```powershell
Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Recurse
```

Sign in and OneDrive will offer to turn Known Folder Backup back on.

## Troubleshooting

**"Could not delete ... delete it after a reboot"**
Something still had a file open. Reboot and delete the folder by hand; the
important fixes (registry + uninstall) are already done.

**Explorer still shows OneDrive in the sidebar after the script**
Sign out and back in. Explorer caches the sidebar until the next sign-in.

**Documents still opens an OneDrive path**
Some apps cache the old location until you sign out. If it persists after
sign-in, run `.\Remove-OneDrive.ps1 -CheckOnly` and look at the `Personal`
line.

**I ran it from a tool or sandbox and nothing changed**
Some automation tools (sandboxed terminals, remote agents) run against a
*virtual* copy of the registry, so edits look like they worked but never reach
Windows. Run the script from a normal PowerShell window on the PC itself.

## Files

- `Remove-OneDrive.ps1` – the script. Fully commented; read it before you run it.
- `README.md` – this file.
- `CHANGELOG.md` – what changed between versions.

## License

MIT. See `LICENSE`.
