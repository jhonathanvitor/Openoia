#!/bin/bash
# Gera pacotes .deb, .rpm e .tar.gz do Openoia usando fpm.
# O helper de root (/usr/local/bin/vpn-openoia-root-helper) e o sudoers NÃO entram nos
# pacotes: continuam sendo instalados pelo próprio app em tempo de execução.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSROOT="$HOME/.local/flutter-sysroot"

export PATH="$HOME/.local/flutter/bin:$SYSROOT/usr/bin:$SYSROOT/usr/lib/llvm-18/bin:$PATH"
export CMAKE_ROOT="$SYSROOT/usr/share/cmake-3.28"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu:$SYSROOT/usr/lib/llvm-18/lib"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
export CPLUS_INCLUDE_PATH="$SYSROOT/usr/include/x86_64-linux-gnu:$SYSROOT/usr/include"
export C_INCLUDE_PATH="$SYSROOT/usr/include/x86_64-linux-gnu:$SYSROOT/usr/include"
export LIBRARY_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
export LDFLAGS="-L$SYSROOT/usr/lib/x86_64-linux-gnu -ldl"

if ! command -v fpm >/dev/null 2>&1; then
  echo "Erro: fpm não encontrado. Instale com:"
  echo "  sudo apt install ruby ruby-dev build-essential rpm && sudo gem install fpm"
  exit 1
fi

NAME="openoia"
VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$PROJECT_DIR/pubspec.yaml" | head -1)"
VERSION="${VERSION:-1.0.0}"
OUT_DIR="$PROJECT_DIR/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "1/3 Compilando projeto Flutter Openoia para Linux..."
cd "$PROJECT_DIR"
mkdir -p build/native_assets/linux
flutter build linux --release

BUNDLE="$PROJECT_DIR/build/linux/x64/release/bundle"

echo "2/3 Montando árvore de instalação..."
mkdir -p "$STAGE/opt/openoia" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/256x256/apps" \
         "$STAGE/usr/share/icons/hicolor/scalable/apps"

cp -a "$BUNDLE/." "$STAGE/opt/openoia/"
if [ -x "$PROJECT_DIR/assets/puttygen" ]; then
  # O app procura o puttygen ao lado do executável.
  cp "$PROJECT_DIR/assets/puttygen" "$STAGE/opt/openoia/puttygen"
  chmod 755 "$STAGE/opt/openoia/puttygen"
fi
ln -s /opt/openoia/vpn_openoia "$STAGE/usr/bin/openoia"

# O tray e a janela procuram estes PNGs em /usr/share/icons/hicolor/256x256/apps
ICONS="$PROJECT_DIR/assets/icons"
cp "$ICONS/vpn-openoia-256.png"          "$STAGE/usr/share/icons/hicolor/256x256/apps/vpn-openoia.png"
cp "$ICONS/vpn-openoia-connected.png"    "$STAGE/usr/share/icons/hicolor/256x256/apps/vpn-openoia-connected.png"
cp "$ICONS/vpn-openoia-disconnected.png" "$STAGE/usr/share/icons/hicolor/256x256/apps/vpn-openoia-disconnected.png"
cp "$ICONS/vpn-openoia.svg"              "$STAGE/usr/share/icons/hicolor/scalable/apps/vpn-openoia.svg"

# Nome do arquivo = application-id do GTK (com.openoia.vpn), para o shell associar a janela.
cat > "$STAGE/usr/share/applications/com.openoia.vpn.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Openoia
Comment=Cliente VPN & SSH/SFTP
Exec=/opt/openoia/vpn_openoia
Icon=vpn-openoia
Terminal=false
Categories=Network;
StartupNotify=true
StartupWMClass=com.openoia.vpn
EOF

find "$STAGE" -type d -exec chmod 755 {} +
chmod 644 "$STAGE"/usr/share/applications/*.desktop \
          "$STAGE"/usr/share/icons/hicolor/*/apps/*

echo "3/3 Gerando pacotes com fpm em $OUT_DIR ..."
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/${NAME}[_-]${VERSION}* "$OUT_DIR"/${NAME}-*.tar.gz

COMMON=(
  -s dir -n "$NAME" -v "$VERSION" -a amd64
  --description "Openoia - Cliente Desktop Linux para OpenVPN, SSH e SFTP."
  --url "https://github.com/jhonathanvitor/openoia"
  --maintainer "jhonathanvitor <jhonathanvitor@gmail.com>"
  -C "$STAGE"
)

fpm -t deb "${COMMON[@]}" \
  -d "libgtk-3-0" -d "libsecret-1-0" -d "openvpn" -d "openssh-client" -d "python3" \
  -d "libayatana-appindicator3-1 | libappindicator3-1" -d "zenity" \
  -p "$OUT_DIR/${NAME}_${VERSION}_amd64.deb" .

fpm -t rpm "${COMMON[@]}" \
  -a x86_64 \
  -d "gtk3" -d "libsecret" -d "openvpn" -d "openssh-clients" -d "python3" \
  -d "libayatana-appindicator-gtk3" -d "zenity" \
  -p "$OUT_DIR/${NAME}-${VERSION}-1.x86_64.rpm" .

fpm -t tar "${COMMON[@]}" -p "$OUT_DIR/${NAME}-${VERSION}-linux-x64.tar" .
gzip -f "$OUT_DIR/${NAME}-${VERSION}-linux-x64.tar"

echo "Pacotes gerados:"
ls -la "$OUT_DIR"
echo "BUILD_PACKAGES_COMPLETE"
