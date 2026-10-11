# USB MTP — Fix "Windows không thấy thẻ SD" trên TG5040 / TrimUI Brick (NX Redux)

> **Ngày:** 2026-10-11
> **Thiết bị:** TrimUI Brick (TG5040, kernel `4.9.191`, firmware OpenWrt `TinaLinux`, procd, dual app A/B OTA)
> **Kết nối:** thẻ SD mount SSHFS tại `trimui_sdcard/` trong repo
> **Kết quả:** Windows Explorer hiện đúng thẻ SD **58 GB** (thay vì 4 GB ổ trong) qua USB MTP.

---

## 1. Tóm tắt vấn đề

| Triệu chứng                                                    | Nguyên nhân gốc                                                                                               |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Bật USB MTP nhưng Windows Explorer không nhận thiết bị         | `/etc/init.d/mtp start` là **no-op** (script thiếu shebang `/etc/rc.common`) → `MtpDaemon` không bao giờ chạy |
| Tắt MTP rồi bật lại → app bị đá ra                             | `NameError: is_proc_running is not defined` trong `rh/services.py`                                            |
| Quá trình debug làm toggle dính ON, không tắt được             | `is_mtp_running()` ưu tiên đọc file `ex_options` (thay đổi tạm trong lúc debug) — đã hoàn tác                 |
| Windows thấy "TinaLinux" nhưng **chỉ 4 GB, không thấy thẻ SD** | Binary `MtpDaemon` **hardcode storage root `/mnt/UDISK`** (ổ trong 4 GB), không liệt kê `/mnt/SDCARD`         |

---

## 2. Phân tích kỹ thuật (bối cảnh hardware/firmware)

### 2.1. USB gadget

- Máy dùng **1 cổng USB gadget** duy nhất qua **configfs**: `/sys/kernel/config/usb_gadget/g1` (`configs/c.1`).
- Tool chuẩn đổi chức năng: **`/bin/setusbconfig`** (shell script của TrimUI; trên kernel 4.9 dùng function `mtp.gs0`, kernel 5.x sẽ dùng `ffs.mtp`).
- **KHÔNG được đọc** các node role: `/sys/devices/platform/soc*/usbc0/usb_host|usb_device|usb_null|usb_otg` — một `cat` là đổi role cổng, chết adb, có thể latch host mode.
- Node an toàn để đọc: `/sys/class/udc/*/state` (giá trị hữu ích: `configured`) và `/sys/kernel/config/usb_gadget/g1/configs/c.1/`.
- Chrome: tg5040 (kernel 4.9) **từ chối cặp bulk endpoint thứ 2** → tránh cùng lúc nhiều functionfs data (xem `workspace/all/usblink/usblink_gadget.c`).

### 2.2. Lưu trữ

| Storage      | Device                            | Mount         | FS    | Vai trò                       |
| ------------ | --------------------------------- | ------------- | ----- | ----------------------------- |
| Ổ trong 4 GB | `/dev/by-name/UDISK` (mmcblk0p10) | `/mnt/UDISK`  | ext4  | data hệ thống                 |
| Thẻ SD 58 GB | `/dev/mmcblk1p1`                  | `/mnt/SDCARD` | exfat | ROM, `.system`, RetroHub, ... |

`/mnt/SDCARD` chính là thư mục `trimui_sdcard/` SSHFS trong repo — **thẻ SD không bị nâng firmware đụng tới**.

### 2.3. Chuỗi khởi động (quan trọng để biết chỗ hook)

```
procd (/sbin/procd)
├─ /etc/rc.d/S10.. / S40fstab ... (mount SD)
├─ /etc/init.d/done (S95)   → chạy /etc/rc.local, mount_root done
├─ /etc/init.d/mtp (START=98) → KHÔNG có symlink trong /etc/rc.d → KHÔNG tự chạy lúc boot
└─ /etc/init.d/runtrimui (S99) → /usr/trimui/bin/runtrimui.sh
      ├─ chờ /mnt/SDCARD (mmcblk1p1) mount
      ├─ nếu có /mnt/SDCARD/.tmp_update/updater → chạy updater (cơ chế nâng firmware)
      └─ ngược lại → /usr/trimui/bin/runtrimui-original.sh
            └─ **chạy mọi /mnt/SDCARD/System/starts/*.sh**  ← ĐIỂM HOOK TRÊN THẺ SD
```

---

## 3. Quá trình debug (ghi chép chi tiết để truy vết lại)

### 3.1. Bước 1 — Xác nhận toggle có vấn đề ngay từ app

- UI: `rh/screens/network.py` → `mtp_toggle` → `toggle_mtp()` trong `rh/services.py`.

### 3.2. Bước 2 — SSH vào máy, đọc trạng thái thật

```sh
# Kết nối (dùng sshpass/SSH_ASKPASS trong WSL)
ssh root@192.168.1.99

# Script MTP & binary
cat /etc/init.d/mtp
ls -l /usr/sbin/MtpDaemon /bin/setusbconfig

# Trạng thái gadget (node AN TOÀN)
cat /sys/class/udc/*/state          # muốn = configured
ls -l /sys/kernel/config/usb_gadget/g1/configs/c.1/
ls /sys/kernel/config/usb_gadget/g1/functions/

# Daemon
ps w | grep -i MtpDaemon

# Log crash của app
cat /mnt/SDCARD/RetroHub-loi.txt | tail -80
# hoặc /mnt/SDCARD/.userdata/tg5040/logs/RetroHub.txt
```

### 3.3. Bước 3 — Phát hiện 3 lỗi chồng nhau

**Lỗi A — `/etc/init.d/mtp` bị hỏng (nhẹ):**

Script có `start_service()` nhưng **thiếu dòng đầu chuẩn `#!/bin/sh /etc/rc.common`** → chạy `start` không làm gì cả. Kiểm tra bằng:

```sh
/etc/init.d/mtp start; echo "rc=$?"
ps w | grep -i MtpDaemon            # → không có process!
```

So sánh script đúng chuẩn OpenWrt/procd: phải bắt đầu bằng `#!/bin/sh /etc/rc.common` và khai báo `USE_PROCD=1` để `start` → `start_service()`.

**Lỗi B — app không tự khởi động daemon (chính là lý do "bật nhưng Windows không thấy"):**

Chuỗi chạy Đ ƯỢC trên thiết bị (đã kiểm chứng) là:

```sh
/usr/sbin/MtpDaemon -D &            # 1) chạy daemon trực tiếp
/bin/setusbconfig mtp               # 2) đổi gadget sang MTP
```

**Lỗi C — crash app:**

```
Traceback ... rh/services.py, line 180, in toggle_mtp
    if is_proc_running(_MTP_DAEMONS):
NameError: name 'is_proc_running' is not defined
```

→ `services.py` dùng `is_proc_running()` nhưng chưa import từ `sysinfo`.

### 3.4. Bước 4 — Phát hiện tầng cuối: MtpDaemon hardcode `/mnt/UDISK`

```sh
strings /usr/sbin/MtpDaemon | grep -E "^/mnt/"
# → chỉ có /mnt/UDISK  (không có SDCARD/mmcblk; daemon không có config file, không nhận tham số storage)
```

→ Windows chỉ thấy 4 GB ổ trong. Phải **đổi storage root sang `/mnt/SDCARD`**.

---

## 4. Giải pháp

### 4.1. Fix app trên thẻ — `trimui_sdcard/.system/paks/Tools/RetroHub.pak/rh/services.py`

- **Import thêm `is_proc_running`** vào dòng import từ `.sysinfo` (hết crash).
- `toggle_mtp()` nhánh **BẬT** (thứ tự quan trọng):
  1. `save_options(mtp_val="Y")` — ghi `USB_MTP="Y"` vào `/mnt/SDCARD/System/etc/ex_options` TRƯỚC.
  2. `_start_mtp_daemon()` — tự chạy `/usr/sbin/MtpDaemon -D` trực tiếp (không phụ thuộc init script hỏng).
  3. `_setusbconfig("mtp")` — đổi gadget sang MTP.
  4. Verify: chờ daemon lên + `/sys/class/udc/*/state` = `configured` + `mtp.gs0` link trong `configs/c.1`.
  5. Chỉ báo "Đã bật" khi verify đạt; nếu lỗi → báo lý do cụ thể + rollback (`stop`, `setusbconfig adb`, `USB_MTP="N"`).
- Nhánh **TẮT**: `_stop_mtp_quiet()` (kill daemon) → `_setusbconfig("adb")` (trả gadget về mặc định) → `save_options(mtp_val="N")`.

Các file code đã sửa (bản chạy thật trên máy, trong `trimui_sdcard/`):

- `rh/services.py`
- `rh/sysinfo.py`

> ⚠️ Lưu ý: `trimui_sdcard/` và `migration-apps/` bị `.gitignore` (không track trong git). Chỉ `skeleton/` mới được track.

### 4.2. Patch binary `MtpDaemon` (đổi storage root sang thẻ SD)

Storage root duy nhất nằm hardcode trong binary. Patch nhị phân an toàn vì sau chuỗi `/mnt/UDISK` là **padding toàn số 0**:

```sh
# backup bản gốc (BẮT BUỘC)
cp -a /usr/sbin/MtpDaemon /usr/sbin/MtpDaemon.orig

# ghi đè "/mnt/UDISK" (10 bytes) -> "/mnt/SDCARD\0" (12 bytes) tại offset
printf '\057\155\156\164\057\123\104\103\101\122\104\000' | \
    dd of=/usr/sbin/MtpDaemon bs=1 seek=69796 conv=notrunc

# xác minh
strings /usr/sbin/MtpDaemon | grep -E "^/mnt/"          # = /mnt/SDCARD
strings -t d /usr/sbin/MtpDaemon | grep "/mnt/"
dd if=/usr/sbin/MtpDaemon bs=1 skip=69792 count=24 2>/dev/null | xxd
```

**Bản chụp offset (snapshot):**

| Tham số                | Giá trị                                                          |
| ---------------------- | ---------------------------------------------------------------- |
| Chuỗi gốc trong binary | `/mnt/UDISK`                                                     |
| Chuỗi sau patch        | `/mnt/SDCARD`                                                    |
| **Offset (decimal)**   | **69796** (0x110A4)                                              |
| Chiều dài chuỗi ghi đè | 11 bytes + NUL (trong padding 0, an toàn)                        |
| Bản firmware ghi nhận  | `4.9.191`, build Jul 17 09:06, `/usr/sbin/MtpDaemon` 87456 bytes |
| Backup                 | `/usr/sbin/MtpDaemon.orig`                                       |

> Nếu firmware đổi, offset có thể lệch. Cách tìm lại: `strings -t d /usr/sbin/MtpDaemon | grep /mnt/UDISK`, lấy cột thứ nhất làm `OFF`.

### 4.3. Boot-hook tự-patch trên thẻ SD (sống sót qua nâng firmware)

Firmware chạy mọi `*.sh` trong **`/mnt/SDCARD/System/starts/`** mỗi lần boot (`runtrimui-original.sh`). Script đã tạo:

- Vị trí: `/mnt/SDCARD/System/starts/00-mtpsdcard.sh`
- Nội dung chính: đọc 11 byte tại offset 69796; nếu khác `/mnt/SDCARD` thì backup 1 lần vào `MtpDaemon.orig` rồi ghi đè; nếu ghi thất bại thì khôi phục backup; ghi log vào `/tmp/mtp-sdcard.log`.
- Vì nằm trên **thẻ SD** nên không bị nâng firmware xoá.

Đã kiểm chứng self-healing: khôi phục binary gốc (mô phỏng nâng firmware) → chạy script → binary lại thành `/mnt/SDCARD`.

---

## 5. Backup & cách hoàn tác

### Hoàn tác patch binary (về ổ trong 4 GB)

```sh
cp /usr/sbin/MtpDaemon.orig /usr/sbin/MtpDaemon
pkill -9 MtpDaemon
# nếu đang bật MTP: /bin/setusbconfig adb
```

### Vô hiệu hoá boot-hook (hết tự-patch)

```sh
rm /mnt/SDCARD/System/starts/00-mtpsdcard.sh
cp /usr/sbin/MtpDaemon.orig /usr/sbin/MtpDaemon
```

> Backup binary gốc nằm tại `/usr/sbin/MtpDaemon.orig` (trên overlay rootfs → cũng bị nâng firmware xoá). Nên giữ 1 bản ở nơi an toàn: `cp /usr/sbin/MtpDaemon.orig /mnt/SDCARD/System/etc/`.

---

## 6. Lưu ý khi nâng cấp NX Redux / firmware

1. **Nâng firmware (OTA dual A/B `app`/`app_sub`):**
   - Binary `/usr/sbin/MtpDaemon` và overlay rootfs sẽ được khôi phục bản gốc.
   - **Không cần làm gì**: boot-hook `00-mtpsdcard.sh` trên thẻ SD sẽ tự patch lại ở boot kế tiếp.
   - Kiểm tra lại sau boot: `strings /usr/sbin/MtpDaemon | grep "^/mnt/"` phải ra `/mnt/SDCARD`.
2. **Nếu firmware mới đổi cấu trúc `MtpDaemon`:**
   - Script sẽ tự phát hiện (11 byte tại offset cũ không khớp) và **tự khôi phục backup** — không làm hỏng binary.
   - Khi đó MTP sẽ quay lại hiện ổ trong 4GB → **tìm offset mới**:
     ```sh
     strings -t d /usr/sbin/MtpDaemon | grep /mnt/UDISK
     ```
     rồi cập nhật biến `OFF` trong `00-mtpsdcard.sh`.
3. **Thay đổi code RetroHub:**
   - Code chạy thật là bản trên thẻ (`trimui_sdcard/.system/paks/Tools/RetroHub.pak/rh/`), KHÔNG phải `skeleton/` hay `migration-apps/`.
   - Sau khi sửa, **xóa `__pycache__`** để app nạp code mới:
     ```sh
     rm -rf /mnt/SDCARD/.system/paks/Tools/RetroHub.pak/rh/__pycache__
     ```
   - Log crash app: `/mnt/SDCARD/RetroHub-loi.txt` (hoặc `.userdata/tg5040/logs/RetroHub.txt`).
4. **Checklist nhanh sau nâng firmware:**
   ```sh
   strings /usr/sbin/MtpDaemon | grep "^/mnt/"    # /mnt/SDCARD
   cat /tmp/mtp-sdcard.log                        # log tự-patch
   cat /mnt/SDCARD/System/etc/ex_options          # USB_MTP="Y" / USB_ADB=...
   ps w | grep -i MtpDaemon                       # daemon đang chạy
   cat /sys/class/udc/*/state                     # configured
   ```

---

## 7. Danh sách file / đường dẫn liên quan

| Đường dẫn                                                      | Vai trò                                                                        |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `/mnt/SDCARD/System/starts/00-mtpsdcard.sh`                    | Boot-hook tự-patch (trên thẻ SD, sống qua firmware upgrade)                    |
| `/usr/sbin/MtpDaemon`                                          | Daemon MTP (đã patch storage root)                                             |
| `/usr/sbin/MtpDaemon.orig`                                     | Backup binary gốc                                                              |
| `/bin/setusbconfig`                                            | Tool đổi USB gadget (TrimUI)                                                   |
| `/etc/init.d/mtp`                                              | Script init "patched" của RetroHub — **bị hỏng** (thiếu rc.common), không dùng |
| `/mnt/SDCARD/System/etc/ex_options`                            | Cờ bật/tắt service (nguồn trạng thái của app)                                  |
| `trimui_sdcard/.system/paks/Tools/RetroHub.pak/rh/services.py` | Code toggle (đã fix)                                                           |
| `trimui_sdcard/.system/paks/Tools/RetroHub.pak/rh/sysinfo.py`  | `is_mtp_running` (đã đưa về ưu tiên file ex_options)                           |
| `plans/usb-mtp-sdcard-fix.md`                                  | Tài liệu này (trong repo)                                                      |
| `plans/retrohub-pak-migration.md`                              | Tài liệu migration RetroHub (repo)                                             |

---

## 8. Changelog nhanh

- **2026-10-11** — Fix chuỗi toggle MTP (import `is_proc_running`, start daemon trực tiếp, verify gadget), đưa `is_mtp_running` về ưu tiên file `ex_options`.
- **2026-10-11** — Patch binary `MtpDaemon`: `/mnt/UDISK` → `/mnt/SDCARD` (offset 69796).
- **2026-10-11** — Thêm boot-hook tự-patch `/mnt/SDCARD/System/starts/00-mtpsdcard.sh`.
- **2026-10-11** — Ghi tài liệu này.

_Hết tài liệu._
