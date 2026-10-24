#!/bin/bash
# Gera o pacote-fonte para o PPA a partir do tar.gz criado por build_packages.sh.
# Uso: ./build_source_package.sh [serie...]   (padrão: noble)
# Para enviar:  dput ppa:SEU_USUARIO/openoia <arquivo>_source.changes
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$ROOT/pubspec.yaml" | head -1)"
TARBALL="$ROOT/dist/openoia-${VERSION}-linux-x64.tar.gz"
[ -f "$TARBALL" ] || { echo "Rode ./build_packages.sh antes (falta $TARBALL)"; exit 1; }
SERIES=("${@:-noble}")
REV="${PPA_REV:-1}"
OUT="$ROOT/dist/ppa"
rm -rf "$OUT"; mkdir -p "$OUT/openoia-$VERSION"
cd "$OUT"

tar -xzf "$TARBALL" -C "openoia-$VERSION"
tar -czf "openoia_${VERSION}.orig.tar.gz" "openoia-$VERSION"

for S in "${SERIES[@]}"; do
  rm -rf "openoia-$VERSION/debian"
  cp -r "$HERE/debian" "openoia-$VERSION/debian"
  cat > "openoia-$VERSION/debian/changelog" <<CL
openoia (${VERSION}-0ppa${REV}~${S}1) ${S}; urgency=medium

  * Release ${VERSION}.

 -- Jhonathan Vitor <jhonathanvitor@gmail.com>  $(date -R)
CL
  # -sa inclui o orig.tar.gz; nas séries seguintes use -sd (já enviado)
  OPT=-sd; [ "$S" = "${SERIES[0]}" ] && OPT=-sa
  (cd "openoia-$VERSION" && debuild -S $OPT)
done
echo "Pronto em $OUT. Envie com: dput ppa:SEU_USUARIO/openoia $OUT/*_source.changes"
