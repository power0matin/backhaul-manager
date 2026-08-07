<div align="center">

# Backhaul Manager

**نصب و مدیریت امن و تعاملی [power0matin/Backhaul](https://github.com/power0matin/Backhaul) و [Musixal/Backhaul](https://github.com/Musixal/Backhaul)**

یک اسکریپت برای هر دو سمت ایران و خارج، همراه با Profile، مهاجرت بین forkها، بکاپ کامل، Health/Metrics، rollback و مدیریت سرویس.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash%205%2B-4EAA25?logo=gnu-bash&logoColor=white)](#پیشنیازها)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20systemd-lightgrey)](#پیشنیازها)
[![Transports](https://img.shields.io/badge/transports-7-informational)](#ترنسپورتها)

[English](./README.md) • [فارسی](./README.fa.md)

</div>

---

Backhaul Manager برای تانل معکوس در کنار Xray، V2Ray، Marzban، 3x-ui/Sanaei، Hiddify و سرویس‌های مشابه طراحی شده است. هدف این نسخه این است که تنظیم دو سمت تانل سریع باشد، ولی خطاهای رایجی مثل TOML خراب، پورت نامعتبر، transport ناهماهنگ، نگهداری ناامن token، آپدیت ناقص و تنظیم دستی systemd اتفاق نیفتد.

## امکانات

| قابلیت | توضیح |
| --- | --- |
| 🔁 **هر دو سمت با یک اسکریپت** | همان فایل هم سرور ایران و هم کلاینت خارج را تنظیم می‌کند |
| 📦 **انتخاب منبع Backhaul** | هنگام setup با شماره بین `power0matin/Backhaul` (پیشنهادی) و upstream رسمی `Musixal/Backhaul` انتخاب می‌کنید |
| 🔄 **مهاجرت بین sourceها** | همه Profileها را با compatibility check، جلوگیری از downgrade ناخواسته، backup، verify و rollback بین PowerMatin و Musixal مهاجرت می‌دهد |
| 🚚 **تمام transportهای رسمی** | `tcp`، `tcpmux`، `udp`، `ws`، `wss`، `wsmux` و `wssmux`؛ انتخاب پیشنهادی همچنان `wsmux` است |
| 🎛️ **Standard و Advanced** | Advanced شامل port range/mapping، Auto tuning، PROXY protocol، UDP روی TCP و optionهای مخصوص هر fork است |
| 🧩 **Profileهای نام‌گذاری‌شده** | چند config/service مستقل مثل `backhaul-edge-1.service` را با یک binary/source مشترک اجرا می‌کند |
| ✅ **اعتبارسنجی ورودی‌ها** | پورت، نسخه، IP/hostname، transport و فایل‌های لازم قبل از هر تغییری بررسی می‌شوند |
| 🔐 **مدیریت امن‌تر secret** | token امن ۴۸ کاراکتری تولید می‌شود، ورودی token روی صفحه echo نمی‌شود، مقادیر TOML escape می‌شوند و token وارد run log نمی‌شود |
| 🛡️ **تغییرات تراکنشی** | قبل از تغییر از config/unit/binary بکاپ گرفته می‌شود؛ فایل‌ها atomic جایگزین می‌شوند و در صورت fail شدن سرویس rollback انجام می‌شود |
| ⬆️ **آپدیت امن چند-Profile** | کل نصب قبل از Upgrade snapshot می‌شود، تمام Profileهای قبلاً فعال verify می‌شوند و در صورت خطا کل وضعیت rollback می‌شود |
| 💾 **Backup و مهاجرت سرور** | بکاپ checksummed، import/export امن و مهاجرت SSH شامل Profileها، service state، binary، source و TLS قابل‌خواندن است |
| 🩺 **Health و Metrics** | Status، Diagnostics، منابع systemd، restart counter، `/stats` امن PowerMatin و لاگ‌ها داخل Manager هستند |
| 🛠️ **دستور سراسری Manager** | Manager را با downgrade guard به‌صورت `backhaul-manager` در `/usr/local/sbin` نصب/آپدیت می‌کند |
| 🧹 **پاک‌سازی کنترل‌شده سرویس‌های قدیمی** | فقط سرویس‌های مشکوک به ابزارهای تانل پیشنهاد می‌شوند و قبل از disable شدن تأیید جدا گرفته می‌شود |
| 🔥 **آگاه از فایروال** | `ufw` و `firewalld` را تشخیص می‌دهد و دستور لازم را نشان می‌دهد؛ خودش قانون فایروال را تغییر نمی‌دهد |
| 🌐 **IPv4 / IPv6 / hostname** | آدرس سرور ایران می‌تواند IPv4، IPv6 یا hostname باشد؛ transportهای WebSocket از edge/CDN اختیاری هم پشتیبانی می‌کنند |
| 🧯 **Uninstall امن‌تر** | ابتدا سرویس و binary حذف می‌شوند؛ حذف دائمی config، credential و backup تأیید جداگانه می‌خواهد |
| 🤖 **دستورات CLI** | کارهای مدیریتی رایج بدون باز کردن منوی تعاملی هم قابل اجرا هستند |

## پیش‌نیازها

- لینوکس با `systemd`
- Bash 5 یا جدیدتر
- معماری `x86_64`/AMD64 یا `arm64`/AArch64
- دسترسی root برای نصب و مدیریت سرویس
- `curl`، `tar`، `systemctl`، `journalctl`، `ss`، `awk`، `grep`، `sed` و ابزارهای استاندارد GNU/coreutils
- `nc`/netcat اختیاری است و فقط برای تست دسترسی سمت کلاینت استفاده می‌شود
- `ssh` و `scp` اختیاری هستند و فقط برای مهاجرت مستقیم سروربه‌سرور لازم‌اند؛ port/key سفارشی SSH را در `~/.ssh/config` تنظیم کنید
- `jq` اختیاری است و در صورت نصب، خروجی `/stats` نسخه PowerMatin را خواناتر نمایش می‌دهد
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
  7) Backhaul maintenance
  8) Profiles
  9) Backup & migration
 10) Health & logs
 11) Manager install / update
 12) Uninstall / purge
  0) Exit
```

اجرای دوباره گزینه ۱ یا ۲ روی نصب فعلی امن است: قبل از تغییر snapshot گرفته می‌شود، فایل جدید به‌صورت atomic جایگزین می‌شود و اگر سرویس با تنظیم جدید بالا نیاید، وضعیت قبلی restore می‌شود.

هنگام تنظیم سرور یا کلاینت، منبع release موردنظر Backhaul را با شماره انتخاب کنید. زدن Enter گزینه پیشنهادی را انتخاب می‌کند:

```text
Backhaul source:
  1) power0matin/Backhaul [recommended]
  2) Musixal/Backhaul [official upstream]
Source [1]:
```

منبع انتخاب‌شده در state نصب ذخیره می‌شود، در Status نمایش داده می‌شود و Upgradeهای بعدی نیز از همان repository انجام می‌شوند. چون همه Profileها یک binary مشترک دارند، تغییر source/version یک عملیات سراسری برای کل نصب است.

## ترنسپورت‌ها

گزینه‌ها با transport typeهای فعلی خود Backhaul هماهنگ هستند:

| Transport | کاربرد | ورودی اضافه در سمت سرور |
| --- | --- | --- |
| `wsmux` | WebSocket multiplex شده؛ انتخاب عمومی پیشنهادی | ندارد |
| `tcpmux` | TCP multiplex شده | ندارد |
| `tcp` | TCP ساده | ندارد |
| `ws` | WebSocket | ندارد |
| `wssmux` | WebSocket multiplex شده با TLS | certificate + private key |
| `wss` | WebSocket با TLS | certificate + private key |
| `udp` | UDP transport | ندارد |

در Standard Mode لیست مستقیم پورت‌ها مثل `443,2052,2082` گرفته می‌شود. Advanced Mode از ruleهایی مثل `4000-4100`، `4000=5000`، `443=127.0.0.1:8443` و mapping به IPv6 براکت‌دار پشتیبانی می‌کند و برخورد با control port را بررسی می‌کند.

برای `ws`، `wss`، `wsmux` و `wssmux` در سمت کلاینت می‌توانید مقدار اختیاری `edge_ip` را هم مشخص کنید.

## Advanced Mode و Auto-Tuning

Standard Mode با تنظیمات محافظه‌کارانه برای اکثر سرورها پیشنهاد می‌شود. در Advanced Mode سه tuning profile با نام‌های `safe`، `balanced` و `throughput` وجود دارد؛ گزینه Auto با توجه به تعداد CPU و RAM یکی را پیشنهاد می‌دهد.

Manager فقط optionهایی را می‌نویسد که برای source انتخابی شناخته شده‌اند. تنظیمات bounded pool/UDP queue و metrics احراز هویت‌شده مخصوص PowerMatin هرگز وارد config مربوط به Musixal نمی‌شوند. Web monitor نسخه Musixal v0.7.2 عمداً خاموش می‌ماند چون در آن نسخه bind امن loopback/auth قابل تنظیم نیست. در PowerMatin، metrics فقط روی `127.0.0.1` و با credential معتبر فعال می‌شود.

## Profile، Backup و Migration

- Profile پیش‌فرض برای سازگاری با نسخه‌های قبلی همان `/root/backhaul/config.toml` و `backhaul.service` است.
- Profileهای نام‌دار در `/root/backhaul/profiles/<name>/` هستند و سرویسی مثل `backhaul-<name>.service` دارند.
- از منوی Profiles می‌توانید Create، Select، Clone و Delete انجام دهید. هنگام clone یک Profile دارای TLS، cert/key داخل Profile جدید کپی می‌شود تا به Profile مبدا وابسته نماند.
- Full Backup همه Profileها، active/enabled state سرویس‌ها، binary/source مشترک و TLS قابل‌خواندن را ذخیره می‌کند. `CHECKSUMS` خرابی تصادفی داده را تشخیص می‌دهد.
- Import فایل `.tar.gz` قبل از extract با دسترسی root، path traversal، link/device، تعداد بیش‌ازحد member، حجم فایل، حجم فشرده و حجم کل extract‌شده را محدود می‌کند. Bundle شامل secret است و امضای دیجیتال ندارد؛ فقط bundle مورد اعتماد خودتان را import کنید.
- مهاجرت سروربه‌سرور همان bundle را روی SSH منتقل می‌کند، permission مقصد را `0600` می‌کند و در صورت تأیید restore را روی سرور مقصد اجرا می‌کند.
- مهاجرت source همه Profileها را قبل از تغییر binary بررسی می‌کند. در PowerMatin → Musixal فقط keyهای شناخته‌شده مخصوص fork با تأیید شما حذف می‌شوند و metrics ناامن Musixal خاموش می‌شود. Downgrade همیشه تأیید تعاملی جدا می‌خواهد.

## دستورات مستقیم CLI

برای کارهای روزمره لازم نیست وارد منو شوید:

```bash
sudo ./backhaul-manager.sh --status
sudo ./backhaul-manager.sh --diagnose
sudo ./backhaul-manager.sh --metrics
sudo ./backhaul-manager.sh --profile edge-1 --status
sudo ./backhaul-manager.sh --restart
sudo ./backhaul-manager.sh --start
sudo ./backhaul-manager.sh --stop
sudo ./backhaul-manager.sh --upgrade
sudo ./backhaul-manager.sh --migrate-source Musixal/Backhaul
sudo ./backhaul-manager.sh --compat power0matin/Backhaul
sudo ./backhaul-manager.sh --list-profiles
sudo ./backhaul-manager.sh --select-profile edge-1
sudo ./backhaul-manager.sh --backup
sudo ./backhaul-manager.sh --list-backups
sudo ./backhaul-manager.sh --export /root/backhaul-portable.tar.gz
sudo ./backhaul-manager.sh --import /root/backhaul-portable.tar.gz
sudo ./backhaul-manager.sh --restore-backup backup-YYYYMMDD-HHMMSS-label-PID
sudo ./backhaul-manager.sh --self-update
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs
./backhaul-manager.sh --version
./backhaul-manager.sh --help
```

`--upgrade` به‌صورت پیش‌فرض آخرین release همان source ذخیره‌شده را می‌گیرد و tag دقیق هم قابل استفاده است. `--migrate-source` در حالت non-interactive عمداً downgrade و config نیازمند adaptation را رد می‌کند؛ برای تأیید آگاهانه این دو مورد از Migration داخل منو استفاده کنید. نصب‌های قدیمی بدون source state به‌عنوان Musixal در نظر گرفته می‌شوند.

## فایل‌ها و بکاپ‌ها

| مسیر | کاربرد |
| --- | --- |
| `/opt/backhaul/backhaul` | binary نصب‌شده Backhaul |
| `/root/backhaul/config.toml` | کانفیگ فعال با permission برابر `0600` |
| `/root/backhaul/backhaul-info.txt` | خلاصه اطلاعات اتصال و setup با `0600` |
| `/root/backhaul/profiles/<name>/config.toml` | config مربوط به Profile نام‌دار با `0600` |
| `/etc/systemd/system/backhaul.service` | سرویس systemd |
| `/etc/systemd/system/backhaul-<name>.service` | سرویس systemd مربوط به Profile نام‌دار |
| `/var/lib/backhaul-manager/backups/` | snapshotهای زمان‌دار برای rollback |
| `/var/lib/backhaul-manager/backhaul-source` | repository انتخاب‌شده برای releaseهای Backhaul |
| `/var/lib/backhaul-manager/active-profile` | Profile انتخاب‌شده فعلی |
| `/var/log/backhaul-manager/` | run logهای Manager با `0600` |
| `/usr/local/sbin/backhaul-manager` | دستور سراسری اختیاری Manager |

Web monitor در Standard Mode خاموش است (`web_port = 0`). در Advanced Mode نسخه PowerMatin می‌تواند آن را به‌صورت loopback-only و با authentication فعال کند.

## مدل امنیت و پایداری

- دایرکتوری‌های نصب قبل از نوشتن config ساخته می‌شوند؛ بنابراین نصب fresh به‌خاطر نبودن `/root/backhaul` fail نمی‌شود.
- تولید token از pipelineای که با `set -o pipefail` و broken pipe مشکل ایجاد کند استفاده نمی‌کند.
- token سفارشی بدون echo روی terminal گرفته و قبل از ذخیره برای TOML escape می‌شود.
- token فقط روی TTY و داخل فایل‌های root-only نمایش/ذخیره می‌شود و وارد manager run log نمی‌شود.
- دانلود release با HTTPS انجام می‌شود؛ ساختار gzip/tar بررسی، فقط عضو مورد انتظار `backhaul` extract، خروجی `-v` binary validate و برای نسخه pinned تطبیق tag بررسی می‌شود.
- جایگزینی binary و config با temporary file و `mv` انجام می‌شود تا فایل نصفه نوشته نشود.
- اگر configure/start fail شود، config، systemd unit، binary و وضعیت فعال/enabled قبلی تا حد ممکن restore می‌شوند.
- Upgrade و source migration از کل Profileها snapshot می‌گیرند و فقط وقتی موفق اعلام می‌شوند که همه سرویس‌هایی که قبلاً active بودند دوباره verify شوند.
- Portable restore ابتدا درخت backup و checksumها را validate می‌کند و systemd unit را از template خود Manager دوباره می‌سازد؛ unit داخل archive کورکورانه اجرا نمی‌شود.
- Import قبل از extract با root، نوع member، مسیر، تعداد، اندازه هر فایل، حجم فشرده و مجموع حجم extract‌شده را محدود می‌کند.
- Self-update فقط اسکریپت `main` همان repository را روی HTTPS می‌گیرد، حجم را محدود می‌کند، Bash syntax و یک version declaration معتبر را بررسی و downgrade را رد می‌کند. این مکانیزم امضای رمزنگاری‌شده مستقل ندارد.
- Uninstall به‌صورت پیش‌فرض config و backup را نگه می‌دارد و purge کامل تأیید دوم می‌خواهد.
- اسکریپت هیچ قانون فایروالی را خودکار تغییر نمی‌دهد.

## پیش‌فرض‌های کانفیگ

| تنظیم | پیش‌فرض |
| --- | --- |
| Control port | `8080` |
| Tunnel ports | `2052,2082,8002,443` |
| Transport | `wsmux` |
| منبع Backhaul | `power0matin/Backhaul` (پیشنهادی) |
| `keepalive_period` | `20` برای transportهای غیر UDP |
| `heartbeat` سمت سرور | `20` |
| `channel_size` | `2048` |
| `connection_pool` | `8` |
| `mux_con` | `8` برای mux سمت سرور |
| `mux_version` | `1` برای mux |
| `web_port` | `0` (خاموش) |
| `log_level` | `info` |

در Advanced Mode مقادیر channel/pool/mux بر اساس tuning profile تغییر می‌کنند: `safe` برای مصرف کمتر منابع، `balanced` مطابق defaultهای بالا و `throughput` برای hostهای قوی‌تر و concurrency بیشتر است.

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
- [x] پشتیبانی first-class از ruleهای پیشرفته range و port mapping
- [x] Standard/Advanced Mode همراه با Auto tuning منابع
- [x] چند Profile/service نام‌گذاری‌شده روی یک سرور
- [x] مهاجرت transactional بین PowerMatin و Musixal همراه compatibility check
- [x] Full backup/restore، import/export portable و مهاجرت SSH به سرور دیگر
- [x] Health metrics و `/stats` امن PowerMatin
- [x] نصب و Self-update دستور سراسری Manager
- [ ] flagهای کاملاً non-interactive برای ساخت server/client

## مشارکت

Issue و Pull Request خوش‌آمدند. برای تغییرات بزرگ بهتر است اول Issue باز شود تا رفتار Manager با مدل config نسخه فعلی Backhaul هماهنگ بماند. تاریخچه تغییرات در [CHANGELOG.md](./CHANGELOG.md) است.

## مجوز

MIT — فایل [LICENSE](./LICENSE) را ببینید. خود Backhaul یک پروژه upstream جدا با مجوز خودش است.
