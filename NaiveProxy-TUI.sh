#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  NaïveProxy Manager — TUI Edition
#  Использует whiptail для интерактивного интерфейса
# ═══════════════════════════════════════════════════════════

set -uo pipefail

CONFIG="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backups"
TMPDIR_BUILD="/root/naiveproxy-build-tmp"
GO_TAR="/tmp/go.tar.gz"
BACKTITLE="NaïveProxy Manager"

# ─── Cleanup ───────────────────────────────────────────────
cleanup() {
  rm -f "$GO_TAR" 2>/dev/null || true
  [[ -d "$TMPDIR_BUILD" ]] && rm -rf "$TMPDIR_BUILD" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Ensure whiptail ──────────────────────────────────────
ensure_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    echo "📦 Устанавливаю whiptail..."
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >/dev/null 2>&1 || {
      echo "❌ Не удалось установить whiptail"
      exit 1
    }
  fi
}

# ─── Root check ────────────────────────────────────────────
need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "❌ Запустите от root"
    exit 1
  }
}

# ─── Helpers ───────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

ensure_pkgs() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget git openssl ufw dnsutils jq ca-certificates whiptail
}

# UI-обёртки
msg_info() {
  whiptail --backtitle "$BACKTITLE" --title "ℹ Инфо" --msgbox "$1" 12 70
}

msg_error() {
  whiptail --backtitle "$BACKTITLE" --title "✖ Ошибка" --msgbox "$1" 12 70
}

msg_success() {
  whiptail --backtitle "$BACKTITLE" --title "✔ Готово" --msgbox "$1" 14 76
}

ask_yesno() {
  # $1 = title, $2 = question
  whiptail --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 10 70
  return $?
}

ask_input() {
  # $1 = title, $2 = prompt, $3 = default (optional)
  whiptail --backtitle "$BACKTITLE" --title "$1" \
    --inputbox "$2" 10 70 "${3:-}" 3>&1 1>&2 2>&3
}

ask_password() {
  # $1 = title, $2 = prompt
  whiptail --backtitle "$BACKTITLE" --title "$1" \
    --passwordbox "$2" 10 70 3>&1 1>&2 2>&3
}

# Показать длинный вывод (из файла или stdin)
show_textbox() {
  # $1 = title, $2 = path (or - for stdin from $3)
  local title="$1"
  local src="$2"
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --textbox "$src" 25 90 --scrolltext
}

# Запуск команды с выводом в окно gauge для длинных операций
run_with_log() {
  # $1 = title, остальное — команда
  local title="$1"; shift
  local log="/tmp/naive_run_$$.log"
  echo "" > "$log"
  {
    echo "=== $(date) ==="
    "$@" 2>&1
    echo ""
    echo "=== exit code: $? ==="
  } | tee -a "$log" > /dev/null &
  local pid=$!

  # Пока команда работает — показываем прогресс
  (
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      echo "XXX"
      echo "50"
      echo "Выполняется: $title..."
      echo "XXX"
    done
  ) | whiptail --backtitle "$BACKTITLE" --title "$title" \
      --gauge "Подготовка..." 10 70 0

  wait "$pid"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    whiptail --backtitle "$BACKTITLE" --title "$title" \
      --textbox "$log" 25 90 --scrolltext
  else
    whiptail --backtitle "$BACKTITLE" --title "✖ Ошибка ($title)" \
      --textbox "$log" 25 90 --scrolltext
  fi
  rm -f "$log"
  return $rc
}

# ─── Detect arch ───────────────────────────────────────────
detect_go_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv6l" ;;
    *)       return 1 ;;
  esac
}

# ─── Build caddy ───────────────────────────────────────────
build_caddy() {
  local go_arch
  go_arch="$(detect_go_arch)" || {
    echo "❌ Неподдерживаемая архитектура: $(uname -m)"
    return 1
  }

  local go_version
  go_version="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"
  echo "📦 Go $go_version ($go_arch)"

  wget -q "https://go.dev/dl/${go_version}.linux-${go_arch}.tar.gz" -O "$GO_TAR" || {
    echo "❌ Не удалось скачать Go"
    return 1
  }
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$GO_TAR"
  export PATH="/usr/local/go/bin:/root/go/bin:$PATH"

  mkdir -p "$TMPDIR_BUILD"
  export TMPDIR="$TMPDIR_BUILD"

  echo "🔨 Устанавливаю xcaddy..."
  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest || return 1

  cd "$TMPDIR_BUILD"
  echo "🔨 Собираю Caddy с naive-плагином..."
  /root/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive || return 1

  mv "$TMPDIR_BUILD/caddy" /usr/bin/caddy
  chmod +x /usr/bin/caddy
  cd /root

  echo "✔ Caddy: $(caddy version 2>/dev/null || echo 'ok')"
}

# ─── Systemd unit ──────────────────────────────────────────
ensure_systemd_unit() {
  local unit="/etc/systemd/system/caddy.service"
  [[ -f "$unit" ]] && return 0

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
}

# ─── Backup ────────────────────────────────────────────────
backup_now() {
  [[ -f "$CONFIG" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  local f="$BACKUP_DIR/caddy_$(date +%Y%m%d_%H%M%S).bak"
  cp "$CONFIG" "$f"
  echo "$f"
}

# ─── Validate config ──────────────────────────────────────
apply_new_config() {
  local new_config="$1"
  caddy fmt --overwrite "$new_config" 2>/dev/null || true

  if ! caddy validate --config "$new_config" 2>/dev/null; then
    rm -f "$new_config"
    return 1
  fi

  mv "$new_config" "$CONFIG"
  caddy reload --config "$CONFIG" --force
  return 0
}

# ─── Parsers ───────────────────────────────────────────────
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
  ' "$CONFIG" 2>/dev/null
}

list_clients_lines() {
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*basic_auth[[:space:]]+/ {print}
  ' "$CONFIG" 2>/dev/null
}

user_exists() {
  list_clients_lines | awk '{print $2}' | grep -Fxq "$1"
}

gen_random() {
  local len="${1:-16}"
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len"
}

validate_user_input() {
  [[ -n "$1" && "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

validate_password_input() {
  [[ -n "$1" && ! "$1" =~ [[:space:]\"\'\\\`] ]]
}

validate_email_input() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# ─── Status ────────────────────────────────────────────────
build_status_text() {
  local status=""

  # Caddy
  if systemctl is-active --quiet caddy 2>/dev/null; then
    status+="Caddy:       🟢 работает\n"
  else
    status+="Caddy:       🔴 не запущен\n"
  fi

  # Config
  if [[ -f "$CONFIG" ]]; then
    local domain cnt
    domain="$(get_domain)"
    cnt=$(list_clients_lines | wc -l | tr -d ' ')
    status+="Домен:       ${domain:-не найден}\n"
    status+="Клиентов:    ${cnt:-0}\n"
  else
    status+="Конфиг:      не установлен\n"
  fi

  # Caddy version
  if command -v caddy >/dev/null 2>&1; then
    local ver
    ver="$(caddy version 2>/dev/null | awk '{print $1}' | head -1)"
    status+="Caddy:       ${ver:-unknown}\n"
  fi

  # Ports
  local p443_tcp p443_udp
  p443_tcp=$(ss -tln 2>/dev/null | awk '$4 ~ /:443$/ {print "TCP"; exit}')
  p443_udp=$(ss -uln 2>/dev/null | awk '$4 ~ /:443$/ {print "UDP"; exit}')
  if [[ -n "$p443_tcp$p443_udp" ]]; then
    status+=":443:        ${p443_tcp:-}${p443_udp:+ ${p443_udp}}\n"
  fi

  # Server IP
  local ip
  ip="$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || echo '?')"
  status+="IP:          $ip"

  echo -e "$status"
}

# ═══════════════════════════════════════════════════════════
# ДЕЙСТВИЯ
# ═══════════════════════════════════════════════════════════

# ─── Install ───────────────────────────────────────────────
action_install() {
  # Домен
  local DOMAIN
  DOMAIN=$(ask_input "Установка (1/4)" "Введите домен для NaïveProxy:\n\nПример: haha.mydomain.com\n\nДомен должен указывать на IP этого сервера (A-запись)." "") || return
  [[ -n "$DOMAIN" ]] || { msg_error "Домен не может быть пустым"; return 1; }

  # DNS check
  local server_ip domain_ip
  server_ip="$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo '')"
  domain_ip="$(dig +short A "$DOMAIN" 2>/dev/null | head -n1 || echo '')"

  if [[ -n "$server_ip" && -n "$domain_ip" && "$server_ip" != "$domain_ip" ]]; then
    ask_yesno "⚠ Несовпадение DNS" "IP сервера:  $server_ip\nIP домена:   $domain_ip\n\nОни не совпадают! Это значит что TLS-сертификат не выпустится.\n\nПродолжить всё равно?" || return
  fi

  # Ports check
  for PORT in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      local occupants
      occupants=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | head -3)
      msg_error "Порт $PORT занят:\n\n$occupants\n\nОсвободите порт (остановите nginx/3x-ui/etc) и попробуйте снова."
      return 1
    fi
  done

  # Email
  local email_choice EMAIL
  email_choice=$(whiptail --backtitle "$BACKTITLE" --title "Установка (2/4) — Email" \
    --menu "Email используется Let's Encrypt для уведомлений об истечении сертификата.\n\nВыберите:" \
    16 76 3 \
    "1" "Тестовый (admin@example.com) — только для теста" \
    "2" "Ввести свой рабочий email (рекомендуется)" \
    3>&1 1>&2 2>&3) || return

  case "$email_choice" in
    1)
      EMAIL="admin@example.com"
      ask_yesno "⚠ Тестовый email" "admin@example.com — синтаксически валидный, но несуществующий адрес.\n\nLet's Encrypt не сможет прислать уведомления.\n\nИспользовать только для теста?" || return
      ;;
    2)
      EMAIL=$(ask_input "Email" "Введите свой рабочий email:" "") || return
      validate_email_input "$EMAIL" || { msg_error "Невалидный email: $EMAIL"; return 1; }
      if [[ "$EMAIL" =~ @(example\.(com|org|net)|localhost)$ ]]; then
        ask_yesno "⚠ Зарезервированный домен" "Этот домен зарезервирован для тестов.\n\nВсё равно использовать?" || return
      fi
      ;;
  esac

  # Credentials
  ask_credentials_tui "Установка (3/4) — Логин и пароль" || return
  local LOGIN="$_LOGIN" PASSWORD="$_PASSWORD"

  # Confirmation
  ask_yesno "Готов к установке (4/4)" "Будет выполнено:\n\n• Обновление системы\n• Установка Go и сборка Caddy (~5 мин)\n• Настройка BBR + firewall\n• Генерация TLS сертификата для $DOMAIN\n\nДомен:   $DOMAIN\nEmail:   $EMAIL\nЛогин:   $LOGIN\nПароль:  $PASSWORD\n\nПродолжить?" || return

  # Overwrite check
  if [[ -f "$CONFIG" ]]; then
    ask_yesno "Конфиг уже существует" "По пути $CONFIG уже есть конфиг.\n\nПерезаписать? (старый будет сохранён в бэкапе)" || return
    backup_now >/dev/null
  fi

  # === Installation ===
  {
    echo "=== Шаг 1/7: Установка пакетов ==="
    ensure_pkgs 2>&1

    echo ""
    echo "=== Шаг 2/7: BBR ==="
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
      grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null \
        || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
      grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null \
        || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
      sysctl -p
      echo "✔ BBR включён"
    else
      echo "✔ BBR уже активен"
    fi

    echo ""
    echo "=== Шаг 3/7: Firewall ==="
    ufw allow 22/tcp 2>/dev/null
    ufw allow 80/tcp 2>/dev/null
    ufw allow 443/tcp 2>/dev/null
    ufw allow 443/udp 2>/dev/null
    ufw --force enable 2>/dev/null
    echo "✔ UFW настроен"

    echo ""
    echo "=== Шаг 4/7: Сборка Caddy ==="
    build_caddy

    echo ""
    echo "=== Шаг 5/7: Камуфляжная страница ==="
    mkdir -p /var/www/html /etc/caddy
    if [[ ! -f /var/www/html/index.html ]]; then
      cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style></head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
HTMLEOF
      echo "✔ Страница создана"
    fi

    echo ""
    echo "=== Шаг 6/7: Caddyfile ==="
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
    caddy fmt --overwrite "$CONFIG" 2>/dev/null
    if ! caddy validate --config "$CONFIG" 2>&1; then
      echo "❌ Невалидный конфиг!"
      exit 1
    fi
    echo "✔ Caddyfile создан и провалидирован"

    echo ""
    echo "=== Шаг 7/7: Systemd ==="
    ensure_systemd_unit
    systemctl daemon-reload
    systemctl enable caddy 2>&1
    systemctl restart caddy
    sleep 2
    if systemctl is-active --quiet caddy; then
      echo "✔ Caddy запущен"
    else
      echo "⚠ Caddy не запустился — проверь логи"
    fi

    echo ""
    echo "════════════════════════════════════════"
    echo "  ✔ УСТАНОВКА ЗАВЕРШЕНА"
    echo "════════════════════════════════════════"
    echo ""
    echo "Ссылка для клиентов:"
    echo "naive+https://${LOGIN}:${PASSWORD}@${DOMAIN}:443"
  } > /tmp/naive_install_$$.log 2>&1 &

  local pid=$!
  # progress dialog
  (
    local step=0
    while kill -0 "$pid" 2>/dev/null; do
      step=$((step + 5))
      [[ $step -gt 95 ]] && step=95
      local msg
      msg="$(tail -1 /tmp/naive_install_$$.log 2>/dev/null | head -c 60)"
      echo "XXX"
      echo "$step"
      echo "${msg:-Работаю...}"
      echo "XXX"
      sleep 2
    done
    echo "XXX"
    echo "100"
    echo "Готово"
    echo "XXX"
  ) | whiptail --backtitle "$BACKTITLE" --title "Установка NaïveProxy" \
    --gauge "Запускаю..." 10 70 0

  wait "$pid"
  local rc=$?

  whiptail --backtitle "$BACKTITLE" --title "Лог установки" \
    --textbox /tmp/naive_install_$$.log 30 100 --scrolltext
  rm -f /tmp/naive_install_$$.log

  if [[ $rc -eq 0 ]]; then
    msg_success "Установка завершена!\n\nДомен:    $DOMAIN\nЛогин:    $LOGIN\nПароль:   $PASSWORD\n\nСсылка:\nnaive+https://${LOGIN}:${PASSWORD}@${DOMAIN}:443"
  else
    msg_error "Установка завершилась с ошибкой.\nСмотри лог выше."
  fi
}

# ─── Ask credentials TUI ──────────────────────────────────
ask_credentials_tui() {
  local title="$1"

  # Login mode
  local login_mode
  login_mode=$(whiptail --backtitle "$BACKTITLE" --title "$title" \
    --menu "Логин:" 12 60 2 \
    "1" "Сгенерировать (12 символов)" \
    "2" "Ввести вручную" \
    3>&1 1>&2 2>&3) || return 1

  case "$login_mode" in
    1) _LOGIN="$(gen_random 12)" ;;
    2)
      _LOGIN=$(ask_input "Логин" "Введите логин:\n\n(допустимы: A-Z a-z 0-9 _ -)" "") || return 1
      ;;
  esac
  validate_user_input "$_LOGIN" || { msg_error "Невалидный логин: $_LOGIN"; return 1; }

  # Password mode
  local pass_mode
  pass_mode=$(whiptail --backtitle "$BACKTITLE" --title "$title" \
    --menu "Пароль:" 12 60 2 \
    "1" "Сгенерировать (24 символа)" \
    "2" "Ввести вручную" \
    3>&1 1>&2 2>&3) || return 1

  case "$pass_mode" in
    1) _PASSWORD="$(gen_random 24)" ;;
    2)
      _PASSWORD=$(ask_password "Пароль" "Введите пароль:\n\n(без пробелов, кавычек и бэкслешей)") || return 1
      ;;
  esac
  validate_password_input "$_PASSWORD" || { msg_error "Невалидный пароль"; return 1; }

  return 0
}

# ─── Add client ────────────────────────────────────────────
action_add_client() {
  systemctl is-active --quiet caddy || { msg_error "Caddy не запущен"; return 1; }

  ask_credentials_tui "Добавление клиента" || return
  local user="$_LOGIN" pass="$_PASSWORD"

  if user_exists "$user"; then
    msg_error "Пользователь '$user' уже существует"
    return 1
  fi

  backup_now >/dev/null

  awk -v u="$user" -v p="$pass" '
    BEGIN { added = 0 }
    {
      print $0
      if ($0 ~ /forward_proxy[[:space:]]*\{/) {
        print "    basic_auth " u " " p
        added = 1
      }
    }
    END { if (!added) exit 2 }
  ' "$CONFIG" > "${CONFIG}.new"

  if apply_new_config "${CONFIG}.new"; then
    local domain
    domain="$(get_domain)"
    msg_success "Клиент добавлен!\n\nЛогин:   $user\nПароль:  $pass\n\nСсылка:\nnaive+https://${user}:${pass}@${domain}:443"
  else
    msg_error "Не удалось применить конфиг"
  fi
}

# ─── List clients ─────────────────────────────────────────
action_list_clients() {
  if [[ ! -f "$CONFIG" ]]; then
    msg_error "Конфиг не найден. Сначала выполни установку."
    return 1
  fi

  local domain
  domain="$(get_domain)"
  [[ -n "$domain" ]] || { msg_error "Домен не найден в конфиге"; return 1; }

  local out="/tmp/naive_clients_$$.txt"
  {
    echo "Домен: $domain"
    echo "════════════════════════════════════════"
    echo ""
    local count=0
    while IFS=' ' read -r _ user pass _rest; do
      [[ -n "$user" && -n "$pass" ]] || continue
      ((count++))
      echo "[$count] $user"
      echo "    naive+https://${user}:${pass}@${domain}:443"
      echo ""
    done < <(list_clients_lines)

    if [[ $count -eq 0 ]]; then
      echo "⚠ Клиентов нет"
    else
      echo "Всего: $count"
    fi
  } > "$out"

  whiptail --backtitle "$BACKTITLE" --title "Список клиентов" \
    --textbox "$out" 25 90 --scrolltext
  rm -f "$out"
}

# ─── Pick client from list ────────────────────────────────
pick_client() {
  local -a users=()
  while IFS=' ' read -r _ user _ _; do
    [[ -n "$user" ]] && users+=("$user" "")
  done < <(list_clients_lines)

  if [[ ${#users[@]} -eq 0 ]]; then
    msg_error "Клиентов нет"
    return 1
  fi

  whiptail --backtitle "$BACKTITLE" --title "Выбор клиента" \
    --menu "Выберите пользователя:" 20 60 12 "${users[@]}" \
    3>&1 1>&2 2>&3
}

# ─── Delete client ────────────────────────────────────────
action_delete_client() {
  systemctl is-active --quiet caddy || { msg_error "Caddy не запущен"; return 1; }

  local user
  user=$(pick_client) || return

  ask_yesno "Подтверждение" "Удалить клиента '$user'?\n\nСвязь с устройств этого клиента будет разорвана." || return

  backup_now >/dev/null

  awk -v u="$user" '
    /^[[:space:]]*basic_auth[[:space:]]+/ {
      if ($2 == u) next
    }
    { print }
  ' "$CONFIG" > "${CONFIG}.new"

  if apply_new_config "${CONFIG}.new"; then
    msg_success "Клиент '$user' удалён"
  else
    msg_error "Не удалось применить конфиг"
  fi
}

# ─── Change password ──────────────────────────────────────
action_change_password() {
  systemctl is-active --quiet caddy || { msg_error "Caddy не запущен"; return 1; }

  local user
  user=$(pick_client) || return

  # Password mode
  local pass_mode newpass
  pass_mode=$(whiptail --backtitle "$BACKTITLE" --title "Новый пароль для '$user'" \
    --menu "Новый пароль:" 12 60 2 \
    "1" "Сгенерировать (24 символа)" \
    "2" "Ввести вручную" \
    3>&1 1>&2 2>&3) || return

  case "$pass_mode" in
    1) newpass="$(gen_random 24)" ;;
    2)
      newpass=$(ask_password "Пароль" "Введите новый пароль для '$user':") || return
      ;;
  esac
  validate_password_input "$newpass" || { msg_error "Невалидный пароль"; return 1; }

  backup_now >/d
