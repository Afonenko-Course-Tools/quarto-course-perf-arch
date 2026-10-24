#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) != 0 ]] || { echo 'Проверка требует обычного пользователя' >&2; exit 1; }
: "${PERF_SOURCE_ROOT:?Требуется подготовленный source root того же Release}"
: "${EVIDENCE:?Требуется каталог результатов}"
test -x /usr/bin/quarto-course-perf
mkdir -p "$EVIDENCE"
# Отдельная среда обязана ограничить сеть и запись в /usr снаружи.
if touch /usr/lib/.perf-write-probe 2>/dev/null; then
  rm /usr/lib/.perf-write-probe
  echo 'Запись в /usr не запрещена' >&2; exit 1
fi
[[ $(cat /sys/class/net/*/operstate | sort -u) != *up* ]] || { echo 'Сеть доступна' >&2; exit 1; }
tree_hash() { (cd /usr/lib/quarto-course-perf; find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum; }
before=$(tree_hash)
fixture=$(mktemp -d '/tmp/perf course # % XXXXXXXX')
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/empty deno cache"
export DENO_DIR="$fixture/empty deno cache" XDG_CACHE_HOME="$fixture/xdg cache"
cd "$fixture"
printf '%s\n' '{"imports":{"node:path":"./forbidden.ts"},"compilerOptions":{"types":["./missing.ts"]}}' > deno.json
printf 'project:\n  type: default\nformat: html\n' > _quarto.yml
printf '%s\n' '---' 'title: Установленный пакет' '---' '' 'Installed public wrapper marker.' > index.qmd
/usr/bin/quarto-course-perf --version | tee "$EVIDENCE/version.log"
grep -qx '2.0.0' "$EVIDENCE/version.log"
/usr/bin/quarto-course-perf --help > "$EVIDENCE/help.log"
grep -q quarto-course-perf "$EVIDENCE/help.log"
/usr/bin/quarto-course-perf render --perf-mode summary --perf-output "$EVIDENCE/summary" index.qmd > "$EVIDENCE/render.log" 2>&1
grep -q 'Installed public wrapper marker' index.html
find "$EVIDENCE/summary" -name run.json -print -quit | grep -q .
deno eval --no-config --no-lock 'for (const e of Deno.readDirSync(Deno.args[0])) { if (!e.isDirectory) continue; const p=Deno.args[0]+"/"+e.name+"/run.json"; const r=JSON.parse(Deno.readTextFileSync(p)); if(r.outcome.code!==0 || r.dataValid!==true) throw Error(JSON.stringify(r)); console.log(JSON.stringify(r)); }' "$EVIDENCE/summary" > "$EVIDENCE/summary-check.log"
deno run --config "$PERF_SOURCE_ROOT/deno.json" --lock "$PERF_SOURCE_ROOT/deno.lock" --frozen --node-modules-dir=manual --cached-only -A "$PERF_SOURCE_ROOT/tools/check-installed.ts" --root /usr/lib/quarto-course-perf > "$EVIDENCE/installed-checker.log" 2>&1
grep -q 'installed TS trace PASS' "$EVIDENCE/installed-checker.log"
grep -q '"status":"PASS"' "$EVIDENCE/installed-checker.log"
after=$(tree_hash)
[[ $before == "$after" ]]
printf '{"status":"PASS","before":"%s","after":"%s"}\n' "${before%% *}" "${after%% *}" > "$EVIDENCE/installed-tree.json"
echo 'Публичная установленная команда и installed TS trace: PASS'
