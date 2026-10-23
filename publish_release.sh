#!/bin/bash
set -e

APPIMAGE_PATH="$HOME/Downloads/VPN-Openoia-x86_64.AppImage"
REPO="jhonathanvitor/openoia"
TAG="${1:-v1.0.0}"

if [ ! -f "$APPIMAGE_PATH" ]; then
  echo "Erro: Arquivo $APPIMAGE_PATH não encontrado."
  exit 1
fi

echo "=========================================="
echo " Atualizar / Publicar AppImage no GitHub ($REPO - $TAG)"
echo "=========================================="
read -rsp "Cole o seu Token do GitHub (ghp_...) e aperte Enter: " TOKEN
echo ""

if [ -z "$TOKEN" ]; then
  echo "Erro: O Token não pode estar vazio."
  exit 1
fi

echo "1/4 Localizando ou criando a Release $TAG no GitHub..."
RESP=$(curl -s \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/tags/$TAG")

RELEASE_ID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

if [ -z "$RELEASE_ID" ]; then
  RESP=$(curl -s -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases" \
    -d "{\"tag_name\":\"$TAG\",\"target_commitish\":\"main\",\"name\":\"Openoia $TAG\",\"body\":\"Aplicativo Desktop Linux **Openoia** (Cliente OpenVPN + Workspace SSH & SFTP com Snippets).\\n\\n### Como executar:\\n\`\`\`bash\\nchmod +x Openoia-x86_64.AppImage\\n./Openoia-x86_64.AppImage\\n\`\`\`\",\"draft\":false,\"prerelease\":false}")
  RELEASE_ID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
fi

if [ -z "$RELEASE_ID" ]; then
  echo "Erro ao localizar/criar Release no GitHub. Resposta da API:"
  echo "$RESP"
  exit 1
fi

echo "2/4 Removendo AppImage anterior da Release (se já existir)..."
OLD_ASSET_ID=$(echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if a.get('name') == 'Openoia-x86_64.AppImage':
        print(a.get('id'))
        break
" 2>/dev/null || true)

if [ -n "$OLD_ASSET_ID" ]; then
  curl -s -X DELETE \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases/assets/$OLD_ASSET_ID" >/dev/null
  echo "    Arquivo antigo removido. Subindo a versão nova..."
fi

echo "3/4 Enviando novo arquivo AppImage atualizado para a Release (ID: $RELEASE_ID)..."
UPLOAD_RESP=$(curl -s -L -X POST \
  -H "Authorization: token $TOKEN" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$APPIMAGE_PATH" \
  "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=Openoia-x86_64.AppImage")

DOWNLOAD_URL=$(echo "$UPLOAD_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('browser_download_url',''))" 2>/dev/null || true)

echo "4/4 Finalizado!"
if [ -n "$DOWNLOAD_URL" ]; then
  echo "✅ AppImage atualizado com sucesso no GitHub Releases!"
  echo "🔗 Página da Release: https://github.com/$REPO/releases/tag/$TAG"
  echo "⬇️ Link direto de download: $DOWNLOAD_URL"
else
  echo "Resposta do upload:"
  echo "$UPLOAD_RESP"
fi
