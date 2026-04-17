#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  NaïveProxy Manager — установщик короткой команды
#  Добавляет команду `naive` в /usr/local/bin
# ═══════════════════════════════════════════════════════════
set -euo pipefail

REPO="pumbaX/naiv"
BRANCH="main"
SCRIPT_NAME="NaiveProxy.sh"
INSTALL_PATH="/usr/local/bin/naive"

# Автоматически поднимаем права до root через sudo
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "🔑 Требуются root-права, перезапускаю через sudo..."
    exec sudo bash -c "bash <(curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh)"
  else
    echo "❌ Запустите от root (sudo не установлен)"
    exit 1
  fi
fi

echo "📦 Устанавливаю команду 'naive'..."

cat > "$INSTALL_PATH" <<EOF
#!/usr/bin/env bash
# Обёртка для NaïveProxy Manager
# Скачивает последнюю версию скрипта и запускает
exec bash <(curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/${SCRIPT_NAME}") "\$@"
EOF

chmod +x "$INSTALL_PATH"

echo "✔ Установлено в $INSTALL_PATH"
echo ""
echo "Теперь запускай одной командой:"
echo ""
echo "  naive"
echo ""
