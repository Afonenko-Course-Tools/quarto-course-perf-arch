#!/usr/bin/env bash
set -euo pipefail
# Один и тот же цикл для локальной проверки и GitHub Actions; нужен rootless Podman.
repo=$(cd "$(dirname "$0")/.." && pwd)
git -C "$repo" diff --quiet HEAD -- || { echo 'Сначала зафиксируйте изменения проверяемого дерева' >&2; exit 1; }
packaging_commit=$(git -C "$repo" rev-parse HEAD)
evidence=${1:?Укажите внешний абсолютный каталог результатов}
[[ $evidence = /* ]] || { echo 'Нужен абсолютный путь' >&2; exit 1; }
cache=${PERF_ARCH_CACHE:-"$(dirname "$evidence")/quarto-course-perf-arch-cache"}
[[ $cache = /* && $cache != "$evidence" ]] || { echo 'Кэш должен быть отдельным абсолютным каталогом' >&2; exit 1; }
mkdir -p "$(dirname "$evidence")" "$cache/source-cache"
mkdir "$evidence" || { echo 'Для каждого запуска требуется новый каталог результатов' >&2; exit 1; }
image='docker.io/library/archlinux@sha256:3cbf69d2d5958d6a294f3722c5668e6187c4df8e00fa27f72352f0bf83e495e1'
# Отдельное хранилище не затрагивает другие среды на ноутбуке.
podman=(podman --root "$cache/podman-root" --runroot "$cache/podman-run" --storage-driver vfs)
name="perf-arch-$$"
trap '"${podman[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
printf '%s\n' "$image" > "$evidence/image.txt"
# Ubuntu runner поставляет Podman без pull --policy; image exists поддерживается им.
if ! "${podman[@]}" image exists "$image"; then
  "${podman[@]}" pull "$image" > "$evidence/pull.log" 2>&1
else
  printf 'Использован закреплённый образ из кэша: %s\n' "$image" > "$evidence/pull.log"
fi
"${podman[@]}" run -i --name "$name" --network host --userns keep-id:uid=1000,gid=1000 --user root \
  -v "$repo:/input:ro" -v "$evidence:/evidence:rw" -v "$cache/source-cache:/source-cache:rw" -e PACKAGING_COMMIT="$packaging_commit" "$image" bash -s > "$evidence/build.log" 2>&1 <<'ARCH'
set -euxo pipefail
# Несколько подписанных Arch mirrors: один недоступный CDN не должен ломать приёмку.
cat > /etc/pacman.d/mirrorlist <<'MIRRORS'
Server = https://archlinux.cachyos.org/repo/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch
MIRRORS
# libalpm в этой среде зависает при загрузке некоторых .sig, а curl получает их.
# Штатный XferCommand меняет транспорт, подписи pacman проверяет как обычно.
sed -i '/^\[options\]/a XferCommand = /usr/bin/curl --http1.1 --fail --location --retry 3 --connect-timeout 20 --output %o %u' /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel deno time util-linux namcap curl git python sudo typescript
useradd -m -u 1000 builder
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
mkdir -p /work
chown builder:builder /work
# Только отслеживаемое дерево: артефакты и developer-кэши не переносятся.
sudo -u builder git -c safe.directory=/input clone --no-hardlinks --no-checkout /input /work/repo
sudo -u builder git -C /work/repo checkout --detach "$PACKAGING_COMMIT"
sudo -u builder git -C /work/repo rev-parse HEAD > /evidence/clone-commit.txt
[[ $(cat /evidence/clone-commit.txt) == "$PACKAGING_COMMIT" ]]
# Кэш только скачанных опубликованных архивов: makepkg проверяет суммы на каждом запуске.
install -d -m755 -o builder -g builder /source-cache
printf '\nSRCDEST=/source-cache\n' >> /etc/makepkg.conf
cd /work/repo
sudo -u builder bash -c 'makepkg --printsrcinfo | diff -u .SRCINFO -'
# Source URL, версия и integrity принадлежат штатному рецепту makepkg.
source PKGBUILD
printf '%s\n' "/work/repo/src/quarto-course-performance-${pkgver}" > /evidence/performance-source-root.txt
pacman -Q > /evidence/arch-packages.txt
makepkg --version > /evidence/makepkg-version.txt
pacman --version > /evidence/pacman-version.txt
deno --version > /evidence/deno-version.txt
tsc --version > /evidence/typescript-version.txt
# Отрицательный контроль: настоящий Quarto обязателен ещё до сборки.
if sudo -u builder makepkg --cleanbuild --force > /evidence/missing-quarto.log 2>&1; then
  echo 'Пропущена обязательная зависимость quarto'; exit 1
fi
grep -q "Missing dependencies:" /evidence/missing-quarto.log
grep -q "  -> quarto" /evidence/missing-quarto.log
sudo -u builder bash -c "makepkg --printsrcinfo | sed 's/pkgver = $pkgver/pkgver = 0.0.0/'" > /tmp/stale-srcinfo
if diff -u .SRCINFO /tmp/stale-srcinfo > /evidence/stale-srcinfo.log; then exit 1; fi
cd ci/quarto
sudo -u builder makepkg --cleanbuild --force --noconfirm
mapfile -t quarto_packages < <(sudo -u builder makepkg --packagelist)
[[ ${#quarto_packages[@]} = 1 && -f ${quarto_packages[0]} ]]
pacman -U --noconfirm "${quarto_packages[0]}"
quarto --version > /evidence/quarto-version.txt
cd /work/repo
sudo -u builder makepkg --verifysource > /evidence/verifysource.log 2>&1
# Контроль работает с отдельной копией SRCDEST: interruption не портит общий кэш.
source_archives=()
for entry in "${source[@]}"; do
  filename=${entry%%::*}
  filename=${filename##*/}
  source_archives+=("/source-cache/$filename")
done
source_archive=${source_archives[0]}
negative_sources=$(mktemp -d /tmp/perf-corrupt-source.XXXXXXXX)
chown builder:builder "$negative_sources"
cp "${source_archives[@]}" "$negative_sources/"
printf '\ncorrupt\n' >> "$negative_sources/$(basename "$source_archive")"
cp /etc/makepkg.conf /tmp/makepkg-corrupt.conf
printf '\nSRCDEST=%q\n' "$negative_sources" >> /tmp/makepkg-corrupt.conf
if sudo -u builder makepkg --config /tmp/makepkg-corrupt.conf --verifysource > /evidence/corrupt-source.log 2>&1; then exit 1; fi
grep -qi 'FAILED' /evidence/corrupt-source.log
rm -rf "$negative_sources"
sudo -u builder makepkg --cleanbuild --force --noconfirm > /evidence/makepkg.log 2>&1
sudo -u builder makepkg --packagelist > /evidence/packagelist.txt
package=$(while IFS= read -r p; do if [[ -f $p && $(basename "$p") = "$pkgname-$pkgver-$pkgrel-any.pkg.tar."* ]]; then printf '%s\n' "$p"; fi; done < /evidence/packagelist.txt)
[[ -n $package && $(wc -l <<< "$package") = 1 ]]
pacman -Qlp "$package" > /evidence/package-files.txt
namcap_status=0
namcap PKGBUILD "$package" > /evidence/namcap.log 2>&1 || namcap_status=$?
printf '%s\n' "$namcap_status" > /evidence/namcap-status.txt
pacman -U --noconfirm "$package"
cp "$package" /evidence/
sha256sum PKGBUILD .SRCINFO "${source_archives[@]}" /source-cache/quarto-1.11.6-linux-amd64.tar.gz "$package" > /evidence/SHA256SUMS
pacman -Q quarto-course-perf quarto-ci deno typescript > /evidence/installed-packages.txt
chown -R builder:builder /work
ARCH
# Сохранить установленный системный Compiler API и checker, затем отключить сеть и запись системного дерева.
local_image="localhost/perf-arch-checked:$$"
"${podman[@]}" commit "$name" "$local_image" > "$evidence/prepared-image.txt"
"${podman[@]}" run --rm --userns keep-id:uid=1000,gid=1000 --user builder --network none --read-only \
  --tmpfs /tmp:rw,exec,size=2g --tmpfs /home/builder:rw,exec,size=1g \
  -v "$evidence:/evidence:rw" -e EVIDENCE=/evidence/smoke \
  -e PERF_SOURCE_ROOT="$(cat "$evidence/performance-source-root.txt")" \
  "$local_image" bash /work/repo/tests/installed-smoke.sh > "$evidence/smoke.log" 2>&1
"${podman[@]}" image inspect "$local_image" > "$evidence/prepared-image-inspect.json"
python3 - "$evidence" "$(cat "$evidence/clone-commit.txt")" <<'REPORT'
import hashlib, json, pathlib, sys
p=pathlib.Path(sys.argv[1])
result={
  'status':'PASS', 'packaging_commit':sys.argv[2],
  'upstream_version':(p/'smoke/version.log').read_text().strip(),
  'image':(p/'image.txt').read_text().strip(),
  'checks':{'makepkg_printsrcinfo':0,'makepkg_verifysource':0,'makepkg_cleanbuild_force':0,'pacman_install':0,'public_wrapper_summary':0,'installed_ts_trace':0},
  'negative_controls':{'missing_quarto':'rejected','corrupt_source':'rejected','stale_srcinfo':'rejected'},
  'hashes':(p/'SHA256SUMS').read_text(),
  'versions':{name:(p/(name+'-version.txt')).read_text() for name in ['pacman','makepkg','deno','quarto','typescript']},
  'commands':[
    'makepkg --printsrcinfo | diff -u .SRCINFO -',
    'makepkg --verifysource',
    'makepkg --cleanbuild --force --noconfirm',
    'makepkg --packagelist', 'pacman -Qlp PACKAGE', 'namcap PKGBUILD PACKAGE',
    'pacman -U --noconfirm PACKAGE',
    '/usr/bin/quarto-course-perf render --perf-mode summary --perf-output /evidence/smoke/summary index.qmd',
    'deno run --config PERF_SOURCE_ROOT/deno.json --lock PERF_SOURCE_ROOT/deno.lock --frozen --cached-only -A PERF_SOURCE_ROOT/tools/check-installed.ts --root /usr/lib/quarto-course-perf'
  ],
  'namcap_status':int((p/'namcap-status.txt').read_text()),
  'namcap':(p/'namcap.log').read_text(),
  'installed_tree':json.loads((p/'smoke/installed-tree.json').read_text()),
  'checker':(p/'smoke/installed-checker.log').read_text(),
  'package':[{ 'file':f.name,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in p.glob('quarto-course-perf-*.pkg.tar.zst')],
  'limits':['Лицензия исходного приложения не объявлена; namcap содержит замечания.', 'Побайтная воспроизводимость пакета не заявлена.']
}
(p/'package-checks.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
REPORT
echo 'Сборка, pacman и изолированная проверка: PASS' 
