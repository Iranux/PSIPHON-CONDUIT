# Conduit Manager

```
  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗
 ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝
 ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║
 ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║
 ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║
  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝
                      M A N A G E R
```

![Version](https://img.shields.io/badge/version-1.2-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Linux-orange)
![Docker](https://img.shields.io/badge/Docker-Required-2496ED?logo=docker&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-Script-4EAA25?logo=gnubash&logoColor=white)

A powerful management tool for deploying and managing Psiphon Conduit nodes on Linux servers. Help users access the open internet during network restrictions.

## Screenshots

| Main Menu | Live Dashboard |
|:-:|:-:|
| ![Main Menu](conduit-menu.png) | ![Live Stats](conduit-stats.png) |

| Live Map | Advanced Stats |
|:-:|:-:|
| ![Live Map](conduit-live-map.png) | ![Advanced Stats](conduit-advanced-stats.png) |

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | sudo bash
```

Or download and run manually:

```bash
wget https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh
sudo bash conduit.sh
```

## What's New in v1.2

- **Per-Container Resource Limits** — Set CPU and memory limits per container via Settings menu with smart defaults
- **Telegram Bot Integration** — Periodic status reports, alerts, and commands (`/status`, `/peers`, `/uptime`, `/containers`, `/restart_N`, `/stop_N`, `/start_N`)
- **Systemd Notification Service** — Telegram bot runs as a systemd service, survives reboots and TUI exits
- **Performance Overhaul** — Parallelized docker commands across all TUI screens, reduced refresh from ~10s to ~2-3s
- **Compact Number Display** — Large counts show as 16.5K, 1.2M
- **Active Clients Count** — Connected and connecting peers in dashboard and Telegram reports
- **Atomic Config Writes** — Settings file writes are now crash-safe
- **Secure Temp Directories** — All temp dirs use `mktemp` for secure random names
- **20+ Bug Fixes** — TUI stability, health check edge cases, Telegram escaping, peer count consistency, and more

## Features

- **One-Click Deployment** — Automatically installs Docker and configures everything
- **Multi-Container Scaling** — Run 1–5 containers to maximize your server's capacity
- **Multi-Distro Support** — Works on Ubuntu, Debian, CentOS, Fedora, Arch, Alpine, openSUSE
- **Auto-Start on Boot** — Supports systemd, OpenRC, and SysVinit
- **Live Dashboard** — Real-time connection stats with CPU/RAM monitoring and per-country client breakdown
- **Advanced Stats** — Top countries by connected peers, download, upload, and unique IPs with bar charts
- **Live Peer Traffic** — Real-time traffic table by country with speed, total bytes, and IP/client counts
- **Background Tracker** — Continuous traffic monitoring via systemd service with GeoIP resolution
- **Telegram Bot** — On-demand `/status`, `/peers`, `/uptime`, `/containers` and remote container management via Telegram
- **Per-Container Settings** — Configure max-clients, bandwidth, CPU, and memory per container
- **Resource Limits** — Set CPU and memory limits with smart defaults based on system specs
- **Easy Management** — Powerful CLI commands or interactive menu
- **Backup & Restore** — Backup and restore your node identity keys
- **Health Checks** — Comprehensive diagnostics for troubleshooting
- **Info & Help** — Built-in multi-page guide explaining how everything works
- **Complete Uninstall** — Clean removal of all components including Telegram service

## Supported Distributions

| Family | Distributions |
|--------|---------------|
| Debian | Ubuntu, Debian, Linux Mint, Pop!_OS, Kali, Raspbian |
| RHEL | CentOS, Fedora, Rocky Linux, AlmaLinux, Amazon Linux |
| Arch | Arch Linux, Manjaro, EndeavourOS |
| SUSE | openSUSE Leap, openSUSE Tumbleweed |
| Alpine | Alpine Linux |

## CLI Reference

After installation, use the `conduit` command:

### Status & Monitoring
```bash
conduit status       # Show current status and resource usage
conduit stats        # View live statistics (real-time dashboard)
conduit logs         # View raw Docker logs
conduit health       # Run health check diagnostics
conduit peers        # Live peer traffic by country (GeoIP)
```

### Rewards
```bash
conduit qr           # Show QR code to claim rewards via Ryve app
```

### Container Management
```bash
conduit start        # Start all Conduit containers
conduit stop         # Stop all Conduit containers
conduit restart      # Restart all Conduit containers
conduit update       # Update to the latest Conduit image
```

### Configuration
```bash
conduit settings     # Change max-clients, bandwidth, CPU, memory per container
conduit menu         # Open interactive management menu
```

### Backup & Restore
```bash
conduit backup       # Backup your node identity keys
conduit restore      # Restore node identity from backup
```

### Maintenance
```bash
conduit uninstall    # Remove all components
conduit version      # Show version information
conduit help         # Show help message
```

## Interactive Menu

The interactive menu (`conduit menu`) provides access to all features:

| Option | Description |
|--------|-------------|
| **1** | View status dashboard — real-time stats with active clients and top upload by country |
| **2** | Live connection stats — streaming stats from Docker logs |
| **3** | View logs — raw Docker log output |
| **4** | Live peers by country — per-country traffic table with speed and client counts |
| **5** | Start Conduit |
| **6** | Stop Conduit |
| **7** | Restart Conduit |
| **8** | Update Conduit image |
| **9** | Settings & Tools — resource limits, QR code, backup, restore, health check, Telegram, uninstall |
| **c** | Manage containers — add or remove containers (up to 5) |
| **a** | Advanced stats — top 5 charts for peers, download, upload, unique IPs |
| **i** | Info & Help — multi-page guide with tracker, stats, containers, privacy, about |
| **0** | Exit |

## Configuration Options

| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| `max-clients` | 200 | 1–1000 | Maximum concurrent proxy clients per container |
| `bandwidth` | 5 | 1–40, -1 | Bandwidth limit per peer (Mbps). Use -1 for unlimited. |
| `cpu` | Unlimited | 0.1–N cores | CPU limit per container (e.g. 1.0 = one core) |
| `memory` | Unlimited | 64m–system RAM | Memory limit per container (e.g. 256m, 1g) |

**Recommended values based on server hardware:**

| CPU Cores | RAM | Recommended Containers | Max Clients (per container) |
|-----------|-----|------------------------|-----------------------------|
| 1 Core | < 1 GB | 1 | 100 |
| 2 Cores | 2 GB | 1–2 | 200 |
| 4 Cores | 4 GB+ | 2–3 | 400 |
| 8+ Cores | 8 GB+ | 3–5 | 800 |

## Installation Options

```bash
# Standard install
sudo bash conduit.sh

# Force reinstall
sudo bash conduit.sh --reinstall

# Uninstall everything
sudo bash conduit.sh --uninstall

# Show help
sudo bash conduit.sh --help
```

## Upgrading

Just run the install command above or use `conduit update` from the menu. Existing containers are recognized automatically. Telegram settings and node identity keys are preserved across upgrades.

## Requirements

- Linux server (any supported distribution)
- Root/sudo access
- Internet connection
- Minimum 512MB RAM (1GB+ recommended for multi-container)

## How It Works

1. **Detection** — Identifies your Linux distribution and init system
2. **Docker Setup** — Installs Docker if not present
3. **Hardware Check** — Detects CPU/RAM and recommends container count
4. **Container Deployment** — Pulls and runs the official Psiphon Conduit image
5. **Auto-Start Configuration** — Sets up systemd/OpenRC/SysVinit service
6. **Tracker Service** — Starts background traffic tracker with GeoIP resolution
7. **CLI Installation** — Creates the `conduit` management command

## Claim Rewards (OAT Tokens)

Conduit node operators can earn OAT tokens for contributing to the Psiphon network. To claim rewards:

1. **Install the Ryve app** on your phone
2. **Create a crypto wallet** within the app
3. **Link your Conduit containers** by scanning the QR code:
   - From the menu: Select Settings & Tools **Option 6 → Show QR Code & Conduit ID**
   - From Manage Containers: press **[q]** to display QR code
   - CLI: `conduit qr`
4. **Scan the QR code** with the Ryve app to link your node
5. **Monitor & earn** — the app shows your last 48 hours of connection activity and OAT token rewards

> Each container has its own unique Conduit ID and QR code. If running multiple containers, you'll need to link each one separately.

## Security

- **Secure Backups**: Node identity keys are stored with restricted permissions (600)
- **No Telemetry**: The manager collects no data and sends nothing externally
- **Local Tracking Only**: Traffic stats are stored locally and never transmitted
- **Telegram Optional**: Bot notifications are opt-in only, zero resources used if disabled

---

<div dir="rtl">

# راهنمای فارسی - مدیریت کاندوییت

ابزار قدرتمند برای راه‌اندازی و مدیریت نود سایفون کاندوییت روی سرورهای لینوکس. به کاربران کمک کنید تا در زمان محدودیت‌های اینترنتی به اینترنت آزاد دسترسی داشته باشند.

## تصاویر

| منوی اصلی | داشبورد زنده |
|:-:|:-:|
| ![منوی اصلی](conduit-menu.png) | ![آمار زنده](conduit-stats.png) |

| نقشه زنده | آمار پیشرفته |
|:-:|:-:|
| ![نقشه زنده](conduit-live-map.png) | ![آمار پیشرفته](conduit-advanced-stats.png) |

## نصب سریع

دستور زیر را در ترمینال سرور اجرا کنید:

```bash
curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | sudo bash
```

یا دانلود و اجرای دستی:

```bash
wget https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh
sudo bash conduit.sh
```

## تازه‌های نسخه 1.2

- **محدودیت منابع هر کانتینر** — تنظیم محدودیت CPU و حافظه برای هر کانتینر با پیش‌فرض‌های هوشمند
- **ربات تلگرام** — گزارش‌های دوره‌ای، هشدارها و دستورات (`/status`، `/peers`، `/uptime`، `/containers`، `/restart_N`، `/stop_N`، `/start_N`)
- **سرویس اعلان سیستمی** — ربات تلگرام به عنوان سرویس systemd اجرا می‌شود و پس از ریستارت سرور فعال می‌ماند
- **بهبود عملکرد** — دستورات داکر به صورت موازی اجرا شده، زمان رفرش از ~۱۰ ثانیه به ~۲-۳ ثانیه کاهش یافته
- **نمایش فشرده اعداد** — اعداد بزرگ به صورت 16.5K و 1.2M نمایش داده می‌شوند
- **شمارش کلاینت‌های فعال** — تعداد متصل و در حال اتصال در داشبورد و گزارش تلگرام
- **ذخیره امن تنظیمات** — نوشتن فایل تنظیمات به صورت اتمیک برای جلوگیری از خرابی
- **۲۰+ رفع باگ** — پایداری رابط کاربری، بررسی سلامت، فرمت تلگرام، هماهنگی تعداد کاربران و موارد دیگر

## ویژگی‌ها

- **نصب با یک کلیک** — داکر و تمام موارد مورد نیاز به صورت خودکار نصب می‌شود
- **مقیاس‌پذیری چند کانتینره** — اجرای ۱ تا ۵ کانتینر برای حداکثر استفاده از سرور
- **پشتیبانی از توزیع‌های مختلف** — اوبونتو، دبیان، سنت‌اواس، فدورا، آرچ، آلپاین، اوپن‌سوزه
- **راه‌اندازی خودکار** — پس از ریستارت سرور، سرویس به صورت خودکار اجرا می‌شود
- **داشبورد زنده** — نمایش لحظه‌ای وضعیت، تعداد کاربران، مصرف CPU و RAM
- **آمار پیشرفته** — نمودار میله‌ای برترین کشورها بر اساس اتصال، دانلود، آپلود و IP
- **مانیتورینگ ترافیک** — جدول لحظه‌ای ترافیک بر اساس کشور با سرعت و تعداد کلاینت
- **ردیاب پس‌زمینه** — سرویس ردیابی مداوم ترافیک با تشخیص جغرافیایی
- **ربات تلگرام** — دستورات `/status`، `/peers`، `/uptime`، `/containers` و مدیریت کانتینر از راه دور (اختیاری)
- **تنظیمات هر کانتینر** — پیکربندی حداکثر کاربران، پهنای باند، CPU و حافظه برای هر کانتینر
- **محدودیت منابع** — تنظیم محدودیت CPU و حافظه با پیش‌فرض‌های هوشمند
- **مدیریت آسان** — دستورات قدرتمند CLI یا منوی تعاملی
- **پشتیبان‌گیری و بازیابی** — پشتیبان‌گیری و بازیابی کلیدهای هویت نود
- **بررسی سلامت** — تشخیص جامع برای عیب‌یابی
- **راهنما و اطلاعات** — راهنمای چندصفحه‌ای داخلی
- **حذف کامل** — پاکسازی تمام فایل‌ها و تنظیمات شامل سرویس تلگرام

## دستورات CLI

### وضعیت و مانیتورینگ
```bash
conduit status       # نمایش وضعیت و مصرف منابع
conduit stats        # داشبورد زنده (لحظه‌ای)
conduit logs         # لاگ‌های داکر
conduit health       # بررسی سلامت سیستم
conduit peers        # ترافیک بر اساس کشور (GeoIP)
```

### پاداش
```bash
conduit qr           # نمایش QR کد برای دریافت پاداش از اپلیکیشن Ryve
```

### مدیریت کانتینر
```bash
conduit start        # شروع تمام کانتینرها
conduit stop         # توقف تمام کانتینرها
conduit restart      # ریستارت تمام کانتینرها
conduit update       # به‌روزرسانی به آخرین نسخه
```

### پیکربندی
```bash
conduit settings     # تغییر تنظیمات هر کانتینر
conduit menu         # منوی تعاملی
```

### پشتیبان‌گیری و بازیابی
```bash
conduit backup       # پشتیبان‌گیری از کلیدهای نود
conduit restore      # بازیابی کلیدهای نود از پشتیبان
```

### نگهداری
```bash
conduit uninstall    # حذف کامل
conduit version      # نمایش نسخه
conduit help         # راهنما
```

## منوی تعاملی

| گزینه | توضیحات |
|-------|---------|
| **1** | داشبورد وضعیت — آمار لحظه‌ای با کلاینت‌های فعال و آپلود برتر |
| **2** | آمار زنده اتصال — استریم آمار از لاگ داکر |
| **3** | مشاهده لاگ — خروجی لاگ داکر |
| **4** | ترافیک زنده به تفکیک کشور — جدول ترافیک با سرعت و تعداد کلاینت |
| **5** | شروع کاندوییت |
| **6** | توقف کاندوییت |
| **7** | ریستارت کاندوییت |
| **8** | به‌روزرسانی ایمیج و اسکریپت |
| **9** | تنظیمات و ابزارها — محدودیت منابع، QR کد، پشتیبان‌گیری، بازیابی، تلگرام، حذف نصب |
| **c** | مدیریت کانتینرها — اضافه یا حذف (تا ۵) |
| **a** | آمار پیشرفته — نمودار برترین کشورها |
| **i** | راهنما — توضیحات ردیاب، آمار، کانتینرها، حریم خصوصی |
| **0** | خروج |

## تنظیمات

| گزینه | پیش‌فرض | محدوده | توضیحات |
|-------|---------|--------|---------|
| `max-clients` | 200 | ۱–۱۰۰۰ | حداکثر کاربران همزمان برای هر کانتینر |
| `bandwidth` | 5 | ۱–۴۰ یا ۱- | محدودیت پهنای باند (Mbps). برای نامحدود ۱- وارد کنید. |
| `cpu` | نامحدود | 0.1–N هسته | محدودیت CPU هر کانتینر (مثلاً 1.0 = یک هسته) |
| `memory` | نامحدود | 64m–حافظه سیستم | محدودیت حافظه هر کانتینر (مثلاً 256m، 1g) |

**مقادیر پیشنهادی بر اساس سخت‌افزار سرور:**

| پردازنده | رم | کانتینر پیشنهادی | حداکثر کاربران (هر کانتینر) |
|----------|-----|-------------------|----------------------------|
| ۱ هسته | کمتر از ۱ گیگ | ۱ | ۱۰۰ |
| ۲ هسته | ۲ گیگ | ۱–۲ | ۲۰۰ |
| ۴ هسته | ۴ گیگ+ | ۲–۳ | ۴۰۰ |
| ۸+ هسته | ۸ گیگ+ | ۳–۵ | ۸۰۰ |

## گزینه‌های نصب

```bash
# نصب استاندارد
sudo bash conduit.sh

# نصب مجدد اجباری
sudo bash conduit.sh --reinstall

# حذف کامل
sudo bash conduit.sh --uninstall

# نمایش راهنما
sudo bash conduit.sh --help
```

## ارتقا از نسخه‌های قبلی

فقط دستور نصب بالا را اجرا کنید یا از منو گزینه `conduit update` را بزنید. کانتینرهای موجود به صورت خودکار شناسایی می‌شوند. تنظیمات تلگرام و کلیدهای هویت نود در به‌روزرسانی حفظ می‌شوند.

## پیش‌نیازها

- سرور لینوکس
- دسترسی root یا sudo
- اتصال اینترنت
- حداقل ۵۱۲ مگابایت رم (۱ گیگ+ برای چند کانتینر پیشنهاد می‌شود)

## نحوه عملکرد

1. **تشخیص** — شناسایی توزیع لینوکس و سیستم init
2. **نصب داکر** — در صورت نبود، داکر نصب می‌شود
3. **بررسی سخت‌افزار** — تشخیص CPU و RAM و پیشنهاد تعداد کانتینر
4. **راه‌اندازی کانتینر** — دانلود و اجرای ایمیج رسمی سایفون
5. **پیکربندی سرویس** — تنظیم سرویس خودکار (systemd/OpenRC/SysVinit)
6. **سرویس ردیاب** — شروع ردیاب ترافیک پس‌زمینه
7. **نصب CLI** — ایجاد دستور مدیریت `conduit`

## دریافت پاداش (توکن OAT)

اپراتورهای نود کاندوییت می‌توانند با مشارکت در شبکه سایفون توکن OAT کسب کنند. مراحل دریافت پاداش:

1. **اپلیکیشن Ryve** را روی گوشی نصب کنید
2. **یک کیف پول کریپتو** در اپلیکیشن بسازید
3. **کانتینرهای خود را لینک کنید** با اسکن QR کد:
   - از منو تنظیمات: **گزینه ۶ ← نمایش QR کد و شناسه کاندوییت**
   - از مدیریت کانتینرها: کلید **[q]** را بزنید
   - CLI: `conduit qr`
4. **QR کد را اسکن کنید** با اپلیکیشن Ryve تا نود شما لینک شود
5. **مانیتور و کسب درآمد** — اپلیکیشن فعالیت ۴۸ ساعت اخیر و توکن‌های OAT را نمایش می‌دهد

> هر کانتینر شناسه و QR کد منحصر به فرد خود را دارد. اگر چند کانتینر اجرا می‌کنید، باید هر کدام را جداگانه لینک کنید.

## امنیت

- **پشتیبان‌گیری امن**: کلیدهای هویت نود با دسترسی محدود (600) ذخیره می‌شوند
- **بدون تلمتری**: هیچ داده‌ای جمع‌آوری یا ارسال نمی‌شود
- **ردیابی محلی**: آمار ترافیک فقط به صورت محلی ذخیره شده و هرگز ارسال نمی‌شود
- **تلگرام اختیاری**: اعلان‌های ربات کاملاً اختیاری هستند و در صورت غیرفعال بودن هیچ منبعی مصرف نمی‌شود

</div>

---

## License

MIT License

## Contributing

Pull requests welcome. For major changes, open an issue first.

## Links

- [Psiphon](https://psiphon.ca/)
- [Psiphon Conduit](https://github.com/Psiphon-Inc/conduit)
