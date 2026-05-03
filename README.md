# Zabbix Config Backup (Config-only)

Giải pháp backup cấu hình Zabbix để có thể **dựng lại hệ thống nhanh chóng**, không lưu metrics nặng.

---

## 1. Mục tiêu

* Backup đầy đủ cấu hình:

  * Hosts
  * Templates
  * Actions
  * Media types
  * Triggers
* Không lưu:

  * history
  * trends
  * metrics
* Có thể:

  * restore nhanh
  * rebuild hệ thống mới

---

## 2. Cấu trúc project

```
/home/setup/zabbix-config-backup/
├── conf/
│   ├── backup.env
│   └── exclude_tables.txt
├── scripts/
│   ├── run_backup.sh
│   ├── backup_db.sh
│   ├── backup_etc.sh
│   └── export_api.sh
├── storage/
│   ├── db/
│   ├── etc/
│   └── exports/
├── manifests/
│   └── backup_manifest.json
└── README.md
```

---

## 3. Cấu hình

Sửa file:

```
nano /home/setup/zabbix-config-backup/conf/backup.env
```

Quan trọng:

```
PROJECT_DIR="/home/setup/zabbix-config-backup"
BACKUP_BASE="${PROJECT_DIR}/storage"

DB_TYPE="postgresql"
DB_HOST="172.16.0.3"
DB_PORT="5432"
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASS="CHANGE_ME"

ZBX_URL="http://127.0.0.1:8080"
ZBX_TOKEN="CHANGE_ME"

RETENTION_DAYS=30
LOG_FILE="/home/setup/zabbix-config-backup/storage/zabbix-config-backup.log"
```

---

## 4. Cài dependency

```
sudo apt update
sudo apt install -y jq curl tar gzip postgresql-client default-mysql-client
```

---

## 5. Cấp quyền

```
sudo chown -R setup:setup /home/setup/zabbix-config-backup
chmod +x /home/setup/zabbix-config-backup/scripts/*.sh
```

---

## 6. Chạy backup

```
sudo ENV_FILE=/home/setup/zabbix-config-backup/conf/backup.env \
bash /home/setup/zabbix-config-backup/scripts/run_backup.sh
```

---

## 7. Debug khi lỗi

```
sudo ENV_FILE=/home/setup/zabbix-config-backup/conf/backup.env \
bash -x /home/setup/zabbix-config-backup/scripts/run_backup.sh 2>&1 | tee debug-run.log
```

---

## 8. Kết quả backup

### DB

```
storage/db/latest
```

### ETC

```
storage/etc/latest
```

### API export

```
storage/exports/<timestamp>/
```

Bao gồm:

```
templates.json
host_groups.json
media_types.json
hosts.json
maps.json
actions.raw.json
value_maps.raw.json
maintenance.raw.json
```

---

## 9. Restore nhanh

### PostgreSQL

```
sudo systemctl stop zabbix-server

PGPASSWORD="DB_PASS" pg_restore \
  -h DB_HOST \
  -p DB_PORT \
  -U DB_USER \
  -d DB_NAME \
  --clean \
  --if-exists \
  storage/db/latest

sudo tar -xzf storage/etc/latest -C /

sudo systemctl restart zabbix-server
```

---

## 10. Cron chạy tự động

Mở:

```
sudo crontab -e
```

Thêm:

```
0 2 1 * * ENV_FILE=/home/setup/zabbix-config-backup/conf/backup.env bash /home/setup/zabbix-config-backup/scripts/run_backup.sh >> /home/setup/zabbix-config-backup/storage/cron.log 2>&1
```

👉 Chạy lúc **02:00 sáng ngày đầu tiên hằng tháng**

---

## 11. Retention

Tự động xóa backup cũ:

```
RETENTION_DAYS=30
```

Xóa:

* DB backup
* ETC backup
* export cũ

---

## 12. Log

```
tail -f storage/zabbix-config-backup.log
```

---

## 13. Lưu ý quan trọng

* Luôn chạy bằng `sudo`
* DB backup đã chứa toàn bộ config
* API export để rebuild/migrate
* Nên restore cùng version Zabbix
* Không backup metrics để giảm dung lượng

---

## 14. Nguyên lý

* DB backup → restore nhanh
* API export → rebuild hệ thống
* ETC → giữ config service

---

## 15. Kết luận

Hệ thống backup này:

* Nhẹ
* Dễ vận hành
* Có thể dựng lại Zabbix mới
* Tự động chạy hàng tuần
* Tự cleanup sau 30 ngày
