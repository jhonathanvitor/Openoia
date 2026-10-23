#!/bin/bash
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

echo "1/2 Compilando projeto Flutter Openoia para Linux..."
cd "$PROJECT_DIR"
flutter build linux --release

echo "2/2 Gerando arquivo VPN-Openoia-x86_64.AppImage (sem nenhum perfil .ovpn embutido)..."
if [ ! -x /tmp/appimagetool ]; then
  curl -L -s -o /tmp/appimagetool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x /tmp/appimagetool
fi

mkdir -p ~/.local/share/icons/hicolor/256x256/apps \
         ~/.local/share/icons/hicolor/scalable/apps \
         ~/.local/share/applications \
         ~/.local/share/openoia

cp -f "$PROJECT_DIR/assets/icons/vpn-openoia-256.png" ~/.local/share/icons/hicolor/256x256/apps/vpn-openoia.png
cp -f "$PROJECT_DIR/assets/icons/vpn-openoia.svg" ~/.local/share/icons/hicolor/scalable/apps/vpn-openoia.svg

rm -rf /tmp/VPN-Openoia.AppDir
mkdir -p /tmp/VPN-Openoia.AppDir/usr/bundle \
         /tmp/VPN-Openoia.AppDir/usr/bin \
         /tmp/VPN-Openoia.AppDir/usr/share/vpn-openoia \
         /tmp/VPN-Openoia.AppDir/usr/share/icons/hicolor/scalable/apps \
         /tmp/VPN-Openoia.AppDir/usr/share/icons/hicolor/256x256/apps

cp -a "$PROJECT_DIR/build/linux/x64/release/bundle/"* /tmp/VPN-Openoia.AppDir/usr/bundle/
if [ -x "$PROJECT_DIR/assets/puttygen" ]; then
  cp "$PROJECT_DIR/assets/puttygen" /tmp/VPN-Openoia.AppDir/usr/bin/puttygen
  chmod +x /tmp/VPN-Openoia.AppDir/usr/bin/puttygen
fi

# NOTE: Never bundle any .ovpn or user credential file inside the AppDir!
cp "$PROJECT_DIR/assets/icons/vpn-openoia-256.png" /tmp/VPN-Openoia.AppDir/usr/share/vpn-openoia/vpn-openoia.png
cp "$PROJECT_DIR/assets/icons/vpn-openoia-disconnected.png" /tmp/VPN-Openoia.AppDir/usr/share/vpn-openoia/vpn-openoia-disconnected.png
cp "$PROJECT_DIR/assets/icons/vpn-openoia-connected.png" /tmp/VPN-Openoia.AppDir/usr/share/vpn-openoia/vpn-openoia-connected.png
cp "$PROJECT_DIR/assets/icons/vpn-openoia.svg" /tmp/VPN-Openoia.AppDir/usr/share/vpn-openoia/vpn-openoia.svg

cat << 'EOF' > /tmp/VPN-Openoia.AppDir/AppRun
#!/bin/sh
SELF=$(readlink -f "$0")
HERE=${SELF%/*}
export APPDIR="$HERE"
exec "$HERE/usr/bundle/vpn_openoia" "$@"
EOF
chmod +x /tmp/VPN-Openoia.AppDir/AppRun

cat << 'EOF' > /tmp/VPN-Openoia.AppDir/vpn-openoia.desktop
[Desktop Entry]
Type=Application
Name=Openoia
Comment=Cliente VPN & SSH/SFTP
Exec=vpn_openoia
Icon=vpn-openoia
Categories=Network;
Terminal=false
StartupNotify=true
StartupWMClass=com.openoia.vpn
EOF

cp "$PROJECT_DIR/assets/icons/vpn-openoia-256.png" /tmp/VPN-Openoia.AppDir/vpn-openoia.png
cp "$PROJECT_DIR/assets/icons/vpn-openoia-256.png" /tmp/VPN-Openoia.AppDir/.DirIcon
cp "$PROJECT_DIR/assets/icons/vpn-openoia.svg" /tmp/VPN-Openoia.AppDir/usr/share/icons/hicolor/scalable/apps/vpn-openoia.svg
cp "$PROJECT_DIR/assets/icons/vpn-openoia-256.png" /tmp/VPN-Openoia.AppDir/usr/share/icons/hicolor/256x256/apps/vpn-openoia.png

rm -f /tmp/VPN-Openoia.AppImage
ARCH=x86_64 /tmp/appimagetool --appimage-extract-and-run /tmp/VPN-Openoia.AppDir /tmp/VPN-Openoia.AppImage
chmod +x /tmp/VPN-Openoia.AppImage

cp /tmp/VPN-Openoia.AppImage /tmp/v1.AppImage && mv -f /tmp/v1.AppImage "$HOME/.local/share/openoia/VPN-Openoia-x86_64.AppImage"
cp /tmp/VPN-Openoia.AppImage /tmp/v3.AppImage && mv -f /tmp/v3.AppImage "$HOME/Downloads/VPN-Openoia-x86_64.AppImage"

cat << EOF > "$HOME/Área de trabalho/VPN-Openoia.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Openoia
Comment=Cliente VPN & SSH/SFTP
Exec=$HOME/.local/share/openoia/VPN-Openoia-x86_64.AppImage
Icon=$HOME/.local/share/icons/hicolor/256x256/apps/vpn-openoia.png
Terminal=false
Categories=Network;
StartupNotify=true
StartupWMClass=com.openoia.vpn
EOF

cp -f "$HOME/Área de trabalho/VPN-Openoia.desktop" ~/.local/share/applications/vpn-openoia.desktop
chmod +x "$HOME/Área de trabalho/VPN-Openoia.desktop" ~/.local/share/applications/vpn-openoia.desktop
gio set "$HOME/Área de trabalho/VPN-Openoia.desktop" metadata::trusted true 2>/dev/null || true
gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null || true
update-desktop-database ~/.local/share/applications 2>/dev/null || true

rm -rf /tmp/VPN-Openoia.AppDir /tmp/VPN-Openoia.AppImage
echo "BUILD_OPENOIA_COMPLETE"
