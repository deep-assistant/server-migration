#!/bin/bash


set -e

# Проверка свободного места на диске (функция)
check_disk_space() {
  local min_gb=$1
  local avail_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  if [ "$avail_gb" -lt "$min_gb" ]; then
    echo "[ERROR] Недостаточно места на диске! Требуется минимум ${min_gb}ГБ, доступно: ${avail_gb}ГБ" >&2
    exit 1
  fi
}

# Проверка открытых портов (функция)
check_ports() {
  local ports=(80 443 8080 1337 5432)
  for port in "${ports[@]}"; do
    if ! ss -tuln | grep -q ":$port "; then
      echo "[WARNING] Порт $port не слушает! Проверьте настройки firewall/security groups."
    else
      echo "[INFO] Порт $port открыт."
    fi
  done
}

# Функция для scp/ssh с паролем через expect
expect_scp() {
  local SRC=$1
  local DST=$2
  local PASS=$3
  expect << EOF
spawn scp -o StrictHostKeyChecking=no $SRC $DST
expect {
  "*assword:" { send "$PASS\r"; exp_continue }
  eof
}
EOF
}

expect_ssh() {
  local HOST=$1
  local PASS=$2
  local CMD=$3
  expect << EOF
spawn ssh -o StrictHostKeyChecking=no $HOST "$CMD"
expect {
  "*assword:" { send "$PASS\r"; exp_continue }
  eof
}
EOF
}

# === Ввод данных пользователя ===
read -p "Введите имя пользователя для SSH: " USER
read -p "Введите IP-адрес сервера: " HOST
read -s -p "Введите пароль для SSH: " PASSWORD
export USER
export HOST
export PASSWORD
echo

# Убедитесь, что sshpass установлен:
if ! command -v sshpass &> /dev/null; then
  echo "[INFO] Устанавливаю sshpass..."
  if [ -f /etc/debian_version ]; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass || { echo "[ERROR] Не удалось установить sshpass!" >&2; exit 1; }
  else
    echo "[ERROR] Установите sshpass вручную для вашей ОС!" >&2
    exit 1
  fi
fi

# === 0. Определяем пользователя Postgres из .env или .env-prod ===
DB_USER=$(grep -E '^POSTGRES_USER=' $WORKDIR/GPT/.env 2>/dev/null | cut -d'=' -f2)
if [ -z "$DB_USER" ]; then
  DB_USER=$(grep -E '^POSTGRES_USER=' $WORKDIR/GPT/.env-prod 2>/dev/null | cut -d'=' -f2)
fi
if [ -z "$DB_USER" ]; then
  DB_USER="postgres" # fallback
fi
echo "[INFO] Используется пользователь Postgres: $DB_USER"

# === 1. Делаем дамп всех баз ===
if [ -f /tmp/all_pg_dump.sql ]; then
  echo "[INFO] Дамп базы уже существует, пропускаю создание."
else
  if ! docker ps | grep -q postgresql-prod; then
    echo "[ERROR] Контейнер postgresql-prod не запущен!" >&2
    exit 1
  fi
  docker exec -t postgresql-prod pg_dumpall -U "$DB_USER" > /tmp/all_pg_dump.sql
fi

# === 2. Архивируем всю рабочую директорию (root) ===
if [ -f "$ARCHIVE" ]; then
  echo "[INFO] Архив уже существует, пропускаю архивацию."
else
  echo "[INFO] Проверяю свободное место перед архивацией..."
  check_disk_space 5 # Требуем минимум 5ГБ (пример)
  cd "$WORKDIR"
  if ! tar czf "$ARCHIVE" .; then
    echo "[ERROR] Ошибка архивации!" >&2
    exit 1
  fi
  echo "[INFO] Архивация завершена. Проверяю свободное место после архивации..."
  check_disk_space 2
fi

# === 3. Копируем архив и дамп на новый сервер ===
sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USER@$HOST 'md5sum /tmp/project_backup.tar.gz /tmp/all_pg_dump.sql 2>/dev/null' > /tmp/remote_md5.txt || true
REMOTE_ARCHIVE_MD5=$(grep project_backup.tar.gz /tmp/remote_md5.txt | awk '{print $1}')
REMOTE_DUMP_MD5=$(grep all_pg_dump.sql /tmp/remote_md5.txt | awk '{print $1}')
LOCAL_ARCHIVE_MD5=$(md5sum "$ARCHIVE" | awk '{print $1}')
LOCAL_DUMP_MD5=$(md5sum /tmp/all_pg_dump.sql | awk '{print $1}')
if [ "$REMOTE_ARCHIVE_MD5" != "$LOCAL_ARCHIVE_MD5" ]; then
  if ! expect_scp "$ARCHIVE" $USER@$HOST:/tmp/ "$PASSWORD"; then
    echo "[ERROR] Ошибка копирования архива по SCP!" >&2
    exit 1
  fi
else
  echo "[INFO] Архив уже актуален на целевом сервере, пропускаю копирование."
fi
if [ "$REMOTE_DUMP_MD5" != "$LOCAL_DUMP_MD5" ]; then
  if ! expect_scp /tmp/all_pg_dump.sql $USER@$HOST:/tmp/ "$PASSWORD"; then
    echo "[ERROR] Ошибка копирования дампа базы по SCP!" >&2
    exit 1
  fi
else
  echo "[INFO] Дамп уже актуален на целевом сервере, пропускаю копирование."
fi

echo "\n[INFO] Если потребуется пароль для SSH, используйте: \n"

# === 4. Создаём скрипт для удалённого выполнения ===
cat > /tmp/remote_migrate.sh <<' '
set -e

check_disk_space() {
  local min_gb=$1
  local avail_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  if [ "$avail_gb" -lt "$min_gb" ]; then
    echo "[ERROR] Недостаточно места на диске! Требуется минимум  [1m${min_gb}ГБ [0m, доступно: ${avail_gb}ГБ" >&2
    exit 1
  fi
}

check_ports() {
  local ports=(80 443 8080 1337 5432)
  for port in "${ports[@]}"; do
    if ! ss -tuln | grep -q ":$port "; then
      echo "[WARNING] Порт $port не слушает! Проверьте настройки firewall/security groups."
    else
      echo "[INFO] Порт $port открыт."
    fi
  done
}

NEWDIR="/root"

# === 5. Устанавливаем docker и docker-compose, если не установлены ===
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v docker-compose &> /dev/null; then
  curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# === 6. Распаковываем архив ===
if [ -d "$NEWDIR/GPT" ]; then
  echo "[INFO] GPT уже распакован, пропускаю распаковку."
else
  echo "[INFO] Проверяю свободное место перед распаковкой..."
  check_disk_space 5
  if [ ! -f /tmp/project_backup.tar.gz ]; then
    echo "[ERROR] Архив не найден!" >&2
    exit 1
  fi
  if ! tar xzf /tmp/project_backup.tar.gz -C $NEWDIR; then
    echo "[ERROR] Ошибка распаковки архива!" >&2
    exit 1
  fi
  echo "[INFO] Распаковка завершена. Проверяю свободное место после распаковки..."
  check_disk_space 2
fi

# === 7. Проверяем docker-compose-prod.yaml и .env ===
cd GPT
if [ ! -f docker-compose-prod.yaml ]; then
  echo "[ERROR] Не найден docker-compose-prod.yaml!"; exit 1
fi
if [ ! -f .env ]; then
  echo "[WARNING] Не найден .env! Проверь переменные окружения вручную."
fi

# === 8. Запускаем все сервисы ===
docker-compose -f docker-compose-prod.yaml up -d --build

# === 9. Восстанавливаем базу Postgres из дампа ===
if ! docker ps | grep -q postgresql-prod; then
  echo "[ERROR] Контейнер postgresql-prod не запущен!" >&2
  exit 1
fi
DB_USER=$(grep -E '^POSTGRES_USER=' /root/GPT/.env 2>/dev/null | cut -d'=' -f2)
if [ -z "$DB_USER" ]; then
  DB_USER=$(grep -E '^POSTGRES_USER=' /root/GPT/.env-prod 2>/dev/null | cut -d'=' -f2)
fi
if [ -z "$DB_USER" ]; then
  DB_USER="postgres"
fi
# Ожидание готовности Postgres
until docker exec postgresql-prod pg_isready -U "$DB_USER"; do
  echo "[INFO] Ожидание готовности Postgres..."; sleep 2;
done
if [ -f /tmp/all_pg_dump.sql ]; then
  echo "[INFO] Восстанавливаю базу Postgres под пользователем: $DB_USER"
  set +e
  docker exec -i postgresql-prod psql -U "$DB_USER" < /tmp/all_pg_dump.sql
  set -e
else
  echo "[WARNING] Дамп базы не найден, пропускаю восстановление."
fi

# === 10. Проверяем статусы контейнеров ===
docker ps
# === 11. Проверяем открытые порты ===
check_ports
# === 13. Запуск Telegram-бота ===
echo "[DEBUG] === Запуск Telegram-бота ==="
echo "[DEBUG] Текущая рабочая директория: $(pwd)"
echo "[DEBUG] Содержимое /root:"
ls -l /root

echo "[DEBUG] Содержимое /root/telegram-bot:"
ls -l /root/telegram-bot

# Переход в директорию telegram-bot
cd /root/telegram-bot || {
    echo "[ERROR] Не удалось перейти в директорию /root/telegram-bot"
    exit 1
}

echo "[DEBUG] Текущая директория после cd: $(pwd)"

# Проверка существования docker-compose.yml
if [ -f docker-compose.yml ]; then
    echo "[INFO] Файл docker-compose.yml найден"
    echo "[DEBUG] Содержимое docker-compose.yml:"
    cat docker-compose.yml
    
    # Проверка синтаксиса docker-compose файла
    echo "[DEBUG] Проверка синтаксиса docker-compose файла:"
    docker-compose config || {
        echo "[ERROR] Ошибка в синтаксисе docker-compose.yml"
        exit 1
    }
    
    # Остановка и удаление старых контейнеров (если есть)
    echo "[INFO] Остановка старых контейнеров..."
    docker-compose down --remove-orphans 2>/dev/null || {
        echo "[WARNING] Не удалось остановить старые контейнеры, возможно их не было"
    }
    
    # Удаление потенциально конфликтующих сетей
    echo "[INFO] Очистка конфликтующих сетей..."
    docker network prune -f 2>/dev/null || true
    
    # Создание переменных окружения для отладки
    export COMPOSE_PROJECT_NAME="telegram-bot"
    export DOCKER_BUILDKIT=1
    export COMPOSE_DOCKER_CLI_BUILD=1
    
    echo "[DEBUG] Переменные окружения:"
    env | grep -E "(COMPOSE|DOCKER)" || true
    
    # Запуск с подробным логированием
    echo "[INFO] Запуск Telegram-бота с подробным логированием..."
    
    # Попытка запуска с детальным выводом ошибок
    if docker-compose up -d --build 2>&1 | tee /tmp/telegram-bot-startup.log; then
        echo "[SUCCESS] Команда docker-compose up завершена успешно"
        
        # Ожидание запуска
        echo "[INFO] Ожидание 10 секунд для запуска контейнеров..."
        sleep 10
        
        # Проверка статуса контейнеров
        echo "[INFO] Проверка статуса контейнеров:"
        docker-compose ps -a
        
        # Проверка логов
        echo "[INFO] Логи Telegram-бота (последние 50 строк):"
        docker-compose logs --tail=50 || {
            echo "[WARNING] Не удалось получить логи через docker-compose"
        }
        
        # Проверка через docker ps
        echo "[INFO] Проверка через docker ps:"
        docker ps -a | grep telegram || {
            echo "[WARNING] Контейнеры telegram не найдены в docker ps"
        }
        
        # Проверка сетей
        echo "[INFO] Проверка сетей:"
        docker network ls | grep telegram || {
            echo "[WARNING] Сети telegram не найдены"
        }
        
    else
        echo "[ERROR] Команда docker-compose up завершилась с ошибкой"
        echo "[ERROR] Содержимое лога запуска:"
        cat /tmp/telegram-bot-startup.log 2>/dev/null || echo "Лог не найден"
        
        # Попытка диагностики
        echo "[DEBUG] Диагностика проблемы:"
        echo "[DEBUG] Статус Docker демона:"
        docker info || echo "Docker info недоступен"
        
        echo "[DEBUG] Проверка образов:"
        docker images | head -10
        
        echo "[DEBUG] Проверка процессов:"
        ps aux | grep docker | head -5
        
        exit 1
    fi
    
else
    echo "[ERROR] Файл docker-compose.yml не найден в /root/telegram-bot"
    echo "[DEBUG] Содержимое директории:"
    ls -la /root/telegram-bot/
    exit 1
fi

echo "[DEBUG] === Завершение запуска Telegram-бота ==="

EOSCRIPT

# === 5. Копируем и запускаем remote_migrate.sh на новом сервере ===
if ! expect_scp /tmp/remote_migrate.sh $USER@$HOST:/tmp/ "$PASSWORD"; then
  echo "[ERROR] Ошибка копирования remote_migrate.sh по SCP!" >&2
  exit 1
fi
if ! expect_ssh $USER@$HOST "$PASSWORD" 'bash /tmp/remote_migrate.sh'; then
  echo "[ERROR] Ошибка запуска remote_migrate.sh на сервере!" >&2
  exit 1
fi

echo "\nПеренос и запуск завершены! Проверь логи и доступность сервисов на новом сервере (vds2783266.my-ihor.ru, 45.89.66.70)." 
