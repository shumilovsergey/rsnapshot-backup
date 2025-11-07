#!/usr/bin/env bash

# sa.shumilov

set -euo pipefail

# -------- SCRIPT_DIR (директория со скриптом) ----------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# -------- ПАРАМЕТРЫ / ДЕФОЛТЫ ----------
# Говорящий дефолт: если пользователь не указал --type, rsnapshot запустится с этой строкой и сам упадёт
RSNAPSHOT_TYPE="Тип бэкапа не указан при запуске"

# Разбор аргументов: поддержка --type=<x> и --type <x>
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t=*|--type=*)
      RSNAPSHOT_TYPE="${1#*=}"
      shift
      ;;
    -t|--type)
      RSNAPSHOT_TYPE="${2:-$RSNAPSHOT_TYPE}"
      shift 2 || true
      ;;
    *)
      echo "Неизвестный параметр: $1"
      exit 1
      ;;
  esac
done

# -------- CONSTS ----------
SNAPSHOT_ROOT="/path/to/snapshot/root/dir/"
SSH_USER="???"
SSH_SERVER="xx.xx.xx.xx"
SSH_PATH="/path/to/backup/target/"
LOCAL_PATH="${SNAPSHOT_ROOT}${RSNAPSHOT_TYPE}.0/"

# -------- TELEGRAM ----------
TELEGRAM_TOKEN="???"
TELEGRAM_ID="???" #sa.shumilov tg - 507717647

send_telegram() {
  local message="$1"
  curl -s --fail \
    -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_ID}" \
    --data-urlencode text="$message" \
    > /dev/null
}

# -------- RSNAPSHOT-CONFIG ----------
RSNAPSHOT_CONF_PATH="${SCRIPT_DIR}/rsnapshot.conf"

RSNAPSHOT_CONFIG=$(cat <<EOF
config_version  1.2
snapshot_root   ${SNAPSHOT_ROOT}
cmd_cp          /usr/bin/cp
cmd_rm          /usr/bin/rm
cmd_rsync       /usr/bin/rsync
cmd_ssh         /usr/bin/ssh
cmd_logger      /usr/bin/logger

retain  daily   30
retain  monthly 12

verbose         2
loglevel        3
logfile         /var/log/rsnapshot.log
lockfile        /var/run/rsnapshot.pid

backup          ${SSH_USER}@${SSH_SERVER}:${SSH_PATH}   ./
EOF
)

# Сохраняем конфиг
printf '%s\n' "$RSNAPSHOT_CONFIG" > "$RSNAPSHOT_CONF_PATH"

# Приводим пробелы к табам во всех незакомментированных строках (rsnapshot любит TAB)
if sed --version >/dev/null 2>&1; then
  sed -i '/^[[:space:]]*#/!s/[ ]\+/\t/g' "$RSNAPSHOT_CONF_PATH"
else
  sed -i '' '/^[[:space:]]*#/!s/[ ]\+/\t/g' "$RSNAPSHOT_CONF_PATH"
fi

# -------- Локаль для сортировки ----------
export LC_ALL=C

# -------- Логирование вывода ----------
LOG_TS=$(date +%F)
TMP_LOG=$(mktemp)
exec > >(tee -a "$TMP_LOG") 2>&1

# -------- Временные файлы ----------
tmp_remote_raw=$(mktemp)
tmp_remote_sorted=$(mktemp)
tmp_remote_first=$(mktemp)
tmp_remote_kv=$(mktemp)

tmp_local_raw=$(mktemp)
tmp_local_sorted=$(mktemp)
tmp_local_first=$(mktemp)
tmp_local_kv=$(mktemp)

cleanup() {
  rm -f \
    "$tmp_remote_raw" "$tmp_remote_sorted" "$tmp_remote_first" "$tmp_remote_kv" \
    "$tmp_local_raw"  "$tmp_local_sorted"  "$tmp_local_first"  "$tmp_local_kv"
}
trap cleanup EXIT

# -------- Старт ----------
echo
echo "⚠️  Начало выполнения rsnapshot: $(date '+%Y-%m-%d %H:%M:%S')"
echo "==  ⚪️ Проверяю rsnapshot.conf =="

if rsnapshot -c "$RSNAPSHOT_CONF_PATH" configtest; then
  echo "   Проверка rsnapshot.conf выполнена успешно"
else
  echo "  rsnapshot.conf не прошёл проверку"
  send_telegram "Цель бэкапа: ${RSNAPSHOT_TYPE} | ${SSH_SERVER}:${SSH_PATH} | 🚨 rsnapshot.conf не прошёл проверку!"
  exit 1
fi

echo
echo "==  ⚪️ Запускаю rsnapshot ${RSNAPSHOT_TYPE}  =="
if rsnapshot -c "$RSNAPSHOT_CONF_PATH" "$RSNAPSHOT_TYPE"; then
  echo "   rsnapshot выполнен успешно"
else
  rc=$?
  echo "  rsnapshot завершился с ошибкой (код ${rc})"
  send_telegram "Цель бэкапа: ${RSNAPSHOT_TYPE} | ${SSH_SERVER}:${SSH_PATH} | 🚨 rsnapshot завершился с ошибкой! (код ${rc})"
  exit "$rc"
fi
echo

# -------- Проверка контрольных сумм ----------
echo "⚠️  Начало выполнения проверки контрольных сумм: $(date '+%Y-%m-%d %H:%M:%S')"

ssh "${SSH_USER}@${SSH_SERVER}" '
  set -euo pipefail
  export LC_ALL=C
  find "'"${SSH_PATH}"'" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum
' > "$tmp_remote_raw"

# Сортируем таргет
sort "$tmp_remote_raw" -o "$tmp_remote_sorted"

# Суммы локального бэкапа
find "${LOCAL_PATH}" -type f -print0 \
  | sort -z \
  | xargs -0 sha256sum > "$tmp_local_raw"

# Сортируем бэкап
sort "$tmp_local_raw" -o "$tmp_local_sorted"

echo "== ⚪️ Формирую первые столбцы (HASH) таргета и бэкапа =="
awk '{print $1}' "$tmp_remote_sorted" > "$tmp_remote_first"
awk '{print $1}' "$tmp_local_sorted"  > "$tmp_local_first"

remote_total=$(wc -l < "$tmp_remote_first" | tr -d ' ')
local_total=$(wc -l < "$tmp_local_first" | tr -d ' ')

echo "  Таргет сервер: всего файлов $remote_total"
echo "  Локальный бэкап: всего файлов $local_total"
echo

echo "== ⚪️ Сравниваю списки HASH’ей =="
if diff -u "$tmp_remote_first" "$tmp_local_first" > /dev/null; then
  echo "✅ Списки хешей (первые столбцы) совпадают."
  rm -f "$TMP_LOG"
else
  echo "❌ Списки хешей различаются."
  safe_type=${RSNAPSHOT_TYPE//[^A-Za-z0-9_.-]/_}
  errfile="${SCRIPT_DIR}/error-${LOG_TS}-${safe_type}-${SSH_SERVER}.log"
  mv "$TMP_LOG" "$errfile"
  echo "Лог сохранён в: $errfile"
  send_telegram "Цель бэкапа: ${RSNAPSHOT_TYPE} | ${SSH_SERVER}:${SSH_PATH} | 🚨 Проверка контрольной суммы не пройдена! Лог: ${errfile}"
fi

echo
echo "⚠️  Скрипт завершён: $(date '+%Y-%m-%d %H:%M:%S')"%   
