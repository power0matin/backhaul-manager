<div align="center">

# Backhaul Manager

**نصب و مدیریت امن و تعاملی [Musixal/Backhaul](https://github.com/Musixal/Backhaul)**

یک اسکریپت برای هر دو سمت ایران و خارج، همراه با نصب، آپدیت، عیب‌یابی، لاگ، rollback و مدیریت سرویس.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash%205%2B-4EAA25?logo=gnu-bash&logoColor=white)](#پیشنیازها)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20systemd-lightgrey)](#پیشنیازها)
[![Transports](https://img.shields.io/badge/transports-7-informational)](#ترنسپورتها)

[English](./README.md) • [فارسی](./README.fa.md)

</div>

---

Backhaul Manager برای تانل معکوس در کنار Xray، V2Ray، Marzban، 3x-ui/Sanaei، Hiddify و سرویس‌های مشابه طراحی شده است. هدف این نسخه این است که تنظیم دو سمت تانل سریع باشد، ولی خطاهای رایجی مثل TOML خراب، پورت نامعتبر، transport ناهماهنگ، نگهداری ناامن token، آپدیت ناقص و تنظیم دستی systemd اتفاق نیفتد.

## امکانات

| قابلیت                                    | توضیح                                                                                                                               |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 🔁 **هر دو سمت با یک اسکریپت**            | همان فایل هم سرور ایران و هم کلاینت خارج را تنظیم می‌کند                                                                            |
| 🚚 **تمام transportهای رسمی**             | `tcp`، `tcpmux`، `udp`، `ws`، `wss`، `wsmux` و `wssmux`؛ انتخاب پیشنهادی همچنان `wsmux` است                                         |
| ✅ **اعتبارسنجی ورودی‌ها**                | پورت، نسخه، IP/hostname، transport و فایل‌های لازم قبل از هر تغییری بررسی می‌شوند                                                   |
| 🔐 **مدیریت امن‌تر secret**               | token امن ۴۸ کاراکتری تولید می‌شود، ورودی token روی صفحه echo نمی‌شود، مقادیر TOML escape می‌شوند و token وارد run log نمی‌شود      |
| 🛡️ **تغییرات تراکنشی**                    | قبل از تغییر از config/unit/binary بکاپ گرفته می‌شود؛ فایل‌ها atomic جایگزین می‌شوند و در صورت fail شدن سرویس rollback انجام می‌شود |
| ⬆️ **آپدیت امن**                          | asset مناسب معماری دانلود و بررسی می‌شود، نسخه binary چک می‌شود و در صورت خراب شدن آپدیت، binary قبلی برمی‌گردد                     |
| 🩺 **ابزار مدیریت روزمره**                | Status، Diagnostics، Start/Stop/Restart، لاگ اخیر، لاگ زنده و Upgrade داخل خود Manager هستند                                        |
| 🧹 **پاک‌سازی کنترل‌شده سرویس‌های قدیمی** | فقط سرویس‌های مشکوک به ابزارهای تانل پیشنهاد می‌شوند و قبل از disable شدن تأیید جدا گرفته می‌شود                                    |
| 🔥 **آگاه از فایروال**                    | `ufw` و `firewalld` را تشخیص می‌دهد و دستور لازم را نشان می‌دهد؛ خودش قانون فایروال را تغییر نمی‌دهد                                |
| 🌐 **IPv4 / IPv6 / hostname**             | آدرس سرور ایران می‌تواند IPv4، IPv6 یا hostname باشد؛ transportهای WebSocket از edge/CDN اختیاری هم پشتیبانی می‌کنند                |
| 🧯 **Uninstall امن‌تر**                   | ابتدا سرویس و binary حذف می‌شوند؛ حذف دائمی config، credential و backup تأیید جداگانه می‌خواهد                                      |
| 🤖 **دستورات CLI**                        | کارهای مدیریتی رایج بدون باز کردن منوی تعاملی هم قابل اجرا هستند                                                                    |

## پیش‌نیازها

- لینوکس با `systemd`
- Bash 5 یا جدیدتر
- معماری `x86_64`/AMD64 یا `arm64`/AArch64
- دسترسی root برای نصب و مدیریت سرویس
- `curl`، `tar`، `systemctl`، `journalctl`، `ss`، `awk`، `grep`، `sed` و ابزارهای استاندارد GNU/coreutils
- `nc`/netcat اختیاری است و فقط برای تست دسترسی سمت کلاینت استفاده می‌شود
- برای `wss` و `wssmux` باید certificate و private key از قبل روی سرور وجود داشته باشند

## اجرای سریع

اگر با کاربر `root` وارد سرور شده‌اید، فقط همین یک دستور کافی است:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh)
```

اگر root نیستید:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh | sudo bash
```

`-f` اجازه نمی‌دهد پاسخ HTTP ناموفق به Bash داده شود، `-sS` خروجی عادی curl را مخفی ولی خطا را نمایش می‌دهد و `-L` redirectهای GitHub را دنبال می‌کند.

> `sudo` را مستقیم قبل از فرم process substitution نگذارید (`sudo bash <(curl ...)`)؛ ممکن است `/dev/fd/...` توسط sudo بسته شود. وقتی نیاز به sudo دارید از فرم pipe بالا استفاده کنید.

برای بررسی فایل قبل از اجرا:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh -o backhaul-manager.sh
chmod +x backhaul-manager.sh
sudo ./backhaul-manager.sh
```

## منوی مدیریتی

```text
  1) Configure Iran server
  2) Configure foreign client
  3) Status
  4) Diagnostics
  5) Restart service
  6) Start / stop service
  7) Upgrade Backhaul
  8) Recent logs
  9) Follow live logs
 10) Uninstall / purge
  0) Exit
```

اجرای دوباره گزینه ۱ یا ۲ روی نصب فعلی امن است: قبل از تغییر snapshot گرفته می‌شود، فایل جدید به‌صورت atomic جایگزین می‌شود و اگر سرویس با تنظیم جدید بالا نیاید، وضعیت قبلی restore می‌شود.

## ترنسپورت‌ها

گزینه‌ها با transport typeهای فعلی خود Backhaul هماهنگ هستند:

| Transport | کاربرد                                         | ورودی اضافه در سمت سرور   |
| --------- | ---------------------------------------------- | ------------------------- |
| `wsmux`   | WebSocket multiplex شده؛ انتخاب عمومی پیشنهادی | ندارد                     |
| `tcpmux`  | TCP multiplex شده                              | ندارد                     |
| `tcp`     | TCP ساده                                       | ندارد                     |
| `ws`      | WebSocket                                      | ندارد                     |
| `wssmux`  | WebSocket multiplex شده با TLS                 | certificate + private key |
| `wss`     | WebSocket با TLS                               | certificate + private key |
| `udp`     | UDP transport                                  | ندارد                     |

در حال حاضر Manager لیست مستقیم پورت‌ها مثل `443,2052,2082` را می‌گیرد. ruleهای پیشرفته range/mapping که Backhaul پشتیبانی می‌کند همچنان می‌توانند مستقیماً در `config.toml` تنظیم شوند.

برای `ws`، `wss`، `wsmux` و `wssmux` در سمت کلاینت می‌توانید مقدار اختیاری `edge_ip` را هم مشخص کنید.

## دستورات مستقیم CLI

برای کارهای روزمره لازم نیست وارد منو شوید:

```bash
sudo ./backhaul-manager.sh --status
sudo ./backhaul-manager.sh --diagnose
sudo ./backhaul-manager.sh --restart
sudo ./backhaul-manager.sh --start
sudo ./backhaul-manager.sh --stop
sudo ./backhaul-manager.sh --upgrade
sudo ./backhaul-manager.sh --upgrade v0.7.2
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs
./backhaul-manager.sh --version
./backhaul-manager.sh --help
```

`--upgrade` به‌صورت پیش‌فرض آخرین release رسمی Backhaul را می‌گیرد. برای reproducible بودن می‌توانید tag دقیق نسخه را مشخص کنید.

## فایل‌ها و بکاپ‌ها

| مسیر                                   | کاربرد                                 |
| -------------------------------------- | -------------------------------------- |
| `/opt/backhaul/backhaul`               | binary نصب‌شده Backhaul                |
| `/root/backhaul/config.toml`           | کانفیگ فعال با permission برابر `0600` |
| `/root/backhaul/backhaul-info.txt`     | خلاصه اطلاعات اتصال و setup با `0600`  |
| `/etc/systemd/system/backhaul.service` | سرویس systemd                          |
| `/var/lib/backhaul-manager/backups/`   | snapshotهای زمان‌دار برای rollback     |
| `/var/log/backhaul-manager/`           | run logهای Manager با `0600`           |

Web dashboard خود Backhaul به‌صورت پیش‌فرض خاموش است (`web_port = 0`) تا سرویس اضافه‌ای ناخواسته روی شبکه expose نشود. اگر واقعاً نیاز دارید، آن را آگاهانه در config فعال کنید.

## مدل امنیت و پایداری

- دایرکتوری‌های نصب قبل از نوشتن config ساخته می‌شوند؛ بنابراین نصب fresh به‌خاطر نبودن `/root/backhaul` fail نمی‌شود.
- تولید token از pipelineای که با `set -o pipefail` و broken pipe مشکل ایجاد کند استفاده نمی‌کند.
- token سفارشی بدون echo روی terminal گرفته و قبل از ذخیره برای TOML escape می‌شود.
- token فقط روی TTY و داخل فایل‌های root-only نمایش/ذخیره می‌شود و وارد manager run log نمی‌شود.
- دانلود release با HTTPS انجام می‌شود؛ ساختار gzip/tar بررسی، فقط عضو مورد انتظار `backhaul` extract، خروجی `-v` binary validate و برای نسخه pinned تطبیق tag بررسی می‌شود.
- جایگزینی binary و config با temporary file و `mv` انجام می‌شود تا فایل نصفه نوشته نشود.
- اگر configure/start fail شود، config، systemd unit، binary و وضعیت فعال/enabled قبلی تا حد ممکن restore می‌شوند.
- Uninstall به‌صورت پیش‌فرض config و backup را نگه می‌دارد و purge کامل تأیید دوم می‌خواهد.
- اسکریپت هیچ قانون فایروالی را خودکار تغییر نمی‌دهد.

## پیش‌فرض‌های کانفیگ

| تنظیم                | پیش‌فرض                        |
| -------------------- | ------------------------------ |
| Control port         | `8080`                         |
| Tunnel ports         | `2052,2082,8002,443`           |
| Transport            | `wsmux`                        |
| `keepalive_period`   | `20` برای transportهای غیر UDP |
| `heartbeat` سمت سرور | `20`                           |
| `channel_size`       | `2048`                         |
| `connection_pool`    | `8`                            |
| `mux_con`            | `8` برای mux سمت سرور          |
| `mux_version`        | `1` برای mux                   |
| `web_port`           | `0` (خاموش)                    |
| `log_level`          | `info`                         |

در config کلاینت عمداً `heartbeat` نوشته نمی‌شود، چون `ClientConfig` فعلی Backhaul چنین فیلدی ندارد.

## رفع مشکل

اول health check داخلی را اجرا کنید:

```bash
sudo ./backhaul-manager.sh --diagnose
```

اگر لازم بود لاگ را ببینید:

```bash
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs
```

موارد رایج:

- control port در فایروال/security group سرور ایران بسته است؛
- پردازش دیگری یکی از پورت‌های انتخابی را گرفته؛
- token، transport یا control port در دو سمت یکی نیست؛
- مسیر certificate/private key برای TLS اشتباه یا غیرقابل خواندن است؛
- برای tag یا معماری انتخاب‌شده asset رسمی Backhaul وجود ندارد.

## توسعه و تست

```bash
bash -n backhaul-manager.sh tests/test.sh
shellcheck backhaul-manager.sh tests/test.sh
bash tests/test.sh
```

GitHub Actions همین syntax check، ShellCheck و helper testها را روی push و pull request اجرا می‌کند.

## نقشه راه

- [x] هر هفت transport فعلی Backhaul
- [x] تولید امن token و محافظت از secret
- [x] تغییرات transactional و rollback
- [x] Status، Diagnostics، Log، Service control و Upgrade
- [x] دستورات CLI مدیریتی
- [x] تست خودکار syntax/lint/helper
- [ ] پشتیبانی first-class از ruleهای پیشرفته range و port mapping
- [ ] flagهای کاملاً non-interactive برای ساخت server/client
- [ ] چند profile/service نام‌گذاری‌شده روی یک سرور

## مشارکت

Issue و Pull Request خوش‌آمدند. برای تغییرات بزرگ بهتر است اول Issue باز شود تا رفتار Manager با مدل config نسخه فعلی Backhaul هماهنگ بماند. تاریخچه تغییرات در [CHANGELOG.md](./CHANGELOG.md) است.

## مجوز

MIT — فایل [LICENSE](./LICENSE) را ببینید. خود Backhaul یک پروژه upstream جدا با مجوز خودش است.
