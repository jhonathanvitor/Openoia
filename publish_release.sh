#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPIMAGE_PATH="$HOME/Downloads/VPN-Openoia-x86_64.AppImage"
DIST_DIR="$PROJECT_DIR/dist"
REPO="jhonathanvitor/openoia"
TAG="${1:-v1.0.0}"

# Arquivos a enviar no formato "caminho|nome do asset na Release".
# O AppImage mantém o nome público Openoia-x86_64.AppImage; os pacotes
# (.deb, .rpm, .tar.gz) vêm de dist/ (gerados por ./build_packages.sh).
FILES=()

if [ ! -f "$APPIMAGE_PATH" ]; then
  echo "Erro: Arquivo $APPIMAGE_PATH não encontrado."
  exit 1
fi
FILES+=("$APPIMAGE_PATH|Openoia-x86_64.AppImage")

shopt -s nullglob
for f in "$DIST_DIR"/*.deb "$DIST_DIR"/*.rpm "$DIST_DIR"/*.tar.gz; do
  FILES+=("$f|$(basename "$f")")
done
shopt -u nullglob

if [ ${#FILES[@]} -eq 1 ]; then
  echo "Aviso: nenhum pacote encontrado em $DIST_DIR (rode ./build_packages.sh). Enviando só o AppImage."
fi

echo "=========================================="
echo " Atualizar / Publicar no GitHub ($REPO - $TAG)"
echo " Arquivos que serão enviados:"
for entry in "${FILES[@]}"; do
  echo "   - ${entry#*|}"
done
echo "=========================================="
read -rsp "Cole o seu Token do GitHub (ghp_...) e aperte Enter: " TOKEN
echo ""

if [ -z "$TOKEN" ]; then
  echo "Erro: O Token não pode estar vazio."
  exit 1
fi

json_get() {
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',''))" 2>/dev/null || true
}

echo "1/4 Localizando ou criando a Release $TAG no GitHub..."
RESP=$(curl -s \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/tags/$TAG")

RELEASE_ID=$(echo "$RESP" | json_get id)

if [ -z "$RELEASE_ID" ]; then
  RESP=$(curl -s -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases" \
    -d "{\"tag_name\":\"$TAG\",\"target_commitish\":\"main\",\"name\":\"Openoia $TAG\",\"body\":\"Aplicativo Desktop Linux **Openoia** (Cliente OpenVPN + Workspace SSH & SFTP com Snippets).\\n\\n### Como executar (AppImage):\\n\`\`\`bash\\nchmod +x Openoia-x86_64.AppImage\\n./Openoia-x86_64.AppImage\\n\`\`\`\\n\\n### Pacotes:\\n- Debian/Ubuntu: \`sudo apt install ./openoia_*_amd64.deb\`\\n- Fedora/RHEL: \`sudo dnf install ./openoia-*.x86_64.rpm\`\\n- Genérico: \`openoia-*-linux-x64.tar.gz\`\",\"draft\":false,\"prerelease\":false}")
  RELEASE_ID=$(echo "$RESP" | json_get id)
fi

if [ -z "$RELEASE_ID" ]; then
  echo "Erro ao localizar/criar Release no GitHub. Resposta da API:"
  echo "$RESP"
  exit 1
fi

echo "2/4 Removendo versões anteriores dos arquivos na Release (se já existirem)..."
ASSETS=$(curl -s \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/$RELEASE_ID/assets?per_page=100")

for entry in "${FILES[@]}"; do
  NAME="${entry#*|}"
  OLD_ASSET_ID=$(echo "$ASSETS" | NAME="$NAME" python3 -c "
import sys, os, json
for a in json.load(sys.stdin):
    if a.get('name') == os.environ['NAME']:
        print(a.get('id'))
        break
" 2>/dev/null || true)
  if [ -n "$OLD_ASSET_ID" ]; then
    curl -s -X DELETE \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/releases/assets/$OLD_ASSET_ID" >/dev/null
    echo "    $NAME anterior removido."
  fi
done

echo "3/4 Enviando arquivos para a Release (ID: $RELEASE_ID)..."
FAILED=0
for entry in "${FILES[@]}"; do
  FILE="${entry%%|*}"
  NAME="${entry#*|}"
  echo "    Enviando $NAME..."
  UPLOAD_RESP=$(curl -s -L -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$FILE" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$NAME")
  DOWNLOAD_URL=$(echo "$UPLOAD_RESP" | json_get browser_download_url)
  if [ -n "$DOWNLOAD_URL" ]; then
    echo "    ✅ $DOWNLOAD_URL"
  else
    echo "    ❌ Falha ao enviar $NAME. Resposta do upload:"
    echo "$UPLOAD_RESP"
    FAILED=1
  fi
done

echo "4/4 Finalizado!"
echo "🔗 Página da Release: https://github.com/$REPO/releases/tag/$TAG"
if [ "$FAILED" -ne 0 ]; then
  echo "Alguns arquivos não foram enviados (veja acima)."
  exit 1
fi
