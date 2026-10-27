<div align="center">

# Backhaul Manager

<p><strong>ابزار تعاملی نصب و مدیریت عملیاتی تانل‌های معکوس Backhaul</strong></p>

<p>
  <a href="https://github.com/power0matin/backhaul-manager/actions/workflows/shell.yml"><img src="https://github.com/power0matin/backhaul-manager/actions/workflows/shell.yml/badge.svg?branch=main" alt="Shell checks"></a>
  <a href="https://github.com/power0matin/backhaul-manager/blob/main/LICENSE"><img src="https://img.shields.io/github/license/power0matin/backhaul-manager?style=flat-square" alt="مجوز MIT"></a>
  <img src="https://img.shields.io/badge/shell-Bash%205%2B-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white" alt="Bash 5 یا جدیدتر">
  <img src="https://img.shields.io/badge/platform-Linux%20%7C%20systemd-lightgrey?style=flat-square" alt="Linux و systemd">
  <img src="https://img.shields.io/badge/transports-7-informational?style=flat-square" alt="هفت transport">
</p>

<p>
  <a href="https://matinshahabadi.ir/projects/backhaul-manager/">صفحه رسمی پروژه</a> ·
  نگه‌دارنده: <a href="https://github.com/power0matin">@power0matin</a> ·
  <a href="./README.md">English</a> ·
  <a href="./README.fa.md">فارسی</a>
</p>

</div>

<div align="center">
  <a href="./imgs/preview_v3.2.1.png">
    <img
      src="./imgs/preview_v3.2.1.png"
      alt="پیش‌نمایش رابط کاربری Backhaul Manager نسخه 3.2.1"
      width="1100"
    />
  </a>
  <p><sub>پیش‌نمایش رابط کاربری Backhaul Manager نسخه 3.2.1 · برای مشاهده در اندازه کامل روی تصویر کلیک کنید</sub></p>
</div>

Backhaul Manager هر دو سمت یک تانل معکوس Backhaul را تنظیم و مدیریت می‌کند: سرور سمت ایران و کلاینت سمت خارج. این ابزار نصب مرحله‌به‌مرحله، Profileهای نام‌گذاری‌شده، مهاجرت بین sourceها، بکاپ اعتبارسنجی‌شده، بررسی سلامت، rollback و عملیات خط فرمان را به binary اصلی Backhaul اضافه می‌کند.

این پروژه از [`power0matin/Backhaul`](https://github.com/power0matin/Backhaul) و نسخه بالادستی [`Musixal/Backhaul`](https://github.com/Musixal/Backhaul) پشتیبانی می‌کند. می‌توان آن را در کنار Xray، V2Ray، Marzban، 3x-ui/Sanaei، Hiddify و ابزارهای مشابه به کار برد، اما **خود این Manager تنظیمات آن برنامه‌ها را انجام نمی‌دهد**.

> **نکته امنیتی:** برای نصب و مدیریت سرویس به دسترسی root نیاز است. پیش از اجرای کد دانلودشده با دسترسی root، اسکریپت را بررسی کنید. دستور نصب سریع نسخه فعلی شاخه `main` را می‌گیرد؛ این مسیر یک Release ثابت یا کانال به‌روزرسانی دارای امضای رمزنگاری‌شده نیست. Manager هیچ قانون فایروالی را خودکار تغییر نمی‌دهد.

## فهرست

- [امکانات](#امکانات)
- [پیش‌نیازها](#پیشنیازها)
- [شروع سریع](#شروع-سریع)
- [روند راه‌اندازی](#روند-راهاندازی)
- [Transportهای پشتیبانی‌شده](#transportهای-پشتیبانیشده)
- [آزمون اتصال پیش از ساخت تانل](#آزمون-اتصال-پیش-از-ساخت-تانل)
- [Profile، بکاپ و مهاجرت](#profile-بکاپ-و-مهاجرت)
- [دستورات خط فرمان](#دستورات-خط-فرمان)
- [فایل‌ها و مقادیر پیش‌فرض](#فایلها-و-مقادیر-پیشفرض)
- [امنیت و محدودیت‌های عملیاتی](#امنیت-و-محدودیتهای-عملیاتی)
- [رفع مشکل](#رفع-مشکل)
- [توسعه و تست](#توسعه-و-تست)
- [نقشه راه](#نقشه-راه)
- [مشارکت و مجوز](#مشارکت-و-مجوز)

## امکانات

| بخش                                 | قابلیت                                                                                                                             |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **هر دو سمت تانل**                  | تنظیم سرور سمت ایران یا کلاینت سمت خارج با یک اسکریپت.                                                                             |
| **انتخاب source مربوط به Backhaul** | انتخاب `power0matin/Backhaul` به‌عنوان گزینه پیشنهادی یا `Musixal/Backhaul` هنگام setup.                                           |
| **هفت transport**                   | پشتیبانی از `tcp`، `tcpmux`، `udp`، `ws`، `wss`، `wsmux` و `wssmux`. گزینه عمومی پیشنهادی `wsmux` است؛ مسیر خودتان را آزمایش کنید. |
| **حالت Standard و Advanced**        | تنظیم port range و mapping، تنظیم منابع، PROXY protocol، انتقال UDP روی تانل و گزینه‌های مختص هر source.                           |
| **Profileهای نام‌گذاری‌شده**        | اجرای config و سرویس مستقل، مثل `backhaul-edge-1.service`، با یک Backhaul binary و source مشترک.                                   |
| **آزمون اتصال پیش از تانل**         | تست همه transportها، یک control port و transport مشخص، یا فقط دسترسی TCP پیش از راه‌اندازی تانل.                                   |
| **تغییرات تراکنشی**                 | اعتبارسنجی ورودی، snapshot، نوشتن اتمیک فایل‌ها، بررسی سلامت سرویس و تلاش برای rollback پس از شکست config یا upgrade.              |
| **Upgrade و مهاجرت چند-Profile**    | بررسی سازگاری، جلوگیری از downgrade تأییدنشده، بررسی Profileهای فعال قبلی و rollback در صورت خطا.                                  |
| **بکاپ و مهاجرت سرور**              | بکاپ با checksum، import/export آرشیو قابل‌انتقال و مهاجرت نصب مدیریت‌شده از طریق SSH.                                             |
| **Health و Metrics**                | بررسی وضعیت سرویس، PID فعلی، listener و control channel، لاگ‌ها، اطلاعات restart و metrics پشتیبانی‌شده.                           |
| **مدیریت امن‌تر secret**            | تولید token تصادفی رمزنگارانه، مخفی‌کردن ورودی token، escape کردن مقادیر TOML و محدودکردن دسترسی فایل‌های حساس.                    |
| **جلوگیری از عملیات هم‌زمان**       | استفاده از `flock` برای جلوگیری از تغییر هم‌زمان state مشترک توسط چند session.                                                     |
| **راهنمایی سازگار با فایروال**      | تشخیص `ufw` یا `firewalld` و نمایش پورت‌ها و فرمان‌های موردنیاز، بدون دست‌کاری policy فایروال.                                     |
| **مدیریت با CLI**                   | اجرای status، diagnostics، عملیات سرویس، بکاپ، Profile، upgrade و migration بدون منوی تعاملی.                                      |

## پیش‌نیازها

- لینوکس با `systemd` فعال به‌عنوان PID 1.
- Bash نسخه 5 یا جدیدتر.
- معماری `x86_64`/AMD64 یا `arm64`/AArch64.
- دسترسی root برای نصب و مدیریت سرویس.
- ابزارهای استاندارد سیستم از جمله `curl`، `tar`، `flock`، `systemctl`، `journalctl`، `ss`، `awk`، `grep`، `sed`، `sha256sum` و ابزارهای GNU/coreutils.
- **برای Link Test:** وجود `python3` و `openssl` برای آزمون کامل لازم است.
- `nc`/netcat اختیاری است و برای بخشی از بررسی‌های دسترسی سمت کلاینت استفاده می‌شود.
- `ssh` و `scp` اختیاری هستند و فقط برای مهاجرت راهنمایی‌شده سروربه‌سرور لازم‌اند. پورت و کلید SSH سفارشی را در `~/.ssh/config` تنظیم کنید.
- `jq` اختیاری است و خروجی `/stats` نسخه PowerMatin را خواناتر می‌کند.
- برای transportهای عملیاتی `wss` و `wssmux` باید certificate و private key روی سرور موجود باشند.

Manager ابزارهای اجباری را بررسی می‌کند و در صورت نبود dependency ضروری با خطا خارج می‌شود. برای Debian/Ubuntu، پیام خطای آن راهنمای نصب packageهای رایج را نمایش می‌دهد.

## شروع سریع

### سریع‌ترین روش: اجرای یک‌دستوری

این دستورها منوی تعاملی Manager را مستقیماً از نسخه فعلی شاخه `main` اجرا می‌کنند؛ یعنی اسکریپت پیش از اجرا بازبینی نمی‌شود. اگر می‌خواهید قبل از اجرا با دسترسی `root` کد را بررسی کنید، روش بعدی را انتخاب کنید.

اگر با کاربر `root` وارد شده‌اید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh)
```

برای کاربر عادی:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh | sudo bash
```

از دستور `sudo bash <(curl ...)` استفاده نکنید؛ ممکن است `sudo` descriptor مربوط به `/dev/fd/...` را که process substitution استفاده می‌کند ببندد. برای اجرای دستور با دسترسی بالاتر، روش pipe به `sudo bash` را به کار ببرید.

### روش امن‌تر: دانلود، بررسی و سپس اجرا

ابتدا اسکریپت را دانلود و پیش از اجرا بررسی کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh -o backhaul-manager.sh
less backhaul-manager.sh
sudo bash ./backhaul-manager.sh
```

دستور آخر منوی تعاملی را اجرا می‌کند. اگر از قبل با کاربر `root` وارد شده‌اید، `sudo` لازم نیست.

هر دو روش، نسخه فعلی شاخه `main` را اجرا می‌کنند؛ این نسخه به یک release ثابت پین نشده و کانال دانلود نیز امضای رمزنگاری‌شده ندارد. برای نصب یا به‌روزرسانی دستور سراسری اختیاری `backhaul-manager` پس از بررسی اسکریپت، گزینه **Manager install / update** یا `--self-update` را اجرا کنید. self-update، syntax و version را بررسی و downgrade را رد می‌کند؛ اما کانال به‌روزرسانی دارای امضای رمزنگاری‌شده نیست.

## روند راه‌اندازی

1. روی سروری که نقش endpoint سمت ایران را دارد، Manager را اجرا و گزینه **Configure Iran server** را انتخاب کنید.
2. منبع Backhaul را انتخاب کنید. `power0matin/Backhaul` گزینه پیش‌فرض پیشنهادی است و `Musixal/Backhaul` نیز در دسترس است.
3. سمت خارج را به‌عنوان client تنظیم کنید و source/version، token، transport و control port سازگار را به کار ببرید.
4. وضعیت و Diagnostics هر دو سمت را بررسی کنید. اگر می‌خواهید پیش از ساخت تانل مسیر را بسنجید، ابتدا Link Test را اجرا کنید.
5. پورت‌های لازم را در فایروال سیستم و security group ارائه‌دهنده بررسی کنید. Manager فقط راهنمایی می‌دهد و تغییری در قوانین فایروال اعمال نمی‌کند.

### منوی تعاملی

فهرست فعلی منوی اصلی:

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
 13) Link test (check before tunneling)
  0) Exit
```

اجرای مجدد مراحل تنظیم سرور یا کلاینت روی نصب مدیریت‌شده ابتدا snapshot می‌گیرد. فایل‌ها اتمیک نوشته می‌شوند و در صورت بالا نیامدن سرویس با تنظیم جدید، rollback انجام می‌شود؛ البته مانند هر عملیات سیستمی، بازیابی همه خطاهای زیرساختی تضمین‌شده نیست.

### انتخاب source و سازگاری

source انتخاب‌شده در state نصب ذخیره شده و برای Upgradeهای بعدی هم به کار می‌رود. همه Profileهای یک میزبان از یک Backhaul binary مشترک استفاده می‌کنند؛ بنابراین تغییر source یا version روی کل نصب اثر دارد، نه فقط Profile انتخاب‌شده.

اگر source یک binary موجود ثبت نشده باشد، Manager به‌جای حدس‌زدن `unknown` نمایش می‌دهد. پیش از عملیات وابسته به source، repository واقعی را از **Backhaul maintenance → Record current source** یا با `--set-source REPO` ثبت کنید.

## Transportهای پشتیبانی‌شده

این هفت نام transport در Manager و sourceهای پشتیبانی‌شده وجود دارند.

| Transport | توضیح                                        | نیاز اضافه در سرور عملیاتی |
| --------- | -------------------------------------------- | -------------------------- |
| `wsmux`   | WebSocket چندگانه‌شده؛ نقطه شروع عمومی مناسب | موردی جز تنظیم معمول ندارد |
| `tcpmux`  | TCP چندگانه‌شده                              | موردی جز تنظیم معمول ندارد |
| `tcp`     | انتقال مستقیم TCP                            | موردی جز تنظیم معمول ندارد |
| `ws`      | انتقال WebSocket                             | موردی جز تنظیم معمول ندارد |
| `wssmux`  | WebSocket چندگانه‌شده با TLS                 | certificate و private key  |
| `wss`     | WebSocket با TLS                             | certificate و private key  |
| `udp`     | انتقال UDP                                   | موردی جز تنظیم معمول ندارد |

در `ws`، `wss`، `wsmux` و `wssmux`، در صورت پشتیبانی source انتخاب‌شده، کلاینت می‌تواند مقدار `edge_ip` را نیز تنظیم کند. transportها و فیلدهای config ممکن است با نسخه Backhaul فرق داشته باشند؛ Manager در جریان maintenance و migration سازگاری source و config را بررسی می‌کند.

### پورت‌ها و mappingها

Standard mode پورت‌های مستقیم مثل `443,2052,2082` را می‌پذیرد. Advanced mode از range و mapping هم پشتیبانی می‌کند:

```text
4000-4100
4000=5000
443=127.0.0.1:8443
443=[2001:db8::10]:8443
```

مقادیر پورت و تداخل با control port بررسی می‌شوند. این مثال‌ها شکل‌های قابل‌قبول را نشان می‌دهند؛ پورت‌ها و mapping نهایی را با طراحی شبکه و syntax نسخه Backhaul انتخابی هماهنگ کنید.

## آزمون اتصال پیش از ساخت تانل

پیش از اتکا به یک جفت سرور جدید، از **گزینه ۱۳ منوی اصلی** استفاده کنید. Link Test با config و listener موقت Backhaul مسیر را می‌سنجد و config ذخیره‌شده یا سرویس مدیریت‌شده را جایگزین نمی‌کند.

زیرمنوی Link Test چهار حالت دارد:

1. **سرور ایران: آزمایش همه transportها.** listenerهای موقت را برای transportهای پشتیبانی‌شده اجرا می‌کند و یک کد pairing نمایش می‌دهد.
2. **سرور خارج: اجرای تست.** آدرس سرور ایران و کد pairing را وارد کنید. نتیجه دسترسی TCP به control port، تأیید pairing، handshake بک‌هاول، forwarding، رفت‌وبرگشت داده و پایداری را جداگانه گزارش می‌کند و در صورت موفقیت یک transport را پیشنهاد می‌دهد.
3. **سرور ایران: آزمایش یک پورت و transport مشخص.** وقتی control port موردنظرتان مهم است—مثلاً TCP پورت `443`—از این حالت استفاده کنید. یک پورت جدا برای forwarding و یک پورت اختیاری برای verification دارد. اگر پورت از قبل اشغال باشد، گزارش می‌شود و listener موجود دست‌کاری نمی‌شود.
4. **سرور خارج: فقط دسترسی TCP.** این یک تست ساده دسترسی پورت است و **handshake یا عبور داده در Backhaul را تأیید نمی‌کند**.

**محدودیت‌های مهم:**

- Link Test فقط پورت‌ها و transportهایی را بررسی می‌کند که واقعاً در تست استفاده شده‌اند. موفقیت، وضعیت همان مسیر در همان زمان را نشان می‌دهد و تضمین uptime، کارایی یا عملکرد برنامه در محیط عملیاتی نیست.
- ممکن است لازم باشد پورت‌های موقت آزمون را در فایروال سیستم و security group باز کنید. Manager شماره و پروتکل دقیق را نمایش می‌دهد، اما خودش پورت را باز نمی‌کند.
- پس از پایان تست listener را متوقف و مجوزهای موقت فایروال را که دیگر لازم نیستند حذف کنید.
- قبولی تست transport مبتنی بر TLS جای تنظیم و اعتبارسنجی certificate، private key و زنجیره گواهی واقعی برای `wss` یا `wssmux` را نمی‌گیرد.
- برای اجرای کامل Link Test به Python 3 و OpenSSL نیاز است. اگر dependency یا asset لازم Backhaul آماده نشود، تست کامل نمی‌شود.

## Profile، بکاپ و مهاجرت

- Profile پیش‌فرض برای سازگاری با نصب‌های قدیمی از `/root/backhaul/config.toml` و `backhaul.service` استفاده می‌کند.
- Profileهای نام‌دار در `/root/backhaul/profiles/<name>/` قرار می‌گیرند و سرویس‌هایی مثل `backhaul-edge-1.service` دارند.
- فایل‌های TOML قدیمی Backhaul در مسیر ریشه می‌توانند شناسایی و فهرست شوند. Discovery فقط خواندنی است؛ برای تبدیل config شناسایی‌شده به Profile نام‌دار، **Profiles → Adopt legacy tunnel** را صریحاً انتخاب کنید.
- نشان `*` به معنی Profile انتخاب‌شده برای عملیات Manager است، نه اینکه بقیه Profileها متوقف شده باشند. وضعیت هر Profile جداگانه و به شکل `active`، `stopped`، `no-unit` یا `mismatch` نمایش داده می‌شود.
- عملیات سرویس برای Profile با وضعیت `mismatch` انجام نمی‌شود. عملیات روی binary مشترک، از جمله Upgrade، source migration، restore و uninstall، ممکن است تا زمان مدیریت‌کردن tunnelهای legacy شناسایی‌شده متوقف شوند.
- بکاپ کامل schema-2 شامل Profileهای مدیریت‌شده، tunnelهای legacy شناسایی‌شده در مسیر ریشه، وضعیت active/enabled سرویس‌ها، وضعیت binary/source مشترک، اطلاعات لازم برای بازسازی unit و فایل‌های TLS قابل‌خواندن است. snapshot پیش از اعلام موفقیت از نظر checksum بررسی می‌شود.
- import آرشیو قابل‌انتقال `.tar.gz` پیش از extract با دسترسی بالا، مسیرها، نوع و تعداد اعضا و محدودیت اندازه را بررسی می‌کند. **آرشیو بکاپ حاوی secret است و امضا یا احراز اصالت رمزنگاری‌شده ندارد؛ فقط فایل‌هایی را import کنید که به آن‌ها اعتماد دارید.**
- مهاجرت سروربه‌سرور bundle را از طریق SSH منتقل کرده و permission فایل انتقالی را محدود می‌کند.
- source migration سازگاری Profileها را بررسی و تغییرات config را پیش از commit آماده می‌کند. downgrade یا تغییری که به adaptation نیاز داشته باشد، در جریان تعاملی به تأیید روشن نیاز دارد.

## دستورات خط فرمان

حالت پیش‌فرض منوی تعاملی است، اما بسیاری از کارهای مدیریتی را می‌توان مستقیم از ترمینال اجرا کرد:

```bash
# وضعیت، عیب‌یابی و metrics
sudo ./backhaul-manager.sh --status
sudo ./backhaul-manager.sh --diagnose
sudo ./backhaul-manager.sh --metrics
sudo ./backhaul-manager.sh --profile edge-1 --status

# کنترل سرویس و ارتقای Backhaul
sudo ./backhaul-manager.sh --start
sudo ./backhaul-manager.sh --stop
sudo ./backhaul-manager.sh --restart
sudo ./backhaul-manager.sh --upgrade            # آخرین نسخه source ثبت‌شده
sudo ./backhaul-manager.sh --upgrade v0.7.2     # تعیین tag نسخه

# مدیریت source و Profile
sudo ./backhaul-manager.sh --compat power0matin/Backhaul
sudo ./backhaul-manager.sh --set-source power0matin/Backhaul
sudo ./backhaul-manager.sh --migrate-source Musixal/Backhaul
sudo ./backhaul-manager.sh --adopt-legacy
sudo ./backhaul-manager.sh --list-profiles
sudo ./backhaul-manager.sh --select-profile edge-1

# بکاپ، export/import و لاگ‌ها
sudo ./backhaul-manager.sh --backup
sudo ./backhaul-manager.sh --list-backups
sudo ./backhaul-manager.sh --export /root/backhaul-portable.tar.gz
sudo ./backhaul-manager.sh --import /root/backhaul-portable.tar.gz
sudo ./backhaul-manager.sh --restore-backup backup-YYYYMMDD-HHMMSS-label-PID
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs

# نصب/به‌روزرسانی اختیاری دستور سراسری
sudo ./backhaul-manager.sh --self-update
./backhaul-manager.sh --version
./backhaul-manager.sh --help
```

`--upgrade` به‌صورت پیش‌فرض آخرین release از source ثبت‌شده را دریافت می‌کند و downgrade غیرتعاملی را رد می‌کند. `--migrate-source` نیز downgrade یا مهاجرت نیازمند تغییر config را در حالت غیرتعاملی رد می‌کند؛ برای بررسی و تأیید چنین تغییری از Manager تعاملی استفاده کنید. در عملیات پشتیبانی‌شده می‌توان `--profile NAME` را پیش از دستور قرار داد.

## فایل‌ها و مقادیر پیش‌فرض

### مسیرهای مهم

| مسیر                                          | کاربرد                                                 |
| --------------------------------------------- | ------------------------------------------------------ |
| `/opt/backhaul/backhaul`                      | Backhaul binary نصب‌شده                                |
| `/root/backhaul/config.toml`                  | config Profile پیش‌فرض با permission برابر `0600`      |
| `/root/backhaul/backhaul-info.txt`            | خلاصه اطلاعات setup و اتصال با permission برابر `0600` |
| `/root/backhaul/profiles/<name>/config.toml`  | config Profile نام‌دار با permission برابر `0600`      |
| `/etc/systemd/system/backhaul.service`        | unit سرویس پیش‌فرض                                     |
| `/etc/systemd/system/backhaul-<name>.service` | unit سرویس Profile نام‌دار                             |
| `/var/lib/backhaul-manager/backups/`          | snapshotهای rollback و بکاپ‌ها                         |
| `/var/lib/backhaul-manager/backhaul-source`   | اطلاعات source انتخاب‌شده                              |
| `/var/lib/backhaul-manager/active-profile`    | نام Profile انتخاب‌شده                                 |
| `/var/log/backhaul-manager/`                  | لاگ مجزای هر اجرا با permission برابر `0600`           |
| `/usr/local/sbin/backhaul-manager`            | دستور سراسری اختیاری Manager                           |

### مقادیر پیش‌فرض Standard mode

| تنظیم                    | مقدار پیش‌فرض                      |
| ------------------------ | ---------------------------------- |
| Control port             | `8080`                             |
| Tunnel ports             | `2052,2082,8002,443`               |
| Transport                | `wsmux`                            |
| source مربوط به Backhaul | `power0matin/Backhaul`             |
| `keepalive_period`       | `20` برای transportهای غیر UDP     |
| `heartbeat` سمت سرور     | `20`                               |
| `channel_size`           | `2048`                             |
| `connection_pool`        | `8`                                |
| `mux_con`                | `8` برای transportهای mux سمت سرور |
| `mux_version`            | `1` برای transportهای mux          |
| `web_port`               | `0` (خاموش)                        |
| `log_level`              | `info`                             |

تنظیمات Advanced می‌تواند pool، channel، mux، buffer و concurrency را تغییر دهد. `safe` مصرف منابع را محدودتر می‌کند، `balanced` به مقدارهای بالا نزدیک است و `throughput` برای میزبان قوی‌تر concurrency/buffer بیشتری در نظر می‌گیرد. Auto با توجه به CPU و RAM در دسترس یک profile را انتخاب می‌کند. در config کلاینت `heartbeat` نوشته نمی‌شود، چون schema فعلی client در Backhaul چنین فیلدی ندارد. web monitor به‌صورت پیش‌فرض خاموش است. در Advanced mode نسخه PowerMatin می‌توان metrics احراز هویت‌شده را فقط روی loopback فعال کرد؛ برای Musixal v0.7.2 این قابلیت خودکار فعال نمی‌شود، چون آن نسخه امکان تنظیم امن bind روی loopback و احراز هویت را ندارد.

## امنیت و محدودیت‌های عملیاتی

- Tokenها از بایت‌های تصادفی رمزنگارانه تولید شده و به ۴۸ کاراکتر hexadecimal تبدیل می‌شوند. ورودی token سفارشی مخفی است و مقدارهای حساس برای TOML قبل از نوشتن escape می‌شوند.
- permission فایل‌های config و info، بکاپ‌ها و لاگ‌های اجرایی محدود است. token در run log نوشته نمی‌شود.
- دانلودها با HTTPS و timeout/retry و محدودیت حجم انجام می‌شوند. آرشیو Release بررسی می‌شود، فقط فایل مورد انتظار `backhaul` استخراج می‌شود و خروجی version binary پیش از جایگزینی اعتبارسنجی می‌شود.
- config و binary با فایل موقت و جایگزینی اتمیک تغییر می‌کنند. هنگام شکست، snapshot قبلی بازیابی می‌شود و transaction قطع‌شده نیز تلاش می‌کند rollback کند.
- Manager برای اتصال systemd service به config مدیریت‌شده، `ExecStart` مؤثر از جمله drop-in override را بررسی می‌کند تا یک سرویس نامرتبط به‌اشتباه به‌عنوان Backhaul مدیریت نشود.
- آرشیوهای importشده و unitهای systemd ذخیره‌شده پیش از restore با دسترسی بالا اعتبارسنجی می‌شوند؛ مسیر یا عضو آرشیو ناامن و hook اجرایی ناامن رد می‌شوند.
- عملیات تغییردهنده Manager از `flock` غیرمسدودکننده استفاده می‌کنند تا چند process هم‌زمان state مشترک را تغییر ندهند.
- قانون‌های فایروال به‌صورت خودکار تغییر نمی‌کنند.
- self-update اختیاری syntax و version را بررسی و downgrade را رد می‌کند، اما **امضای رمزنگاری‌شده ندارد**. پیش از استفاده، source و سطح اعتماد خود را بررسی کنید.

این کنترل‌ها احتمال خطاهای رایج را کاهش می‌دهند، اما جای بکاپ، امنیت خود میزبان، تنظیم درست فایروال و بررسی کد پیش از اجرای privileged را نمی‌گیرند.

## رفع مشکل

ابتدا Diagnostics را اجرا کنید:

```bash
sudo ./backhaul-manager.sh --diagnose
sudo ./backhaul-manager.sh --status
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs
```

علت‌های رایج عدم راه‌اندازی:

- control port سمت ایران در فایروال سیستم، security group ارائه‌دهنده یا مسیر شبکه مسدود است.
- پردازش دیگری از قبل به پورت انتخاب‌شده گوش می‌دهد.
- token، transport یا control port سمت سرور و کلاینت هماهنگ نیست؛ یا source/version دو سمت با هم سازگار نیستند.
- certificate یا private key موردنیاز TLS وجود ندارد یا قابل خواندن نیست.
- برای tag نسخه یا معماری CPU انتخاب‌شده، asset متناظر Backhaul وجود ندارد.
- source migration با فیلدهایی در Profile مواجه شده که نسخه مقصد پشتیبانی نمی‌کند.

وقتی لازم است دسترسی پورت را از handshake و عبور داده تفکیک کنید، Link Test (گزینه ۱۳) را اجرا کنید. نتیجه آزمون TCP به‌تنهایی اثبات نمی‌کند که تانل Backhaul کار می‌کند.

## توسعه و تست

دستورها را از ریشه repository اجرا کنید. برای فرمان‌های lint، نصب بودن ShellCheck لازم است.

```bash
# بررسی syntax زبان Bash مطابق CI
bash -n backhaul-manager.sh test.sh tests/test.sh tests/test-v311.sh tests/test-v312.sh tests/test-linktest.sh

# تحلیل ایستا مطابق CI
shellcheck backhaul-manager.sh test.sh tests/test-v311.sh tests/test-v312.sh tests/test-linktest.sh tests/test-linktest-integration.sh
shellcheck --exclude=SC2317,SC2329,SC2034 tests/test.sh

# مجموعه تست‌های regression و failure-injection که CI اجرا می‌کند
bash test.sh
bash tests/test.sh
bash tests/test-v311.sh
bash tests/test-v312.sh
bash tests/test-linktest.sh
```

GitHub Actions روی push به `main` و pull requestها، syntax check، ShellCheck و مجموعه تست‌های بالا را اجرا می‌کند. فایل `tests/test-linktest-integration.sh` در CI از نظر lint بررسی می‌شود، اما یک مجموعه integration اختیاری با binary واقعی است و در حلقه تست پیش‌فرض CI اجرا نمی‌شود. این تست فقط روی loopback اجرا می‌شود و مسیر واقعی بین دو میزبان را بررسی نمی‌کند. برای اجرا، مسیر binaryهای واقعی موردنظر را بدهید: `BH_BIN_POWER=/path/to/power0matin/backhaul BH_BIN_MUSIXAL=/path/to/Musixal/backhaul bash tests/test-linktest-integration.sh`.

## نقشه راه

- [x] هر هفت transport پشتیبانی‌شده Backhaul
- [x] تولید امن token و مدیریت محتاطانه secretها
- [x] تغییر تراکنشی config/binary همراه با rollback
- [x] Status، Diagnostics، کنترل سرویس، لاگ و Upgrade
- [x] دستورات مدیریتی CLI
- [x] تست خودکار syntax، lint، regression و failure-injection
- [x] پورت‌رنج و port mapping پیشرفته
- [x] Standard/Advanced mode همراه با تنظیم منابع
- [x] چند Profile و سرویس نام‌گذاری‌شده
- [x] مهاجرت source با compatibility check و rollback
- [x] بکاپ کامل، restore، import/export و مهاجرت SSH
- [x] Health metrics و اتصال `/stats` در sourceهای پشتیبانی‌شده
- [x] نصب/به‌روزرسانی اختیاری دستور سراسری Manager
- [x] Link Test پیش از تانل، شامل exact-port و آزمون صرفاً TCP
- [ ] فلگ‌های پیکربندی کاملاً غیرتعاملی برای سمت سرور و کلاینت

برای تاریخچه نسخه‌ها و تغییرات منتشرنشده، [CHANGELOG.md](./CHANGELOG.md) را ببینید.

## مشارکت و مجوز

گزارش باگ و pull request از طریق [GitHub Issues](https://github.com/power0matin/backhaul-manager/issues) و [Pull Requests](https://github.com/power0matin/backhaul-manager/pulls) پذیرفته می‌شود. برای تغییر رفتاری بزرگ، بهتر است ابتدا issue ثبت کنید تا پیشنهاد با مدل config نسخه‌های پشتیبانی‌شده Backhaul تطبیق داده شود.

مجوز این پروژه [MIT](./LICENSE) است. خود Backhaul پروژه‌ای جدا با source و مجوز مستقل است. برای معرفی کلی پروژه، [صفحه رسمی](https://matinshahabadi.ir/projects/backhaul-manager/) را ببینید.
