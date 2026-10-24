#!/bin/bash
# Publica o .deb de dist/ num repositório apt na branch gh-pages (GitHub Pages).
# Uso: GPG_KEY=<id-da-chave> ./packaging/apt/publish_apt_repo.sh
# (adicione PUSH=1 para enviar a branch ao GitHub)
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${GPG_KEY:?Defina GPG_KEY com o ID da sua chave GPG (gpg --list-secret-keys)}"
CODENAME=stable
DEBS=("$ROOT"/dist/openoia_*_amd64.deb)
[ -f "${DEBS[0]}" ] || { echo "Rode ./build_packages.sh antes (falta dist/*.deb)"; exit 1; }

WT="$(mktemp -d)"
trap 'git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true' EXIT
cd "$ROOT"
git fetch origin gh-pages 2>/dev/null || true
if git show-ref --verify --quiet refs/remotes/origin/gh-pages; then
  git worktree add -B gh-pages "$WT" origin/gh-pages
else
  git worktree add --detach "$WT"
  git -C "$WT" checkout --orphan gh-pages
  git -C "$WT" rm -rf . >/dev/null 2>&1 || true
fi
cd "$WT"

mkdir -p pool/main/o/openoia "dists/$CODENAME/main/binary-amd64"
cp "${DEBS[@]}" pool/main/o/openoia/

apt-ftparchive packages pool > "dists/$CODENAME/main/binary-amd64/Packages"
gzip -kf9 "dists/$CODENAME/main/binary-amd64/Packages"
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=Openoia \
  -o APT::FTPArchive::Release::Label=Openoia \
  -o APT::FTPArchive::Release::Suite=$CODENAME \
  -o APT::FTPArchive::Release::Codename=$CODENAME \
  -o APT::FTPArchive::Release::Architectures=amd64 \
  -o APT::FTPArchive::Release::Components=main \
  release "dists/$CODENAME" > "dists/$CODENAME/Release"

gpg --batch --yes -u "$GPG_KEY" --clearsign -o "dists/$CODENAME/InRelease" "dists/$CODENAME/Release"
gpg --batch --yes -u "$GPG_KEY" -abs -o "dists/$CODENAME/Release.gpg" "dists/$CODENAME/Release"
gpg --export "$GPG_KEY" > openoia.gpg   # chave binária, usada com signed-by
cp "$ROOT/packaging/apt/install.sh" install.sh
touch .nojekyll
cat > index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>Openoia APT</title>
<pre>curl -fsSL https://jhonathanvitor.github.io/openoia/install.sh | sudo bash

# ou manualmente:
curl -fsSL https://jhonathanvitor.github.io/openoia/openoia.gpg | sudo tee /usr/share/keyrings/openoia.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/openoia.gpg] https://jhonathanvitor.github.io/openoia stable main" | sudo tee /etc/apt/sources.list.d/openoia.list
sudo apt update &amp;&amp; sudo apt install openoia</pre>
HTML

git add -A
git commit -m "apt repo: openoia $(basename "${DEBS[0]}")" >/dev/null
if [ -n "$PUSH" ]; then git push origin gh-pages; else echo "Commit criado na branch gh-pages. Envie com: git push origin gh-pages"; fi
