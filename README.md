# quarto-course-perf для Arch Linux

Готовая упаковка [Performance 2.0.0](https://github.com/Afonenko-Course-Tools/quarto-course-performance/releases/tag/v2.0.0).
Репозиторий содержит конкретный `PKGBUILD` из опубликованного выпуска, `.SRCINFO`
и приёмку установленной команды. AUR и собственный сервер пакетов не требуются.

## Установка

Заранее установите `base-devel`, `git`, `deno`, `time`, `util-linux` и настоящий
pacman-пакет Quarto, предоставляющий зависимость `quarto`. На чистой Arch Linux
его нужно подготовить отдельно: `makepkg` не устанавливает зависимости из AUR.
Наличие команды `quarto` в `PATH` само по себе не заменяет pacman-провайдер.
Проверенная среда использует Quarto 1.11.6 и Deno 2.9.8; целевые расширения курса
требуют Quarto >=1.11.5. Рецепт `ci/quarto/PKGBUILD` служит только проверочной среде.

Сборку запускайте обычным пользователем:

```sh
git clone https://github.com/Afonenko-Course-Tools/quarto-course-perf-arch.git
cd quarto-course-perf-arch
makepkg -si
quarto-course-perf --version
quarto-course-perf --help
```

`makepkg` скачает три закреплённых архива и проверит их SHA-256. Ручная подготовка
npm, генерация рецепта и developer checkout Performance не нужны.

В каталоге проекта Quarto:

```sh
quarto-course-perf render --perf-mode summary index.qmd
```

[Форматы и команды версии 2.0.0](https://github.com/Afonenko-Course-Tools/quarto-course-performance/blob/v2.0.0/docs/general-use-formats.md),
[диагностика](https://github.com/Afonenko-Course-Tools/quarto-course-performance/blob/v2.0.0/docs/diagnostics.md).

## Обновление и удаление

```sh
git pull --ff-only
makepkg -si
```

Удаление:

```sh
sudo pacman -Rns quarto-course-perf
```

Документация в `/usr/share/doc/quarto-course-perf` поставляется неизменённой из
исторического архива 2.0.0 и может описывать прежний маршрут установки.
Актуальные инструкции установки и обновления находятся в этом README.

## Проверка и сопровождение

Полный цикл в disposable Arch через rootless Podman:

```sh
bash ci/check-arch.sh /абсолютный/внешний/новый-каталог-результатов
```

Каждый запуск требует новый, ещё не существующий каталог результатов. При отказе
предыдущие журналы и заключения сохраняются отдельно. Скачанные опубликованные
архивы и образы хранятся в соседнем `quarto-course-perf-arch-cache`; другой
абсолютный путь к кэшу можно задать через `PERF_ARCH_CACHE`. Суммы архивов
проверяются при каждом запуске, developer-кэш Performance не используется.

Цикл использует закреплённый digest Arch, настоящий Quarto из официального архива,
собирает пакет обычным пользователем, устанавливает его через pacman и проверяет
`/usr/bin/quarto-course-perf`. Последний этап выполняется без сети, с read-only
системным деревом, чужим `deno.json` и пустыми кэшами. Проверяются summary-рендер,
содержимое HTML, `dataValid`, TS trace из checker того же исходного архива и
неизменность установленного дерева. Отрицательные контроли проверяют повреждение
архива, устаревшую `.SRCINFO` и отсутствие настоящего Quarto.

Для следующего выпуска сопровождающий сверяет upstream Release, source receipt,
commit и SHA-256 архивов, переносит конкретный опубликованный рецепт и выполняет:

```sh
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "Обновить упаковку конкретного опубликованного выпуска"
bash ci/check-arch.sh /абсолютный/новый/каталог-результатов
```

Проверка требует чистое зафиксированное дерево. После локальной приёмки требуется
hosted CI на том же commit и tag упаковки.
`pkgver` следует версии приложения; при изменении упаковки той же версии
повышается `pkgrel`. Архивы, внутренний шаблон, оболочка и runtime остаются у
Performance; старые Releases не переписываются.

В исходниках Performance 2.0.0 лицензия не объявлена; `license=()` в опубликованном
рецепте сохраняется. Это требует решения правообладателя. `namcap` сохраняется
целиком в результатах проверки: сообщения об отсутствующей лицензии и
эвристические замечания по зависимостям не означают чистую проверку.
