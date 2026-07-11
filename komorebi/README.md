# Komorebi Autostart Setup

## Startup

Copy `launch.vbs` to:

```
C:\Users\%USERPROFILE%\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\
```

Edit `launch.vbs` so it points to the location of `komorebi_autostart.ps1`.

## Komorebi Configuration

Copy the following to your Komorebi config directory (`%USERPROFILE%\AppData\Local\komorebi` or your configured profile location):

* `komorebi.json`
* `applications.json`
* `.config/`

## Installation

Install the required components:

```powershell
winget install -e LGUG2Z.whkd LGUG2Z.masir LGUG2Z.komorebi
```
