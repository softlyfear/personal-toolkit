## Quick Install

#### Setting server
```shell
source <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh)
```

#### Add gnome + xrdp
```shell
source <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_gnome_xrdp.sh)
```

#### Add xfce + xrdp
```shell
source <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_xfce_xrdp.sh)
```

#### Download Makefile for FastApi projects
```
wget -O Makefile https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/Makefile
```

#### Installs `svcctl` — a utility to manage `postgresql` and `docker` services (start/stop/restart/status/enable/disable)
```shell
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_svcctl.sh)
```

#### `svcctl` (service manager)
```shell
svcctl status all
svcctl start postgresql
svcctl stop docker
```

#### `devsetup` by direct link (no pre-install needed)
Runs `devsetup` directly from GitHub and installs the full default stack: `git`, `uv`, `docker`, and `postgresql`
```shell
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/install-dev-tools.sh)
```

#### `devsetup` with explicit selection
Runs `devsetup` from GitHub with your chosen packages only (e.g. `git uv` or `docker postgresql`)
```shell
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/install-dev-tools.sh) git uv docker postgresql
```

#### Full system update (apt + snap + flatpak)
```shell
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/update_system_all.sh)
```

#### Install `sysupdate` globally (run updates anytime)
```shell
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_sysupdate.sh)
```

#### Run local update command
```shell
sysupdate
```