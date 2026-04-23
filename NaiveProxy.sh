#!/usr/bin/env bash
# NaïveProxy Manager-1.2 — Caddy (klzgrad/forwardproxy)
# Архитектура: клиент → Caddy:443 (TLS, Chromium fingerprint) → internet
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# КОНСТАНТЫ
# ═══════════════════════════════════════════════════════════
CONFIG="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backups"
TMPDIR_BUILD="/root/naiveproxy-build-tmp"
GO_TAR="/tmp/go.tar.gz"
MAX_BACKUPS="${MAX_BACKUPS:-10}"

# ═══════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════
cleanup() {
  rm -f "$GO_TAR" 2>/dev/null || true
  [[ -d "$TMPDIR_BUILD" ]] && rm -rf "$TMPDIR_BUILD" 2>/dev/null || true
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════
need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "❌ Запустите от root"; exit 1; }
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Не найдена команда: $1"; exit 1; }
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

# ═══════════════════════════════════════════════════════════
# ARCH DETECT
# Баг-фикс: ошибка идёт в stderr, не в stdout — иначе при $() перехвате
# значение "❌ ..." попадёт в переменную go_arch и xcaddy упадёт с кривым аргументом
# ═══════════════════════════════════════════════════════════
detect_go_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv6l" ;;
    *)
      echo "❌ Неподдерживаемая архитектура: $machine" >&2
      exit 1
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# BUILD CADDY
# ═══════════════════════════════════════════════════════════
build_caddy() {
  local go_arch
  go_arch="$(detect_go_arch)"

  local go_version
  go_version="$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n1)"
  [[ -n "$go_version" ]] || { echo "❌ Не смог получить версию Go"; exit 1; }
  echo "📦 Go $go_version ($go_arch)"

  wget -q "https://go.dev/dl/${go_version}.linux-${go_arch}.tar.gz" -O "$GO_TAR"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$GO_TAR"
  export PATH="/usr/local/go/bin:/root/go/bin:$PATH"

  mkdir -p "$TMPDIR_BUILD"
  export TMPDIR="$TMPDIR_BUILD"

  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

  cd "$TMPDIR_BUILD"
  /root/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

  mv "$TMPDIR_BUILD/caddy" /usr/bin/caddy
  chmod +x /usr/bin/caddy
  cd /root

  echo "✔ Caddy собран: $(caddy version 2>/dev/null || echo 'ok')"
}

# ═══════════════════════════════════════════════════════════
# SYSTEMD UNIT — CADDY

# ═══════════════════════════════════════════════════════════
ensure_systemd_unit_caddy() {
  local unit="/etc/systemd/system/caddy.service"
  # Пересоздаём при каждой установке
  cat > "$unit" <<'UNIT'
[Unit]
Description=Caddy (NaiveProxy frontend)
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
  echo "✔ Systemd unit (caddy) создан/обновлён"
}

# ═══════════════════════════════════════════════════════════
# BACKUP
# ═══════════════════════════════════════════════════════════
backup_now() {
  [[ -f "$CONFIG" ]] || { echo "⚠️  Конфиг не найден, бэкап пропущен"; return 0; }
  mkdir -p "$BACKUP_DIR"
  local f
  f="$BACKUP_DIR/caddy_$(date +%Y%m%d_%H%M%S).bak"
  cp "$CONFIG" "$f"
  echo "✔ Бэкап: $f"

  local count
  count=$(ls -1 "$BACKUP_DIR"/caddy_*.bak 2>/dev/null | wc -l)
  if [[ "$count" -gt "$MAX_BACKUPS" ]]; then
    local to_delete=$((count - MAX_BACKUPS))
    ls -1t "$BACKUP_DIR"/caddy_*.bak 2>/dev/null | tail -n "$to_delete" | xargs -r rm -f
    echo "  ↳ удалено старых бэкапов: $to_delete (оставлено: $MAX_BACKUPS)"
  fi
}

# ═══════════════════════════════════════════════════════════
# APPLY NEW CONFIG (валидация + reload, откат при ошибке)
# ═══════════════════════════════════════════════════════════
apply_new_config() {
  local new_config="$1"

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

# ═══════════════════════════════════════════════════════════
# PARSE DOMAIN FROM CADDYFILE
# ═══════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════
# VALIDATION
# ═══════════════════════════════════════════════════════════
validate_user() {
  [[ -n "${1:-}" ]] || { echo "❌ Пустой логин"; exit 1; }
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "❌ Невалидный логин (допустимы: A-Za-z0-9_-)"
    exit 1
  }
}

validate_password() {
  [[ -n "${1:-}" ]] || { echo "❌ Пустой пароль"; exit 1; }
  if [[ "$1" =~ [[:space:]\"\'\\\`] ]]; then
    echo "❌ Пароль содержит недопустимые символы (пробел, кавычки, бэкслеш)"
    exit 1
  fi
}

gen_random() {
  local len="${1:-16}"
  local result
  result="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len")"
  [[ -n "$result" ]] || { echo "❌ Не удалось сгенерировать случайную строку"; exit 1; }
  echo "$result"
}

ask_credentials() {
  echo ""
  echo "  Логин:"
  echo "  1) Сгенерировать"
  echo "  2) Ввести вручную"
  read -rp "  [1/2]: " choice
  case "$choice" in
    2)
      read -rp "  Логин: " _LOGIN
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
    2)
      read -rsp "  Пароль (скрытый ввод): " _PASSWORD
      echo ""
      ;;
    *)
      _PASSWORD="$(gen_random 24)"
      echo "  → Пароль: $_PASSWORD"
      ;;
  esac
  validate_password "$_PASSWORD"
}

# ═══════════════════════════════════════════════════════════
# CLIENT MANAGEMENT HELPERS
#
# Баг-фикс: после caddy fmt строки могут начинаться с табов/пробелов.
# gsub убирает leading whitespace перед split, иначе $2 окажется пустым.
# ═══════════════════════════════════════════════════════════
list_clients_lines() {
  [[ -f "$CONFIG" ]] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*basic_auth[[:space:]]+/ {
      gsub(/^[[:space:]]+/, "")
      print
    }
  ' "$CONFIG"
}

user_exists() {
  local u="$1"
  list_clients_lines | awk '{print $2}' | grep -Fxq "$u"
}

get_users_array() {
  list_clients_lines | awk '{print $2}'
}

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
    i=$((i + 1))   # Баг-фикс: ((i++)) при set -e падает когда i==0 (exit code 1)
  done
  echo "     0) Отмена" >&2
  echo "" >&2

  local num
  read -rp "  Номер [1-${#users[@]}]: " num

  [[ "$num" == "0" ]] && return 1
  [[ "$num" =~ ^[0-9]+$ ]] || { echo "❌ Не число" >&2; return 1; }
  [[ "$num" -ge 1 && "$num" -le ${#users[@]} ]] || { echo "❌ Вне диапазона" >&2; return 1; }

  echo "${users[$((num - 1))]}"
}

# ═══════════════════════════════════════════════════════════
# LIST CLIENTS
# ═══════════════════════════════════════════════════════════
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
    count=$((count + 1))
    printf "  [%d] %s\n" "$count" "$user"
    echo "      naive+https://${user}:${pass}@${domain}:443"
    echo ""
  done < <(list_clients_lines)

  if [[ $count -eq 0 ]]; then
    echo "  ⚠️  Клиентов нет"
  else
    echo "  Всего: $count"
  fi
}

# ═══════════════════════════════════════════════════════════
# ADD CLIENT
# Баг-фикс: ищем строку forward_proxy { через более точный regex
# чтобы не зависеть от количества пробелов после caddy fmt
# ═══════════════════════════════════════════════════════════
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
      if (!added && $0 ~ /^[[:space:]]*forward_proxy[[:space:]]*\{/) {
        print "    basic_auth " u " " p
        added = 1
      }
    }
    END {
      if (!added) { print "❌ Не нашёл блок forward_proxy { в конфиге" > "/dev/stderr"; exit 2 }
    }
  ' "$CONFIG" > "${CONFIG}.new"

  apply_new_config "${CONFIG}.new"

  local domain
  domain="$(get_domain)"
  echo "✔ naive+https://${user}:${pass}@${domain}:443"
}

# ═══════════════════════════════════════════════════════════
# DELETE CLIENT
# ═══════════════════════════════════════════════════════════
delete_client() {
  ensure_caddy_running
  local user="$1"
  validate_user "$user"
  user_exists "$user" || { echo "❌ Нет такого пользователя: $user"; exit 1; }

  backup_now

  awk -v u="$user" '
    /^[[:space:]]*basic_auth[[:space:]]+/ {
      # gsub убирает leading whitespace для корректного split
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      split(line, parts, /[[:space:]]+/)
      if (parts[2] == u) next
    }
    { print }
  ' "$CONFIG" > "${CONFIG}.new"

  apply_new_config "${CONFIG}.new"
  echo "✔ Удалён: $user"
}

# ═══════════════════════════════════════════════════════════
# CHANGE PASSWORD
# ═══════════════════════════════════════════════════════════
change_password() {
  ensure_caddy_running
  local user="$1" newpass="$2"
  validate_user "$user"
  validate_password "$newpass"
  user_exists "$user" || { echo "❌ Нет такого пользователя: $user"; exit 1; }

  backup_now

  awk -v u="$user" -v p="$newpass" '
    /^[[:space:]]*basic_auth[[:space:]]+/ {
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      split(line, parts, /[[:space:]]+/)
      if (parts[2] == u) {
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

# ═══════════════════════════════════════════════════════════
# RESTORE BACKUP
# ═══════════════════════════════════════════════════════════
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
    i=$((i + 1))
  done
  echo "     0) Отмена"
  echo ""

  local num
  read -rp "  Номер бэкапа: " num
  [[ "$num" == "0" ]] && { echo "Отмена"; return 0; }
  [[ "$num" =~ ^[0-9]+$ ]] || { echo "❌ Не число"; return 1; }
  [[ "$num" -ge 1 && "$num" -le ${#files[@]} ]] || { echo "❌ Вне диапазона"; return 1; }

  local chosen="${files[$((num - 1))]}"

  read -rp "  Восстановить '$chosen'? Текущий конфиг сохранится в новый бэкап. (y/n): " yn
  [[ "$yn" == "y" ]] || { echo "Отмена"; return 0; }

  backup_now

  if ! caddy validate --config "$BACKUP_DIR/$chosen" 2>/dev/null; then
    echo "❌ Бэкап невалиден!"
    return 1
  fi

  cp "$BACKUP_DIR/$chosen" "$CONFIG"
  caddy reload --config "$CONFIG" --force
  echo "✔ Восстановлено из: $chosen"
}

# ═══════════════════════════════════════════════════════════
# EXPORT JSON — sing-box naive outbound формат (server_name для TLS SNI)
# ═══════════════════════════════════════════════════════════
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
        server_port: 443,
        username: $user,
        password: $pass,
        tls: {
          enabled: true,
          server_name: $server
        }
      }')")
  done < <(list_clients_lines)

  if [[ ${#results[@]} -eq 0 ]]; then
    echo "⚠️  Клиентов нет"
    return
  fi

  printf '%s\n' "${results[@]}" | jq -s '.'
}

# ═══════════════════════════════════════════════════════════
# INSTALL / REINSTALL
# ═══════════════════════════════════════════════════════════
install_or_reinstall() {
  read -rp "  Домен: " DOMAIN
  [[ -n "$DOMAIN" ]] || { echo "❌ Пустой домен"; exit 1; }

  # DNS check
  local server_ip domain_ip
  server_ip="$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || true)"
  domain_ip="$(dig +short A "$DOMAIN" 2>/dev/null | head -n1 || true)"
  echo "  IP сервера: ${server_ip:-не определён}"
  echo "  IP домена:  ${domain_ip:-не определён}"
  if [[ -n "$server_ip" && -n "$domain_ip" && "$server_ip" != "$domain_ip" ]]; then
    read -rp "  ⚠️  IP сервера и домена не совпадают! Продолжить? (y/n): " yn
    [[ "$yn" == "y" ]] || exit 1
  fi

  # Проверка портов 80 и 443
  # Баг-фикс: PORT был глобальной переменной (нет local внутри цикла)
  local port_check
  for port_check in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":${port_check} "; then
      echo "  ❌ Порт $port_check занят:"
      ss -tlnp 2>/dev/null | grep ":${port_check} " || true
      exit 1
    fi
  done

  # Email для Let's Encrypt
  echo ""
  echo "  Email для TLS-сертификата:"
  echo "  1) Тестовый (admin@example.com)"
  echo "  2) Ввести свой (рекомендуется)"
  read -rp "  [1/2]: " choice
  local EMAIL
  case "$choice" in
    1)
      EMAIL="admin@example.com"
      echo "  ⚠️  Тестовый email — только для проверки!"
      read -rp "  Продолжить? (y/n): " yn
      [[ "$yn" == "y" ]] || exit 1
      ;;
    *)
      read -rp "  Email: " EMAIL
      [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || {
        echo "❌ Невалидный email"; exit 1
      }
      if [[ "$EMAIL" =~ @(example\.(com|org|net)|localhost)$ ]]; then
        echo "  ⚠️  Зарезервированный домен."
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

  # BBR
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "📶 Включаю BBR..."
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null \
      || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null \
      || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null
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

  # Камуфляжная страница
  if [[ ! -f /var/www/html/index.html ]]; then
    cat > /var/www/html/index.html <<'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style></head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
HTMLEOF
    echo "✔ Камуфляжная страница создана"
  fi

  if [[ -f "$CONFIG" ]]; then
    read -rp "  ⚠️  Конфиг уже существует. Перезаписать? (y/n): " yn
    [[ "$yn" == "y" ]] || exit 1
    backup_now
  fi

  # Генерируем Caddyfile
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

  caddy fmt --overwrite "$CONFIG" 2>/dev/null || true

  if ! caddy validate --config "$CONFIG"; then
    echo "❌ Сгенерированный конфиг невалиден!"
    exit 1
  fi

  ensure_systemd_unit_caddy
  systemctl enable caddy
  systemctl restart caddy

  echo ""
  echo "  ═══════════════════════════════════════════"
  echo "  ✔ NaïveProxy установлен"
  echo ""
  echo "  naive+https://${LOGIN}:${PASSWORD}@${DOMAIN}:443"
  echo "  ═══════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════
# UPDATE CADDY
# ═══════════════════════════════════════════════════════════
update_caddy() {
  ensure_caddy_running
  ensure_pkgs
  backup_now
  build_caddy
  systemctl restart caddy
  echo "✔ Caddy обновлён: $(caddy version 2>/dev/null || echo 'ok')"
}


# ═══════════════════════════════════════════════════════════
# UNINSTALL — полная очистка сервера
# Бэкапы Caddy СОХРАНЯЮТСЯ в $BACKUP_DIR
# ═══════════════════════════════════════════════════════════
uninstall() {
  echo ""
  echo "  ⚠️  Будут удалены: Caddy, Go, systemd unit, конфиги."
  echo "  Бэкапы в $BACKUP_DIR СОХРАНЯТСЯ."
  echo ""
  read -rp "  Вы уверены? (y/n): " yn
  [[ "$yn" == "y" ]] || { echo "Отмена"; return 0; }


  read -rp "  Введите 'YES' заглавными для подтверждения: " yes2
  [[ "$yes2" == "YES" ]] || { echo "Отмена"; return 0; }

  systemctl stop caddy 2>/dev/null || true
  systemctl disable caddy 2>/dev/null || true
  rm -f /etc/systemd/system/caddy.service
  rm -f /usr/bin/caddy

  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  apt-get remove -y sing-box 2>/dev/null || true

  systemctl daemon-reload

  echo "  ✔ Удалено."
  echo "  Конфиг Caddy сохранён: $CONFIG"
  echo "  Бэкапы сохранены: $BACKUP_DIR"
}

# ═══════════════════════════════════════════════════════════
# SHOW QR
# ═══════════════════════════════════════════════════════════
show_qr() {
  local domain
  domain="$(get_domain)"
  [[ -n "$domain" ]] || { echo "❌ Домен не найден"; return 1; }

  if ! command -v qrencode >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >/dev/null 2>&1 || {
      echo "❌ Не удалось установить qrencode"
      return 1
    }
  fi

  local user
  user="$(pick_client)" || { echo "Отмена"; return 0; }

  local pass
  pass=$(list_clients_lines | awk -v u="$user" '{gsub(/^[[:space:]]+/,""); if ($2 == u) {print $3; exit}}')
  [[ -n "$pass" ]] || { echo "❌ Не нашёл пароль для '$user'"; return 1; }

  local url="naive+https://${user}:${pass}@${domain}:443"

  echo ""
  echo "  Ссылка для '$user':"
  echo "  $url"
  echo ""
  echo "  QR-код (Karing / NekoBox):"
  echo ""
  qrencode -t ANSIUTF8 -m 2 "$url"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SERVICE CONTROL
# ═══════════════════════════════════════════════════════════
service_control() {
  echo ""
  echo "  Управление сервисом Caddy:"
  echo "    2) Остановить всё"
  echo "    3) Перезапустить всё"
  echo "    4) Статус Caddy"
  echo "    5) Логи Caddy (live)"
  echo "    0) Назад"
  echo ""
  read -rp "  Выбор: " sc

  case "$sc" in
    1)
      systemctl start caddy && echo "✔ Caddy запущен" || echo "❌ Caddy не запустился"
      ;;
    2)
      read -rp "  ⚠️  Остановить? Все клиенты потеряют связь. (y/n): " yn
      [[ "$yn" == "y" ]] || { echo "Отмена"; return 0; }
      systemctl stop caddy 2>/dev/null && echo "✔ Caddy остановлен" || true
      ;;
    3)
      systemctl restart caddy && echo "✔ Caddy перезапущен" || echo "❌ Caddy не перезапустился"
      ;;
    4)
      echo ""
      systemctl status caddy --no-pager 2>&1 | head -25
      ;;
    5)
      echo "  Ctrl+C для выхода"
      journalctl -u caddy -f --no-pager
      ;;
    0) return 0 ;;
    *) echo "❌ Неверный выбор" ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# LIST BACKUPS
# ═══════════════════════════════════════════════════════════
list_backups() {
  [[ -d "$BACKUP_DIR" ]] || { echo "⚠️  Нет директории бэкапов"; return 1; }

  local -a files=()
  while IFS= read -r f; do
    [[ -f "$BACKUP_DIR/$f" ]] && files+=("$f")
  done < <(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r)

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "⚠️  Бэкапов нет"
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
    i=$((i + 1))
  done
  echo "  Всего: ${#files[@]}"
}

# ═══════════════════════════════════════════════════════════
# STATUS (шапка меню)
# ═══════════════════════════════════════════════════════════
show_status() {
  echo ""
  echo "  ┌─────────────────────────────────────────────┐"

  if systemctl is-active --quiet caddy 2>/dev/null; then
    echo "  │ Caddy:      🟢 работает"
  else
    echo "  │ Caddy:      🔴 не запущен"
  fi

  if [[ -f "$CONFIG" ]]; then
    local domain
    domain="$(get_domain 2>/dev/null || echo '')"
    echo "  │ Домен:      ${domain:-не найден}"

    local cnt
    cnt=$(list_clients_lines 2>/dev/null | wc -l | tr -d ' ')
    echo "  │ Клиентов:   ${cnt:-0}"
  else
    echo "  │ Конфиг:     не установлен"
  fi

  if command -v caddy >/dev/null 2>&1; then
    local ver
    ver="$(caddy version 2>/dev/null | awk '{print $1}' | head -1)"
    echo "  │ Caddy ver:  ${ver:-unknown}"
  fi

  local p443
  p443=$(ss -Hlnt 2>/dev/null | awk '$4 ~ /[:.]443$/ {print "TCP ✔"; exit}')
  echo "  │ :443:       ${p443:-нет}"

  echo "  └─────────────────────────────────────────────┘"
}

# ═══════════════════════════════════════════════════════════
# DIAGNOSE
# ═══════════════════════════════════════════════════════════
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
    ok=$((ok + 1))
  else
    echo "  $err_mark Caddy не установлен — выполни установку (пункт 1)"
    err=$((err + 1))
    echo ""
    return 1
  fi

  # 3. Systemd unit caddy
  if [[ -f /etc/systemd/system/caddy.service ]]; then
    echo "  $ok_mark Systemd unit caddy существует"
    ok=$((ok + 1))
  else
    echo "  $err_mark Нет systemd unit caddy — переустанови"
    err=$((err + 1))
  fi

  # 4. Caddy running
  if systemctl is-active --quiet caddy 2>/dev/null; then
    echo "  $ok_mark Caddy запущен"
    ok=$((ok + 1))
  else
    echo "  $err_mark Caddy не запущен: systemctl start caddy"
    err=$((err + 1))
  fi

  # 7. Caddyfile валиден
  if [[ -f "$CONFIG" ]]; then
    if caddy validate --config "$CONFIG" >/dev/null 2>&1; then
      echo "  $ok_mark Caddyfile валиден"
      ok=$((ok + 1))
    else
      echo "  $err_mark Caddyfile невалиден: caddy validate --config $CONFIG"
      err=$((err + 1))
    fi
  else
    echo "  $err_mark Нет конфига: $CONFIG"
    err=$((err + 1))
  fi

  # 9. Домен
  local domain
  domain="$(get_domain 2>/dev/null || echo '')"
  if [[ -n "$domain" ]]; then
    echo "  $ok_mark Домен: $domain"
    ok=$((ok + 1))
  else
    echo "  $err_mark Домен не найден в конфиге"
    err=$((err + 1))
    echo "  Дальнейшие проверки пропущены."
    return 1
  fi

  # 10. DNS
  local server_ip domain_ip
  server_ip="$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo '')"
  domain_ip="$(dig +short A "$domain" 2>/dev/null | head -n1 || echo '')"
  if [[ -z "$server_ip" ]]; then
    echo "  $warn_mark Не смог определить IP сервера (нет интернета?)"
    warn=$((warn + 1))
  elif [[ -z "$domain_ip" ]]; then
    echo "  $err_mark DNS $domain не резолвится"
    err=$((err + 1))
  elif [[ "$server_ip" == "$domain_ip" ]]; then
    echo "  $ok_mark DNS: $domain → $domain_ip ✔"
    ok=$((ok + 1))
  else
    echo "  $err_mark DNS несовпадение: сервер=$server_ip, домен=$domain_ip"
    echo "          → TLS не выпустится пока не исправишь A-запись"
    err=$((err + 1))
  fi

  # 11. TCP/443
  if ss -Hlnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]443$'; then
    local pid_name
    pid_name=$(ss -Hlntp 2>/dev/null | awk '$4 ~ /[:.]443$/ {print; exit}' \
               | grep -oP 'users:\(\("\K[^"]+' | head -1)
    echo "  $ok_mark TCP/443 слушает: ${pid_name:-?}"
    ok=$((ok + 1))
  else
    echo "  $err_mark TCP/443 не слушает никто"
    err=$((err + 1))
  fi

  # 12. TLS сертификат
  if [[ -n "$domain" ]]; then
    local tls_out expires
    tls_out=$(timeout 5 openssl s_client \
      -connect "${domain}:443" -servername "$domain" \
      </dev/null 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || true)
    if [[ -n "$tls_out" ]]; then
      expires=$(echo "$tls_out" | grep "notAfter" | cut -d= -f2)
      echo "  $ok_mark TLS сертификат активен до: $expires"
      ok=$((ok + 1))
    else
      echo "  $err_mark Не удалось получить TLS сертификат от $domain:443"
      err=$((err + 1))
    fi
  fi

  # 13. Probe resistance (без auth должна быть HTML страница)
  if [[ -n "$domain" ]]; then
    local http_code
    http_code=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" "https://${domain}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      echo "  $ok_mark Камуфляжная страница отвечает (HTTP 200)"
      ok=$((ok + 1))
    elif [[ "$http_code" == "000" ]]; then
      echo "  $warn_mark Не смог подключиться к $domain (фаерволл?)"
      warn=$((warn + 1))
    else
      echo "  $warn_mark Домен отдаёт HTTP $http_code (ожидалось 200)"
      warn=$((warn + 1))
    fi
  fi

  # 14. BBR
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "  $ok_mark BBR включён"
    ok=$((ok + 1))
  else
    echo "  $warn_mark BBR не включён (скорость может быть ниже)"
    warn=$((warn + 1))
  fi

  # 15. Клиенты
  local cnt
  cnt=$(list_clients_lines 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$cnt" -gt 0 ]]; then
    echo "  $ok_mark Клиентов настроено: $cnt"
    ok=$((ok + 1))
  else
    echo "  $warn_mark Нет клиентов (добавь через пункт 4)"
    warn=$((warn + 1))
  fi

  echo ""
  echo "  ═══════════ ИТОГО ═══════════"
  echo "  🟢 OK: $ok   🟡 Warn: $warn   🔴 Err: $err"
  echo ""

  if [[ $err -eq 0 && $warn -eq 0 ]]; then
    echo "  ✔ Всё в порядке!"
  elif [[ $err -eq 0 ]]; then
    echo "  ⚠️  Есть предупреждения, критичного нет."
  else
    echo "  ❌ Есть ошибки, требуется внимание."
  fi
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
need_root

run_action() {
  ( "$@" ) || echo "⚠️  Действие завершилось с ошибкой"
}

while true; do
  clear 2>/dev/null || printf '\n\n\n'
  echo ""
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║          NaïveProxy Manager               ║"
  echo "  ╚═══════════════════════════════════════════╝"

  show_status

  echo ""
  echo "  ── Установка ────────────────────────────────"
  echo "  1)  Установить / Переустановить"
  echo "  2)  Обновить Caddy"
  echo "  ── Клиенты ──────────────────────────────────"
  echo "  4)  Добавить клиента"
  echo "  5)  Список клиентов"
  echo "  6)  Удалить клиента"
  echo "  7)  Сменить пароль"
  echo "  8)  QR-код"
  echo "  9)  Экспорт JSON (клиентский конфиг)"
  echo "  ── Бэкапы ───────────────────────────────────"
  echo "  10) Создать бэкап"
  echo "  11) Восстановить бэкап"
  echo "  12) Список бэкапов"
  echo "  ── Прочее ───────────────────────────────────"
  echo "  13) Показать Caddyfile"
  echo "  15) Управление сервисами"
  echo "  16) Диагностика"
  echo "  17) Удалить установку"
  echo "  0)  Выход"
  echo ""

  read -rp "  Выбор: " MODE

  case "$MODE" in
    0)
      echo "👋 Выход"
      exit 0
      ;;
    1)  run_action install_or_reinstall ;;
    2)  run_action update_caddy ;;
    4)
      (
        ask_credentials
        add_client "$_LOGIN" "$_PASSWORD"
      ) || echo "⚠️  Не удалось добавить клиента"
      ;;
    5)  run_action list_clients ;;
    6)
      (
        U="$(pick_client)" || { echo "Отмена"; exit 0; }
        echo ""
        read -rp "  Удалить '$U'? (y/n): " yn
        [[ "$yn" == "y" ]] || { echo "Отмена"; exit 0; }
        delete_client "$U"
      ) || echo "⚠️  Не удалось удалить"
      ;;
    7)
      (
        U="$(pick_client)" || { echo "Отмена"; exit 0; }
        echo ""
        echo "  Новый пароль для '$U':"
        echo "    1) Сгенерировать"
        echo "    2) Ввести вручную"
        read -rp "  [1/2]: " choice
        NEWPASS=""
        case "$choice" in
          2)
            read -rsp "  Пароль (скрытый ввод): " NEWPASS
            echo ""
            ;;
          *)
            NEWPASS="$(gen_random 24)"
            echo "  → Пароль: $NEWPASS"
            ;;
        esac
        validate_password "$NEWPASS"
        change_password "$U" "$NEWPASS"
      ) || echo "⚠️  Не удалось сменить пароль"
      ;;
    8)  run_action show_qr ;;
    9)  run_action export_json ;;
    10) run_action backup_now ;;
    11) run_action restore_backup ;;
    12) run_action list_backups ;;
    13)
      echo ""
      if [[ -f "$CONFIG" ]]; then
        echo "  ─── $CONFIG ───"
        echo ""
        cat "$CONFIG"
        echo ""
        echo "  ────────────────"
      else
        echo "  ⚠️  Конфиг не найден: $CONFIG"
      fi
      ;;
    15) run_action service_control ;;
    16) run_action diagnose ;;
    17) run_action uninstall ;;
    *)
      echo "❌ Неверный выбор"
      ;;
  esac

  echo ""
  read -rp "  ↵ Enter для возврата в меню..." _
done
