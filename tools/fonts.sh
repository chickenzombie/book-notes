#!/usr/bin/env bash
# Забирает шрифты с Google Fonts в assets/fonts/ и пересобирает assets/fonts.css.
#
# Запускать только когда меняется набор семейств: скачанные файлы лежат в
# репозитории, и обычная работа над конспектами сети не требует.
#
#   bash tools/fonts.sh
#
# Новое семейство — допишите строку в FAMILIES: «параметр family для css2»
# и slug для имён файлов. Начертания перечисляйте по одному, переменные оси
# не нужны — так файлы меньше.
set -euo pipefail
cd "$(dirname "$0")/.."

# Имена файлов делаются из названия семейства: «Golos Text» → golos-text-400-latin.woff2,
# у курсива к весу добавляется i: playfair-display-600i-cyrillic.woff2.
#
# Начертание, которого нет в файлах, браузер подделает: наклонит прямое или
# утолщит обводкой. Выглядит это плохо, поэтому перечисляйте всё, что реально
# используете в стилях, — и наоборот, лишнее убирайте, это чистый вес страницы.
FAMILIES=(
  "Golos+Text:wght@400;500;600"
  "Unbounded:wght@600;800"
  "JetBrains+Mono:wght@400;600"
  "Playfair+Display:ital,wght@0,600;0,700;1,600"
)
# Латиница и кириллица. latin-ext добавляет 350 КБ ради диакритики,
# которая в русско-английском тексте не встречается.
SUBSETS="cyrillic latin"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p assets/fonts

for query in "${FAMILIES[@]}"; do
  echo "→ ${query%%:*}"
  curl -sS -m 30 --retry 5 --retry-all-errors -A "$UA" \
    "https://fonts.googleapis.com/css2?family=${query}&display=swap" >> "$tmp/gf.css"
done

SUBSETS="$SUBSETS" node - "$tmp" <<'JS'
const fs = require("fs"), tmp = process.argv[2];
const want = new Set(process.env.SUBSETS.split(" "));
// Google отдаёт «/* subset */» перед каждым @font-face — по этой паре и разбираем
const css = fs.readFileSync(tmp + "/gf.css", "utf8");
const faces = [];
const re = /\/\*\s*([\w-]+)\s*\*\/\s*@font-face\s*\{([^}]*)\}/g;
let m;
while ((m = re.exec(css))) {
  const [, sub, body] = m;
  if (!want.has(sub)) continue;
  const family = body.match(/font-family:\s*["']([^"']+)["']/)[1];
  const wght = body.match(/font-weight:\s*(\d+)/)[1];
  const style = (body.match(/font-style:\s*(\w+)/) || [, "normal"])[1];
  const src = body.match(/url\((https:[^)]+\.woff2)\)/)[1];
  const range = body.match(/unicode-range:\s*([^;]+);/)[1].trim();
  const slug = family.toLowerCase().replace(/\s+/g, "-");
  const file = `${slug}-${wght}${style === "italic" ? "i" : ""}-${sub}.woff2`;
  faces.push({ family, wght, style, sub, src, range, file });
}
fs.writeFileSync(tmp + "/dl.txt", faces.map((f) => f.src + " " + f.file).join("\n"));

let out =
`/* Шрифты лежат в репозитории: страница не ходит на сторонние домены и
   не зависит от их доступности. Файлы взяты с Google Fonts, нарезка по
   subset и unicode-range — их же: браузер качает только те куски, которые
   реально нужны тексту на странице.

   Лицензия на все семейства — SIL Open Font License 1.1; её текст и
   уведомления об авторских правах лежат в fonts/LICENSE.txt.

   Файл собран tools/fonts.sh — правьте скрипт, а не его. */\n`;
let cur = "";
for (const f of faces) {
  if (f.family !== cur) { out += `\n/* ${f.family} */\n`; cur = f.family; }
  out += `@font-face{font-family:"${f.family}";font-style:${f.style};font-weight:${f.wght};font-display:swap;\n` +
         `  src:url("fonts/${f.file}") format("woff2");\n  unicode-range:${f.range};}\n`;
}
fs.writeFileSync("assets/fonts.css", out);
console.log(`  ${faces.length} начертаний в assets/fonts.css`);
JS

# Качаем весь набор заново: файлов два десятка, а сверять версии дороже
while read -r url file; do
  curl -sS -m 30 --retry 5 --retry-all-errors -o "assets/fonts/$file" "$url"
done < "$tmp/dl.txt"

# Файлы от начертаний, выпавших из списка, оставлять незачем
cut -d' ' -f2 "$tmp/dl.txt" | sort > "$tmp/keep.txt"
for f in assets/fonts/*.woff2; do
  grep -qxF "$(basename "$f")" "$tmp/keep.txt" || { echo "  лишний: $(basename "$f")"; rm "$f"; }
done

echo "готово: $(ls assets/fonts | wc -l) файлов, $(du -sh assets/fonts | cut -f1)"
