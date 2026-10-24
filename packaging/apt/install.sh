#!/bin/sh
# Configura o repositório apt do Openoia e instala o app.
# Uso: curl -fsSL https://jhonathanvitor.github.io/openoia/install.sh | sudo bash
set -e
BASE="https://jhonathanvitor.github.io/openoia"

if [ "$(id -u)" -ne 0 ]; then
  echo "Execute como root: curl -fsSL $BASE/install.sh | sudo bash" >&2
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  echo "Este instalador requer um sistema com apt (Ubuntu/Debian)." >&2
  exit 1
fi
if [ "$(dpkg --print-architecture)" != "amd64" ]; then
  echo "O Openoia só está disponível para amd64." >&2
  exit 1
fi

apt-get install -y curl ca-certificates >/dev/null
curl -fsSL "$BASE/openoia.gpg" -o /usr/share/keyrings/openoia.gpg
echo "deb [signed-by=/usr/share/keyrings/openoia.gpg] $BASE stable main" > /etc/apt/sources.list.d/openoia.list
apt-get update
apt-get install -y openoia
echo "Openoia instalado. Atualizações: sudo apt update && sudo apt upgrade"
