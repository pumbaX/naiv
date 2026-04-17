#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backups"
TMPDIR_BUILD="/root/naiveproxy-build-tmp"
GO_TAR="/tmp/go.tar.gz"
MAX_BACKUPS="${MAX_BACKUPS:-10}"  # сколько бэкапов хранить

# ─── Cleanup ───────────────────────────────────────────────
cleanup() {
  rm -f "$GO_TAR" 2>/dev/null || true
  [[ -d "$TMPDIR_BUILD" ]] && rm -rf "$TMPDIR_BUILD" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Helpers ───────────────────────────────────────────────
need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "❌ Run as root"; exit 1; }
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }
}

ensure_pkgs() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget git openssl ufw dnsutils jq ca-certificates qrencode
}

ensure_caddy_running() {
  systemctl is-active --quiet caddy || {
    echo "❌ Caddy не запущен. Запустите: systemctl start caddy"
    exit 1
  }
}

# ─── Detect arch ───────────────────────────────────────────
detect_go_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv6l" ;;
    *)       echo "❌ Неподдерживаемая архитектура: $machine"; exit 1 ;;
  esac
}

# ─── Install Go + build caddy (единая функция) ────────────
build_caddy() {
  local go_arch
  go_arch="$(detect_go_arch)"

  local go_version
  go_version="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"
  echo "📦 Go $go_version ($go_arch)"

  wget -q "https://go.dev/dl/${go_version}.linux-${go_arch}.tar.gz" -O "$GO_TAR"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$GO_TAR"
  export PATH="/usr/local/go/bin:/root/go/bin:$PATH"

  mkdir -p "$TMPDIR_BUILD"
  export TMPDIR="$TMPDIR_BUILD"

  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

  # Собираем в фиксированную директорию
  cd "$TMPDIR_BUILD"
  /root/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

  mv "$TMPDIR_BUILD/caddy" /usr/bin/caddy
  chmod +x /usr/bin/caddy
  cd /root

  echo "✔ Caddy собран: $(caddy version 2>/dev/null || echo 'ok')"
}

# ─── Systemd unit ──────────────────────────────────────────
ensure_systemd_unit() {
  local unit="/etc/systemd/system/caddy.service"
  if [[ -f "$unit" ]]; then
    return 0
  fi
  echo "📝 Создаю systemd unit..."
  cat > "$unit" <<'UNIT'
[Unit]
Description=Caddy (NaiveProxy)
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  echo "✔ Systemd unit создан"
}

# ─── Backup ────────────────────────────────────────────────
backup_now() {
  [[ -f "$CONFIG" ]] || { echo "⚠️ Конфиг не найден, бэкап пропущен"; return 0; }
  mkdir -p "$BACKUP_DIR"
  local f="$BACKUP_DIR/caddy_$(date +%Y%m%d_%H%M%S).bak"
  cp "$CONFIG" "$f"
  echo "✔ Backup: $f"

  # Авто-чистка: оставляем последние $MAX_BACKUPS
  local count
  count=$(ls -1 "$BACKUP_DIR"/caddy_*.bak 2>/dev/null | wc -l)
  if [[ "$count" -gt "$MAX_BACKUPS" ]]; then
    local to_delete=$((count - MAX_BACKUPS))
    ls -1t "$BACKUP_DIR"/caddy_*.bak 2>/dev/null | tail -n "$to_delete" | xargs -r rm -f
    echo "  ↳ удалено старых бэкапов: $to_delete (оставлено: $MAX_BACKUPS)"
  fi
}

# ─── Validate config before applying ──────────────────────
apply_new_config() {
  local new_config="$1"

  # Причёсываем форматирование (убирает WARN about formatting)
  caddy fmt --overwrite "$new_config" 2>/dev/null || true

  if ! caddy validate --config "$new_config" 2>/dev/null; then
    echo "❌ Новый конфиг невалиден! Откат."
    rm -f "$new_config"
    exit 1
  fi

  mv "$new_config" "$CONFIG"
  caddy reload --config "$CONFIG" --force
  echo "✔ Конфиг применён"
}

# ─── Parse domain from Caddyfile ───────────────────────────
get_domain() {
  awk '
    /:443/ {
      n = split($0, tokens, /[[:space:],{}]+/)
      for (i = 1; i <= n; i++) {
        t = tokens[i]
        if (t == "" || t == ":443" || t ~ /^:/) continue
        if (t ~ /@/) continue
        if (t ~ /\./ && t !~ /:/) { print t; exit }
      }
    }
  ' "$CONFIG"
}

# ─── Validation ────────────────────────────────────────────
validate_user() {
  [[ -n "$1" ]] || { echo "❌ Пустой логин"; exit 1; }
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "❌ Невалидный логин (допустимы: A-Za-z0-9_-)"
    exit 1
  }
}

validate_password() {
  [[ -n "$1" ]] || { echo "❌ Пустой пароль"; exit 1; }
  if [[ "$1" =~ [[:space:]\"\'\\\`] ]]; then
    echo "❌ Пароль содержит недопустимые символы (пробел, кавычки, бэкслеш)"
    exit 1
  fi
}

gen_random() {
  # $1 = длина (по умолчанию 16)
  local len="${1:-16}"
  local result
  result="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len")"
  [[ -n "$result" ]] || { echo "❌ Не удалось сгенерировать случайную строку"; exit 1; }
  echo "$result"
}

# Спрашивает логин и пароль с выбором: сгенерировать или ввести вручную
# Устанавливает глобальные переменные _LOGIN и _PASSWORD
ask_credentials() {
  echo ""
  echo "  Логин:"
  echo "  1) Сгенерировать"
  echo "  2) Ввести вручную"
  read -rp "  [1/2]: " choice
  case "$choice" in
    1)
      _LOGIN="$(gen_random 12)"
      echo "  → Логин: $_LOGIN"
      ;;
    2)
      read -rp "  Login: " _LOGIN
      ;;
    *)
      _LOGIN="$(gen_random 12)"
      echo "  → Логин: $_LOGIN"
      ;;
  esac
  validate_user "$_LOGIN"

  echo ""
  echo "  Пароль:"
  echo "  1) Сгенерировать"
  echo "  2) Ввести вручную"
  read -rp "  [1/2]: " choice
  case "$choice" in
    1)
      _PASSWORD="$(gen_random 24)"
      echo "  → Пароль: $_PASSWORD"
      ;;
    2)
      read -rsp "  Password (скрытый ввод): " _PASSWORD
      echo ""
      ;;
    *)
      _PASSWORD="$(gen_random 24)"
      echo "  → Пароль: $_PASSWORD"
      ;;
  esac
  validate_password "$_PASSWORD"
}

# ─── Client lines ─────────────────────────────────────────
list_clients_lines() {
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*basic_auth[[:space:]]+/ {print}
  ' "$CONFIG"
}

user_exists() {
  local u="$1"
  list_clients_lines | awk '{print $2}' | grep -Fxq "$u"
}

# Возвращает массив имён пользователей
get_users_array() {
  list_clients_lines | awk '{print $2}'
}

# Интерактивный выбор клиента по номеру. Возвращает имя в stdout.
# Использование: user="$(pick_client)" || return
pick_client() {
  local -a users=()
  while IFS= read -r u; do
    [[ -n "$u" ]] && users+=("$u")
  done < <(get_users_array)

  if [[ ${#users[@]} -eq 0 ]]; then
    echo "❌ Клиентов нет" >&2
    return 1
  fi

  echo "" >&2
  echo "  Выберите клиента:" >&2
  local i=1
  for u in "${users[@]}"; do
    printf "    %2d) %s\n" "$i" "$u" >&2
    ((i++))
  done
  echo "     0) Отмена" >&2
  echo "" >&2

  local num
  read -rp "  Номер [1-${#users[@]}]: " num

  [[ "$num" == "0" ]] && return 1
  [[ "$num" =~ ^[0-9]+$ ]] || { echo "❌ Не число" >&2; return 1; }
  [[ "$num" -ge 1 && "$num" -le ${#users[@]} ]] || { echo "❌ Вне диапазона" >&2; return 1; }

  echo "${users[$((num-1))]}"
}

# ─── List clients ─────────────────────────────────────────
list_clients() {
  local domain
  domain="$(get_domain)"
  [[ -n "$domain" ]] || { echo "❌ Домен не найден в конфиге"; exit 1; }

  echo ""
  echo "  Домен: $domain"
  echo "  ════════════════════════════════════════"
  local count=0
  while IFS=' ' read -r _ user pass _rest; do
    [[ -n "$user" && -n "$pass" ]] || continue
    ((count++)) || true
    printf "  [%d] %s\n" "$count" "$user"
    echo "      naive+https://${user}:${pass}@${domain}:443"
    echo ""
  done < <(list_clients_lines)

  if [[ $count -eq 0 ]]; then
    echo "  ⚠️ Клиентов нет"
  else
    echo "  Всего: $count"
  fi
}

# ─── Add client ────────────────────────────────────────────
add_client() {
  ensure_caddy_running
  local user="$1" pass="$2"
  validate_user "$user"
  validate_password "$pass"
  user_exists "$user" && { echo "❌ Пользователь '$user' уже существует"; exit 1; }

  backup_now

  awk -v u="$user" -v p="$pass" '
    BEGIN { added = 0 }
    {
      print $0
      if ($0 ~ /forward_proxy[[:space:]]*\{/) {
        print "    basic_auth " u " " p
        added = 1
      }
    }
    END {
      if (!added) exit 2
    }
  ' "$CONFIG" > "${CONFIG}.new"

  apply_new_config "${CONFIG}.new"

  local domain
  domain="$(get_domain)"
  echo "✔ naive+https://${user}:${pass}@${domain}:443"
}

# ─── Delete client ─────────────────────────────────────────
delete_client() {
  ensure_caddy_running
  local user="$1"
  validate_user "$user"
  user_exists "$user" || { echo "❌ Нет такого пользователя: $user"; exit 1; }

  backup_now

  awk -v u="$user" '
    /^[[:space:]]*basic_auth[[:space:]]+/ {
      if ($2 == u) next
    }
    { print }
  ' "$CONFIG" > "${CONFIG}.new"

  apply_new_config "${CONFIG}.new"
  echo "✔ Удалён: $user"
}

# ─── Change password ──────────────────────────────────────
change_password() {
  ensure_caddy_running
  local user="$1" newpass="$2"
  validate_user "$user"
  validate_password "$newpass"
  user_exists "$user" || { echo "❌ Нет такого пользователя: $user"; exit 1; }

  backup_now

  awk -v u="$user" -v p="$newpass" '
    /^[[:space:]]*basic_auth[[:space:]]+/ {
      if ($2 == u) {
        print "    basic_auth " u " " p
        next
      }
    }
    { print }
  ' "$CONFIG" > "${CONFIG}.new"

  apply_new_config "${CONFIG}.new"

  local domain
  domain="$(get_domain)"
  echo "✔ naive+https://${user}:${newpass}@${domain}:443"
}

# ─── Restore backup ───────────────────────────────────────
restore_backup() {
  ensure_caddy_running
  [[ -d "$BACKUP_DIR" ]] || { echo "❌ Нет директории бэкапов"; return 1; }

  local -a files=()
  while IFS= read -r f; do
    [[ -f "$BACKUP_DIR/$f" ]] && files+=("$f")
  done < <(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r)

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "❌ Бэкапов нет"
    return 1
  fi

  echo ""
  echo "  Доступные бэкапы:"
  echo "  ────────────────────────────────────────"
  local i=1
  for f in "${files[@]}"; do
    local date_str
    date_str="$(stat -c '%y' "$BACKUP_DIR/$f" 2>/dev/null | cut -d. -f1)"
    printf "    %2d) %s  (%s)\n" "$i" "$f" "${date_str:-?}"
    ((i++))
  done
  echo "     0) Отмена"
  echo ""

  local num
  read -rp "  Номер бэкапа: " num
  [[ "$num" == "0" ]] && { echo "Отмена"; return 0; }
  [[ "$num" =~ ^[0-9]+$ ]] || { echo "❌ Не число"; return 1; }
  [[ "$num" -ge 1 && "$num" -le ${#files[@]} ]] || { echo "❌ Вне диапазона"; return 1; }

  local chosen="${files[$((num-1))]}"

  read -rp "  Восстановить '$chosen'? Текущий конфиг будет сохранён в новый бэкап. (y/n): " yn
  [[ "$yn" == "y" ]] || { echo "Отмена"; return 0; }

  # Сохраним текущий конфиг перед восстановлением
  backup_now

  if ! caddy validate --config "$BACKUP_DIR/$chosen" 2>/dev/null; then
    echo "❌ Бэкап невалиден!"
    return 1
  fi

  cp "$BACKUP_DIR/$chosen" "$CONFIG"
  caddy reload --config "$CONFIG" --force
  echo "✔ Восстановлено из: $chosen"
}

# ─── Export JSON ───────────────────────────────────────────
export_json() {
  require_cmd jq
  local domain
  domain="$(get_domain)"
  [[ -n "$domain" ]] || { echo "❌ Домен не найден"; exit 1; }

  local results=()
  while IFS=' ' read -r _ user pass _rest; do
    [[ -n "$user" && -n "$pass" ]] || continue
    results+=("$(jq -n \
      --arg server "$domain" \
      --arg user "$user" \
      --arg pass "$pass" \
      '{
        type: "naive",
        tag: $user,
        server: $server,
        port: 443,
        username: $user,
        password: $pass,
        tls: true
      }')")
  done < <(list_clients_lines)

  if [[ ${#results[@]} -eq 0 ]]; then
    echo "⚠️ Клиентов нет"
    return
  fi

  printf '%s\n' "${results[@]}" | jq -s '.'
}

# ─── Install / Reinstall ──────────────────────────────────
install_or_reinstall() {
  read -rp "Домен: " DOMAIN
  [[ -n "$DOMAIN" ]] || { echo "❌ Пустой домен"; exit 1; }

  # DNS check
  local server_ip domain_ip
  server_ip="$(curl -4 -s --connect-timeout 5 ifconfig.me || true)"
  domain_ip="$(dig +short A "$DOMAIN" | head -n1 || true)"
  echo "Server IP: ${server_ip:-не определён}"
  echo "Domain IP: ${domain_ip:-не определён}"
  if [[ -n "$server_ip" && -n "$domain_ip" && "$server_ip" != "$domain_ip" ]]; then
    read -rp "⚠️ DNS mismatch! Продолжить? (y/n): " yn
    [[ "$yn" == "y" ]] || exit 1
  fi

  # Check ports
  for PORT in 80 443; do
    if ss -tlnp | grep -q ":${PORT} "; then
      echo "❌ Порт $PORT занят:"
      ss -tlnp | grep ":${PORT} " || true
      exit 1
    fi
  done

  # Email для TLS (Let's Encrypt)
  echo ""
  echo "  Email для TLS-сертификата:"
  echo "  1) Тестовый (admin@example.com) — только для проверки, не использовать на реальном сервере!"
  echo "  2) Ввести свой рабочий email (рекомендуется)"
  read -rp "  [1/2]: " choice
  case "$choice" in
    1)
      EMAIL="admin@example.com"
      echo ""
      echo "  ⚠️  ВНИМАНИЕ: тестовый email."
      echo "  ⚠️  Let's Encrypt не сможет прислать уведомления об истечении сертификата."
      echo "  ⚠️  Используй этот вариант только для теста/одноразового сервера."
      read -rp "  Продолжить с тестовым email? (y/n): " yn
      [[ "$yn" == "y" ]] || exit 1
      ;;
    2|*)
      read -rp "  Email: " EMAIL
      [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || {
        echo "❌ Невалидный email"; exit 1
      }
      # Защита от случайного ввода example.com
      if [[ "$EMAIL" =~ @(example\.(com|org|net)|localhost)$ ]]; then
        echo "⚠️  Этот домен зарезервирован для тестов (example.com/org/net)."
        read -rp "  Всё равно использовать? (y/n): " yn
        [[ "$yn" == "y" ]] || exit 1
      fi
      ;;
  esac
  echo "  → Email: $EMAIL"

  ask_credentials
  local LOGIN="$_LOGIN"
  local PASSWORD="$_PASSWORD"

  ensure_pkgs

  # BBR (Шаг 2 из мануала)
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "📶 Включаю BBR..."
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null \
      || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null \
      || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "✔ BBR включён"
  else
    echo "✔ BBR уже активен"
  fi

  # Firewall
  ufw allow 22/tcp  2>/dev/null || true
  ufw allow 80/tcp  2>/dev/null || true
  ufw allow 443/tcp 2>/dev/null || true
  ufw allow 443/udp 2>/dev/null || true
  ufw --force enable 2>/dev/null || true

  build_caddy

  mkdir -p /var/www/html /etc/caddy

  # Камуфляжная страница (Шаг 7 из мануала)
  if [[ ! -f /var/www/html/index.html ]]; then
    cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style></head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
HTMLEOF
    echo "✔ Камуфляжная страница создана"
  fi

  if [[ -f "$CONFIG" ]]; then
    read -rp "⚠️ Конфиг уже существует. Перезаписать? (y/n): " yn
    [[ "$yn" == "y" ]] || exit 1
    backup_now
  fi

  cat > "$CONFIG" <<EOF
{
  order forward_proxy before file_server
}

:443, ${DOMAIN} {
  tls ${EMAIL}

  forward_proxy {
    basic_auth ${LOGIN} ${PASSWORD}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
EOF

  # Причёсываем форматирование
  caddy fmt --overwrite "$CONFIG" 2>/dev/null || true

  if ! caddy validate --config "$CONFIG"; then
    echo "❌ Сгенерированный конфиг невалиден!"
    exit 1
  fi

  ensure_systemd_unit
  systemctl daemon-reload
  systemctl enable caddy
  systemctl restart caddy

  echo ""
  echo "═══════════════════════════════════════════"
  echo "  ✔ NaïveProxy установлен"
  echo "  naive+https://${LOGIN}:${PASSWORD}@${DOMAIN}:443"
  echo "═══════════════════════════════════════════"
}

# ─── Update Caddy ─────────────────────────────────────────
update_caddy() {
  ensure_caddy_running
  ensure_pkgs
  backup_now
  build_caddy
  systemctl restart caddy
  echo "✔ Caddy обновлён: $(caddy version 2>/dev/null || echo 'ok')"
}

# ─── Uninstall ─────────────────────────────────────────────
uninstall() {
  echo ""
  echo "  ⚠️  ВНИМАНИЕ: будет удалён Caddy, конфиг и systemd unit."
  echo "  Бэкапы в $BACKUP_DIR и конфиг в $CONFIG СОХРАНЯТСЯ."
  echo ""
  read -rp "  Вы уверены? (y/n): " yn
  [[ "$yn" == "y" ]] || { echo "Отмена"; return 0; }

  read -rp "  Точно? Это необратимо. Введите 'YES' заглавными: " yes2
  [[ "$yes2" == "YES" ]] || { echo "Отмена"; return 0; }

  systemctl stop caddy 2>/dev/null || true
  systemctl disable caddy 2>/dev/null || true
  rm -f /etc/systemd/system/caddy.service
  rm -f /usr/bin/caddy
  systemctl daemon-reload

  echo ""
  echo "  ✔ Удалено."
  echo "  Конфиг сохранён: $CONFIG"
  echo "  Бэкапы сохранены: $BACKUP_DIR"
}

# ─── Show QR code ─────────────────────────────────────────
show_qr() {
  local domain
  domain="$(get_domain)"
  [[ -n "$domain" ]] || { echo "❌ Домен не найден"; return 1; }

  # Проверим qrencode
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "📦 Устанавливаю qrencode..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >/dev/null 2>&1 || {
      echo "❌ Не удалось установить qrencode"
      return 1
    }
  fi

  local user
  user="$(pick_client)" || { echo "Отмена"; return 0; }

  # Достаём пароль этого пользователя
  local pass
  pass=$(list_clients_lines | awk -v u="$user" '$2 == u {print $3; exit}')
  [[ -n "$pass" ]] || { echo "❌ Не нашёл пароль для '$user'"; return 1; }

  local url="naive+https://${user}:${pass}@${domain}:443"

  echo ""
  echo "  Ссылка для '$user':"
  echo "  $url"
  echo ""
  echo "  QR-код (отсканируй телефоном → импорт в Karing/NekoBox):"
  echo ""
  qrencode -t ANSIUTF8 -m 2 "$url"
  echo ""
}

# ─── Diagnose ─────────────────────────────────────────────
diagnose() {
  echo ""
  echo "  ═══════════ ДИАГНОСТИКА ═══════════"

  local ok=0 warn=0 err=0
  local ok_mark="🟢" warn_mark="🟡" err_mark="🔴"

  # 1. Caddy бинарник
  if command -v caddy >/dev/null 2>&1; then
    local ver
    ver="$(caddy version 2>/dev/null | awk '{print $1}' | head -1)"
    echo "  $ok_mark Caddy установлен: $ver"
    ((ok++))
  else
    echo "  $err_mark Caddy не установлен. Выполни установку (пункт 1)"
    ((err++))
    echo ""
    return 1
  fi

  # 2. Systemd unit
  if [[ -f /etc/systemd/system/caddy.service ]]; then
    echo "  $ok_mark Systemd unit существует"
    ((ok++))
  else
    echo "  $err_mark Нет systemd unit — переустанови"
    ((err++))
  fi

  # 3. Caddy running
  if systemctl is-active --quiet caddy 2>/dev/null; then
    echo "  $ok_mark Caddy запущен"
    ((ok++))
  else
    echo "  $err_mark Caddy не запущен. Запустить: systemctl start caddy"
    ((err++))
  fi

  # 4. Config existing & valid
  if [[ -f "$CONFIG" ]]; then
    if caddy validate --config "$CONFIG" >/dev/null 2>&1; then
      echo "  $ok_mark Caddyfile валиден"
      ((ok++))
    else
      echo "  $err_mark Caddyfile невалиден! Проверь: caddy validate --config $CONFIG"
      ((err++))
    fi
  else
    echo "  $err_mark Нет конфига: $CONFIG"
    ((err++))
  fi

  # 5. Domain parsing
  local domain
  domain="$(get_domain)"
  if [[ -n "$domain" ]]; then
    echo "  $ok_mark Домен в конфиге: $domain"
    ((ok++))
  else
    echo "  $err_mark Домен не найден в конфиге"
    ((err++))
    echo ""
    echo "  Дальнейшие проверки пропущены."
    return 1
  fi

  # 6. DNS check
  local server_ip domain_ip
  server_ip="$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo '')"
  domain_ip="$(dig +short A "$domain" 2>/dev/null | head -n1 || echo '')"
  if [[ -z "$server_ip" ]]; then
    echo "  $warn_mark Не смог определить IP сервера (нет интернета?)"
    ((warn++))
  elif [[ -z "$domain_ip" ]]; then
    echo "  $err_mark DNS домена $domain не резолвится"
    ((err++))
  elif [[ "$server_ip" == "$domain_ip" ]]; then
    echo "  $ok_mark DNS: $domain → $domain_ip (совпадает с IP сервера)"
    ((ok++))
  else
    echo "  $err_mark DNS несовпадение: сервер=$server_ip, домен=$domain_ip"
    echo "          → TLS сертификат не выпустится пока не починишь A-запись"
    ((err++))
  fi

  # 7. Port 443 TCP
  if ss -tln 2>/dev/null | awk '$4 ~ /:443$/ {exit 0} END {exit 1}'; then
    local pid_name
    pid_name=$(ss -tlnp 2>/dev/null | grep ":443 " | head -1 | grep -oP 'users:\(\("\K[^"]+' | head -1)
    echo "  $ok_mark TCP/443 слушает: ${pid_name:-?}"
    ((ok++))
  else
    echo "  $err_mark TCP/443 не слушает никто!"
    ((err++))
  fi

  # 8. Port 443 UDP (QUIC)
  if ss -uln 2>/dev/null | awk '$4 ~ /:443$/ {exit 0} END {exit 1}'; then
    echo "  $ok_mark UDP/443 слушает (QUIC/HTTP3)"
    ((ok++))
  else
    echo "  $warn_mark UDP/443 не слушает (QUIC не работает, но не критично)"
    ((warn++))
  fi

  # 9. TLS certificate
  if [[ -n "$domain" ]]; then
    local tls_out
    tls_out=$(timeout 5 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
    if [[ -n "$tls_out" ]]; then
      local expires
      expires=$(echo "$tls_out" | grep "notAfter" | cut -d= -f2)
      echo "  $ok_mark TLS сертификат активен, действует до: $expires"
      ((ok++))
    else
      echo "  $err_mark Не удалось получить TLS сертификат от $domain:443"
      ((err++))
    fi
  fi

  # 10. Probe resistance — ответ на запрос без auth должен быть HTML
  if [[ -n "$domain" ]]; then
    local http_code
    http_code=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" "https://${domain}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      echo "  $ok_mark Камуфляжная страница отвечает (HTTP 200)"
      ((ok++))
    elif [[ "$http_code" == "000" ]]; then
      echo "  $warn_mark Не смог подключиться к $domain (фаерволл?)"
      ((warn++))
    else
      echo "  $warn_mark Домен отдаёт HTTP $http_code (ожидалось 200)"
      ((warn++))
    fi
  fi

  # 11. BBR
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "  $ok_mark BBR включён"
    ((ok++))
  else
    echo "  $warn_mark BBR не включён (скорость может быть ниже)"
    ((warn++))
  fi

  # 12. Clients count
  local cnt
  cnt=$(list_clients_lines 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$cnt" -gt 0 ]]; then
    echo "  $ok_mark Клиентов настроено: $cnt"
    ((ok++))
  else
    echo "  $warn_mark Нет настроенных клиентов (добавь через пункт 4)"
    ((warn++))
  fi

  echo ""
  echo "  ═══════════ ИТОГО ═══════════"
  echo "  🟢 OK: $ok   🟡 Warn: $warn   🔴 Err: $err"
  echo ""

  if [[ $err -eq 0 && $warn -eq 0 ]]; then
    echo "  ✔ Всё в порядке!"
  elif [[ $err -eq 0 ]]; then
    echo "  ⚠️  Есть предупреждения, но критичного ничего."
  else
    echo "  ❌ Есть ошибки, требуется внимание."
  fi
}

# ─── Service control ──────────────────────────────────────
service_control() {
  echo ""
  echo "  Управление сервисом Caddy:"
  echo "    1) Запустить (start)"
  echo "    2) Остановить (stop)"
  echo "    3) Перезапустить (restart)"
  echo "    4) Статус (status)"
  echo "    0) Назад"
  echo ""
  read -rp "  Выбор: " sc

  case "$sc" in
    1)
      if systemctl start caddy; then
        echo "✔ Caddy запущен"
      else
        echo "❌ Не удалось запустить. Смотри логи (пункт 12)"
      fi
      ;;
    2)
      read -rp "  ⚠️  Остановить Caddy? Все клиенты потеряют связь. (y/n): " yn
      [[ "$yn" == "y" ]] || { echo "Отмена"; return 0; }
      if systemctl stop caddy; then
        echo "✔ Caddy остановлен"
      else
        echo "❌ Не удалось остановить"
      fi
      ;;
    3)
      if systemctl restart caddy; then
        echo "✔ Caddy перезапущен"
      else
        echo "❌ Не удалось перезапустить. Смотри логи (пункт 12)"
      fi
      ;;
    4)
      echo ""
      systemctl status caddy --no-pager 2>&1 | head -20
      ;;
    0) return 0 ;;
    *) echo "❌ Неверный выбор" ;;
  esac
}

# ─── List backups ─────────────────────────────────────────
list_backups() {
  [[ -d "$BACKUP_DIR" ]] || { echo "⚠️ Нет директории бэкапов"; return 1; }

  local -a files=()
  while IFS= read -r f; do
    [[ -f "$BACKUP_DIR/$f" ]] && files+=("$f")
  done < <(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r)

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "⚠️ Бэкапов нет"
    return 1
  fi

  echo ""
  echo "  Бэкапы в $BACKUP_DIR:"
  echo "  ────────────────────────────────────────"
  local i=1
  for f in "${files[@]}"; do
    local date_str
    date_str="$(stat -c '%y' "$BACKUP_DIR/$f" 2>/dev/null | cut -d. -f1)"
    printf "    %2d) %s  (%s)\n" "$i" "$f" "${date_str:-?}"
    ((i++))
  done
  echo "  Всего: ${#files[@]}"
}

# ─── Status display ────────────────────────────────────────
show_status() {
  echo ""
  echo "  ┌─────────────────────────────────────────────┐"

  # Caddy status
  if systemctl is-active --quiet caddy 2>/dev/null; then
    echo "  │ Caddy:      🟢 работает"
  else
    echo "  │ Caddy:      🔴 не запущен"
  fi

  # Config + domain
  if [[ -f "$CONFIG" ]]; then
    local domain
    domain="$(get_domain 2>/dev/null || echo '')"
    if [[ -n "$domain" ]]; then
      echo "  │ Домен:      $domain"
    else
      echo "  │ Домен:      не найден в конфиге"
    fi

    # Clients count
    local cnt
    cnt=$(list_clients_lines 2>/dev/null | wc -l | tr -d ' ')
    echo "  │ Клиентов:   ${cnt:-0}"
  else
    echo "  │ Конфиг:     не установлен"
  fi

  # Caddy binary version
  if command -v caddy >/dev/null 2>&1; then
    local ver
    ver="$(caddy version 2>/dev/null | awk '{print $1}' | head -1)"
    echo "  │ Caddy ver:  ${ver:-unknown}"
  fi

  # Port listening
  local p443_tcp p443_udp
  p443_tcp=$(ss -tln 2>/dev/null | awk '$4 ~ /:443$/ {print "TCP"; exit}')
  p443_udp=$(ss -uln 2>/dev/null | awk '$4 ~ /:443$/ {print "UDP"; exit}')
  if [[ -n "$p443_tcp" || -n "$p443_udp" ]]; then
    echo "  │ :443:       ${p443_tcp:-}${p443_udp:+ ${p443_udp}}"
  fi

  echo "  └─────────────────────────────────────────────┘"
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
need_root

# Безопасный запуск действия в subshell — ошибка не убьёт меню
run_action() {
  ( "$@" ) || echo "⚠️ Действие завершилось с ошибкой"
}

while true; do
  clear 2>/dev/null || printf '\n\n\n'
  echo ""
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║         NaïveProxy Manager                ║"
  echo "  ╚═══════════════════════════════════════════╝"

  show_status

  echo ""
  echo "  1)  Install"
  echo "  2)  Update Caddy"
  echo "  3)  Reinstall"
  echo "  ─"
  echo "  4)  Add client"
  echo "  5)  List clients"
  echo "  6)  Delete client"
  echo "  7)  Change password"
  echo "  8)  Show QR code"
  echo "  ─"
  echo "  9)  Backup config"
  echo "  10) Restore backup"
  echo "  11) Export JSON"
  echo "  ─"
  echo "  12) Show config"
  echo "  13) Show logs"
  echo "  14) Service control (start/stop/restart)"
  echo "  15) Diagnose"
  echo "  16) Uninstall"
  echo "  0)  Exit"
  echo ""

  read -rp "  Выбор: " MODE

  case "$MODE" in
    0)
      echo "👋 Выход"
      exit 0
      ;;
    1)  run_action install_or_reinstall ;;
    2)  run_action update_caddy ;;
    3)  run_action install_or_reinstall ;;
    4)
      (
        ask_credentials
        add_client "$_LOGIN" "$_PASSWORD"
      ) || echo "⚠️ Не удалось добавить клиента"
      ;;
    5)  run_action list_clients ;;
    6)
      (
        U="$(pick_client)" || { echo "Отмена"; exit 0; }
        echo ""
        read -rp "  Удалить клиента '$U'? (y/n): " yn
        [[ "$yn" == "y" ]] || { echo "Отмена"; exit 0; }
        delete_client "$U"
      ) || echo "⚠️ Не удалось удалить"
      ;;
    7)
      (
        U="$(pick_client)" || { echo "Отмена"; exit 0; }
        echo ""
        echo "  Новый пароль для '$U':"
        echo "    1) Сгенерировать"
        echo "    2) Ввести вручную"
        read -rp "  [1/2]: " choice
        case "$choice" in
          2)
            read -rsp "  Password (скрытый ввод): " NEWPASS
            echo ""
            ;;
          *)
            NEWPASS="$(gen_random 24)"
            echo "  → Пароль: $NEWPASS"
            ;;
        esac
        validate_password "$NEWPASS"
        change_password "$U" "$NEWPASS"
      ) || echo "⚠️ Не удалось сменить пароль"
      ;;
    8)  run_action show_qr ;;
    9)  run_action backup_now ;;
    10) run_action restore_backup ;;
    11) run_action export_json ;;
    12)
      echo ""
      if [[ -f "$CONFIG" ]]; then
        echo "  ─── $CONFIG ───"
        echo ""
        cat "$CONFIG"
        echo ""
        echo "  ─── конец ───"
      else
        echo "  ⚠️ Конфиг не найден: $CONFIG"
      fi
      ;;
    13)
      echo ""
      echo "  ─── Последние 30 строк лога Caddy ───"
      echo ""
      journalctl -u caddy --no-pager -n 30 2>/dev/null || echo "  ⚠️ Логи не найдены"
      echo ""
      echo "  ─── конец (для live-лога: journalctl -u caddy -f) ───"
      ;;
    14) run_action service_control ;;
    15) run_action diagnose ;;
    16) run_action uninstall ;;
    *)
      echo "❌ Неверный выбор"
      ;;
  esac

  echo ""
  read -rp "  ↵ Нажми Enter чтобы вернуться в меню..." _
done
