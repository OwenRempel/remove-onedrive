# Changelog

## 1.0.0 - 2026-10-29

First version. Written after cleaning up a Windows 11 Home PC where
uninstalling OneDrive from Settings left Desktop, Documents, Pictures and
Screenshots pointing at a missing `OneDrive` folder, causing a
"Location is not available" dialog on every Explorer launch.

- Uninstalls per-user, machine-wide and Store installs of OneDrive
- Repoints all known folders back to `%USERPROFILE%`
- Rescues leftover files from the OneDrive folder
- Removes sidebar node, startup entry, scheduled tasks, environment variables
- Blocks reinstall through policy and the Default user profile
- `-CheckOnly`, `-KeepFiles`, `-SkipUninstall` switches
- Admin window writes `Remove-OneDrive.log` and waits for Enter before closing
- Verified on a Windows 11 Home 25H2 PC: full run then `-CheckOnly` all green
