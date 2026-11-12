# Инструкции для Codex

Репозиторий хранит штатный Arch-рецепт quarto-course-perf. Исходники, оболочка
и среда исполнения принадлежат quarto-course-performance; не копируйте их сюда.
Источник — обычный GitHub tag archive, integrity — стандартный `sha256sums`
в `PKGBUILD`; `.SRCINFO` создаётся `makepkg --printsrcinfo`. Не добавляйте
собственные package/source resolvers, lock manifests и повторный commit selector.
Системный пакет `typescript` предоставляет Compiler API и CLI без точного пина.
Сохраняйте makepkg dependency/checksum checks и реальную offline installed
приёмку; не изменяйте общие стенды. Приёмка: `bash ci/check-arch.sh /абсолютный/каталог`.

Новые README, документация и описания PR пишутся по-русски по
[общему языковому правилу](https://github.com/Afonenko-Course-Tools/quarto-course/blob/main/docs/russian-language-policy.md).
Команды, API, пути, имена пакетов и URL сохраняются буквально.
