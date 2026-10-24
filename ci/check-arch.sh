#!/usr/bin/env bash
set -euo pipefail
# Один и тот же цикл для локальной проверки и GitHub Actions; нужен rootless Podman.
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${1:?Укажите внешний абсолютный каталог результатов}
[[ $evidence = /* ]] || { echo 'Нужен абсолютный путь' >&2; exit 1; }
mkdir -p "$evidence"
image='docker.io/library/archlinux@sha256:3cbf69d2d5958d6a294f3722c5668e6187c4df8e00fa27f72352f0bf83e495e1'
# Отдельное хранилище не затрагивает другие среды на ноутбуке.
podman=(podman --root "$evidence/podman-root" --runroot "$evidence/podman-run" --storage-driver vfs)
name="perf-arch-$$"
trap '"${podman[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
printf '%s\n' "$image" > "$evidence/image.txt"
"${podman[@]}" pull "$image" > "$evidence/pull.log" 2>&1
"${podman[@]}" run --name "$name" --userns keep-id:uid=1000,gid=1000 --user root \
  -v "$repo:/input:ro" -v "$evidence:/evidence:rw" "$image" bash -s > "$evidence/build.log" 2>&1 <<'ARCH'
set -euxo pipefail
pacman -Syu --noconfirm --needed base-devel deno time util-linux namcap curl git python sudo
useradd -m -u 1000 builder
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
mkdir -p /work
chown builder:builder /work
# Только отслеживаемое дерево: артефакты и developer-кэши не переносятся.
sudo -u builder git -c safe.directory=/input clone --no-hardlinks /input /work/repo
cd /work/repo
sudo -u builder bash -c 'makepkg --printsrcinfo | diff -u .SRCINFO -'
pacman -Q > /evidence/arch-packages.txt
makepkg --version > /evidence/makepkg-version.txt
pacman --version > /evidence/pacman-version.txt
deno --version > /evidence/deno-version.txt
# Отрицательный контроль: настоящий Quarto обязателен ещё до сборки.
if sudo -u builder makepkg --cleanbuild --force > /evidence/missing-quarto.log 2>&1; then
  echo 'Пропущена обязательная зависимость quarto'; exit 1
fi
grep -q quarto /evidence/missing-quarto.log
sudo -u builder bash -c 'makepkg --printsrcinfo; echo "# устаревший metadata"' > /tmp/stale-srcinfo
if diff -u .SRCINFO /tmp/stale-srcinfo > /evidence/stale-srcinfo.log; then exit 1; fi
cd ci/quarto
sudo -u builder makepkg --cleanbuild --force --noconfirm
mapfile -t quarto_packages < <(sudo -u builder makepkg --packagelist)
[[ ${#quarto_packages[@]} = 1 && -f ${quarto_packages[0]} ]]
pacman -U --noconfirm "${quarto_packages[0]}"
quarto --version > /evidence/quarto-version.txt
cd /work/repo
sudo -u builder makepkg --verifysource > /evidence/verifysource.log 2>&1
# Контроль повреждённого опубликованного исходника; после него вернуть оригинал.
sudo -u builder cp quarto-course-perf-2.0.0.tar.gz /tmp/source-original.tar.gz
printf '\ncorrupt\n' >> quarto-course-perf-2.0.0.tar.gz
if sudo -u builder makepkg --verifysource > /evidence/corrupt-source.log 2>&1; then exit 1; fi
grep -qi 'FAILED' /evidence/corrupt-source.log
sudo -u builder cp /tmp/source-original.tar.gz quarto-course-perf-2.0.0.tar.gz
sudo -u builder makepkg --cleanbuild --force --noconfirm > /evidence/makepkg.log 2>&1
sudo -u builder makepkg --packagelist > /evidence/packagelist.txt
package=$(while IFS= read -r p; do [[ -f $p && $(basename "$p") = quarto-course-perf-2.0.0-1-any.pkg.tar.* ]] && printf '%s\n' "$p"; done < /evidence/packagelist.txt)
[[ -n $package && $(wc -l <<< "$package") = 1 ]]
pacman -Qlp "$package" > /evidence/package-files.txt
namcap PKGBUILD "$package" > /evidence/namcap.log 2>&1 || true
pacman -U --noconfirm "$package"
cp "$package" /evidence/
sha256sum PKGBUILD .SRCINFO *.tar.gz *.tgz "$package" > /evidence/SHA256SUMS
pacman -Q quarto-course-perf quarto-ci deno > /evidence/installed-packages.txt
chown -R builder:builder /work /evidence
ARCH
# Сохранить подготовленные npm и checker, затем отключить сеть и запись системного дерева.
local_image="localhost/perf-arch-checked:$$"
"${podman[@]}" commit "$name" "$local_image" > "$evidence/prepared-image.txt"
"${podman[@]}" run --rm --userns keep-id:uid=1000,gid=1000 --user builder --network none --read-only \
  --tmpfs /tmp:rw,exec,size=2g --tmpfs /home/builder:rw,exec,size=1g \
  -v "$evidence:/evidence:rw" -e EVIDENCE=/evidence/smoke \
  -e PERF_SOURCE_ROOT=/work/repo/src/quarto-course-perf-f79d4f7e4cf2d235ae7d35a7b6a1b7a6be42486f \
  "$local_image" bash /work/repo/tests/installed-smoke.sh > "$evidence/smoke.log" 2>&1
"${podman[@]}" image inspect "$local_image" > "$evidence/prepared-image-inspect.json"
echo 'Сборка, pacman и изолированная проверка: PASS'
