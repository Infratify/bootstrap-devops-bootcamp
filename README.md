# DevOps Bootcamp Bootstrap

> One command. One coffee. A complete dev environment ready for the bootcamp.

A setup script for **DevOps Bootcamp students** to prepare their desktop
environment in a single command. It installs **Git** for version control,
**VS Code** for writing code, **Docker** for running containerised tools
and labs, and a **Linux/Ubuntu shell** on every platform — so your machine
matches what the rest of the class is using on day one.

| Platform | Script | Under the hood |
|---|---|---|
| **Windows** | `install.ps1` | PowerShell + Chocolatey |
| **macOS** | `script-macos.sh` | Bash + Homebrew (Apple Silicon and Intel) |
| **Linux Desktop** | `script-linux.sh` | Bash + apt/dnf (Ubuntu, Debian, Fedora, RHEL, Rocky, AlmaLinux) |

> [!TIP]
> **This script is idempotent.**
>
> *Idempotent* means running the script once or running it ten times
> produces the same end result. If something fails halfway — wifi drops,
> you reboot, you accidentally close the terminal — just run it again.
> The script checks what's already installed, marks those as `Ready`, and
> only touches what's missing. Nothing is reinstalled, overwritten, or
> duplicated.

---

## Quick navigation

- [Before you start](#before-you-start) — prerequisites at a glance
- [Windows](#windows) · [macOS](#macos) · [Linux](#linux) — pick your OS
- [Verify it worked](#verify-it-worked) — sanity check after install
- [If something goes wrong](#if-something-goes-wrong) — troubleshooting

---

## Before you start

| What you need | Detail |
|---|---|
| **Time** | 15–45 minutes (mostly waiting for downloads) |
| **Free disk space** | ~6 GB (Docker is the largest piece) |
| **Internet** | Stable connection — about 2 GB of downloads |
| **Permission** | You'll be asked for your password — UAC on Windows, `sudo` on Mac/Linux |

---

## Windows

1. **Open PowerShell** — press `Win`, type `PowerShell`, hit Enter. (No need to run it as Administrator; the script asks for that itself.)
2. **Paste this command and press Enter:**

   ```powershell
   irm https://raw.githubusercontent.com/Infratify/bootstrap-devops-bootcamp/main/install.ps1 | iex
   ```

3. **Click Yes** on the User Account Control prompt. The bootstrap opens in a **new window** — watch that one from here on.
4. **Wait for it to finish.** If it asks you to **reboot**, that's because Windows can't enable WSL or Hyper-V while it's running. Reboot, then run the same command again — the script picks up where it left off.
5. When it asks **"Would you like to install Ubuntu 24.04 LTS on WSL?"**, press **Y** — that's your Linux shell.

The script lands in `Desktop\bootcamp\`, alongside its `script.log`.

> [!TIP]
> **Prefer clicking to typing?** Download the
> [project ZIP](https://github.com/Infratify/bootstrap-devops-bootcamp/archive/refs/heads/main.zip),
> extract it, and double-click **`script.bat`** instead. Same result.

**What gets installed:** Chocolatey · WSL · Virtual Machine Platform · Hyper-V · Containers · Ubuntu 24.04 LTS · Git · Windows Terminal · VS Code · Docker Desktop.

> [!IMPORTANT]
> Hyper-V and Containers require **Windows Pro / Enterprise / Education**.
> On **Windows Home** those show as `Not Supported` — that's fine, WSL +
> Docker Desktop alone are enough for the bootcamp.

![Bootstrap run on Windows](screenshot-windows.png)

---

## macOS

1. **Open Terminal** — press `⌘` + `Space`, type `Terminal`, hit Enter.
2. **Paste this command and press Enter:**

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Infratify/bootstrap-devops-bootcamp/main/script-macos.sh -o script-macos.sh && bash script-macos.sh
   ```

3. **Approve any prompts.** A system dialog will appear to install Xcode Command Line Tools — click **Install**. The script may also ask for your Mac password.
4. After it finishes, **open Docker Desktop once** (`⌘` + `Space` → Docker) so it can complete its first-run setup.

**What gets installed:** Xcode Command Line Tools · Homebrew · Git · VS Code · Docker Desktop.

> [!TIP]
> [iTerm2](https://iterm2.com/) is a nicer terminal than Apple's Terminal —
> not required for the bootcamp, but a popular optional upgrade.

![Bootstrap run on macOS](screenshot-macos.png)

---

## Linux

Supported: **Ubuntu, Debian, Fedora, RHEL, Rocky, AlmaLinux**.
Other distros (Arch, openSUSE, Alpine, etc.) are reported as `Not Supported`.

1. **Open a terminal.**
2. **Paste this command and press Enter:**

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Infratify/bootstrap-devops-bootcamp/main/script-linux.sh -o script-linux.sh && bash script-linux.sh
   ```

   The script asks for your password (`sudo`) and re-runs itself with admin rights.
3. After Docker installs, **log out and log back in.** This lets your user pick up the `docker` group — without this, you'd need to type `sudo docker …` for every command.

**What gets installed:** Git · VS Code (Microsoft repo) · Docker Engine · Docker CLI · Docker Compose v2 · Buildx · containerd — installed from Docker's official repo (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`).

> [!NOTE]
> Install steps follow Docker's official guide at
> [docs.docker.com/engine/install](https://docs.docker.com/engine/install/).

![Bootstrap run on Linux](screenshot-linux.png)

---

## Verify it worked

**Open a fresh terminal** (close the current one and open a new one), then run:

```bash
git --version
code --version
docker --version
docker compose version
```

Each command should print a version number, similar to:

```
git version 2.45.1
1.95.3
Docker version 27.5.1, build ...
Docker Compose version v2.32.4
```

> [!WARNING]
> If any command says **`command not found`**:
>
> - Close every terminal window and open a new one — PATH changes only apply to new sessions.
> - On Linux, **log out and back in.**
> - Re-run the bootstrap script. Because it's idempotent, it only installs what's missing.

---

## If something goes wrong

1. **Read `script.log`** — it sits next to the script itself and captures every command with its output. The actual error is almost always at the bottom.
2. **Re-run the script.** It's idempotent — running it again only fixes the broken pieces, it never breaks the working ones.
3. **Still stuck?** Open an [issue on this repo](https://github.com/Infratify/bootstrap-devops-bootcamp/issues) with `script.log` attached.

---

<sub>Made for **DevOps Bootcamp** students. Install steps follow each tool's official documentation.</sub>
