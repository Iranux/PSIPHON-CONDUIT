# Conduit Manager

```
  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗
 ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝
 ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║
 ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║
 ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║
  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝
                      M A N A G E R - SILENT MODE - Version 2.0
```


A powerful management tool for deploying and managing Psiphon Conduit nodes on Linux servers. Help users access the open internet during network restrictions.

# PSIPHON CONDUIT MANAGER (Iranux)

# Conduit – Fully Automated Server Deployment Script

Conduit is a **fully automated, headless installation and management script** designed for rapid deployment of a secure, Docker-based network service on Linux servers.

The script is engineered to be executed as a **single one-liner**, requiring **zero user interaction**, while preserving a powerful interactive menu for post-install management.

---

## Key Design Principles

- ✅ **One-liner installation**
- ✅ **Zero prompts / headless-friendly**
- ✅ **No feature removal – only enhancements**
- ✅ **Safe re-installation with full cleanup**
- ✅ **Production-ready, auto-start on boot**
- ✅ **Designed for VPS / cloud servers**

---

## Features Overview

### 1. Pre-Installation Automation

- Automatic **root privilege escalation**
- Full **conflict detection and cleanup** of previous or broken installations
- System-wide **OS package update**
- Dependency installation (including **Docker**)

---

### 2. Fully Automated Installation

- Headless installation mode (`--auto`)
- No user input required
- Default configuration applied automatically:
  - **50 concurrent users**
  - **10 Mbps bandwidth per user**
- Docker is installed and enabled automatically

---

### 3. Intelligent IP & Traffic Management (Optional)

A built-in **geo-aware access control system** with a toggle in the menu.

#### Grace Period
- For the **first 12 hours after installation**, all IP addresses are allowed without restriction.

#### After Grace Period
- **Iranian IP addresses**
  - Allowed permanently
  - No forced disconnection
- **Non-Iranian IP addresses**
  - Allowed to connect
  - Automatically disconnected after **5 minutes**
  - Reconnection is required (temporary block applied)

> This logic can be enabled or disabled at any time from the menu.

---

### 4. Persistence & Reliability

- Service is enabled via **systemd**
- Automatically starts on server boot
- Automatically recovers after reboots or crashes

---

### 5. Interactive Management Menu

After installation, the script provides a full interactive menu for:

- Managing services
- Toggling IP / Geo management logic
- Monitoring status
- Applying configuration changes

The menu is displayed **automatically after installation completes**.

---

## Installation

### Option 1 – One-Liner (Recommended)

```bash
curl -sL https://raw.githubusercontent.com/iranux/PSIPHON-CONDUIT/main/conduit_auto.sh | sudo bash
