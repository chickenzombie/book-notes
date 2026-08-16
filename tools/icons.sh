#!/usr/bin/env bash
# Собирает растровые запасные варианты иконок из каждого icon.svg.
#
# Нужен, потому что SVG-фавикон понимают не везде: iOS для значка на
# домашнем экране требует PNG и любой прозрачности подставляет чёрный фон,
# а старые контексты просят .ico. Рисунок при этом один — SVG остаётся
# источником правды, растр из него пересобирается.
#
#   bash tools/icons.sh
#
# Запускать после правки любого icon.svg и при заведении новой книги.
set -euo pipefail
cd "$(dirname "$0")/.."

# Свой venv: cairosvg тянет системный libcairo, а в системный Python 3.12
# pip не пускает (PEP 668). MuPDF тут не годится — он молча теряет
# градиенты, и жемчужина «Жемчужин» выходит чёрным кругом.
VENV="$HOME/.venvs/icontools"
if [ ! -x "$VENV/bin/python" ]; then
  echo "→ ставлю cairosvg и Pillow в $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check cairosvg pillow
fi

"$VENV/bin/python" - <<'PY'
import io, pathlib, re
import cairosvg
from PIL import Image

# Подложка иконки — заливка рамки во всю картинку. Из неё берётся фон для
# apple-touch-icon: iOS сама скругляет значок, и прозрачные углы под её
# маской стали бы чёрными. Радиус в наших SVG (rx=7 при 32) совпадает с
# маской iOS почти точь-в-точь, так что скругление рисовать заново не надо.
BACKDROP = re.compile(r'<rect width="32" height="32" rx="7" fill="(#[0-9A-Fa-f]{6})"')

TOUCH = 180  # столько просит iOS для значка на домашнем экране
ICO = [(16, 16), (32, 32), (48, 48)]

def render(svg, size):
    png = cairosvg.svg2png(url=str(svg), output_width=size, output_height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")

icons = sorted(pathlib.Path(".").glob("assets/icon.svg")) + \
        sorted(pathlib.Path(".").glob("books/*/icon.svg"))
if not icons:
    raise SystemExit("не нашёл ни одного icon.svg")

for svg in icons:
    m = BACKDROP.search(svg.read_text(encoding="utf-8"))
    if not m:
        raise SystemExit(f"{svg}: не вижу рамку во всю картинку, "
                         "неоткуда взять фон для apple-touch-icon")
    flat = Image.new("RGB", (TOUCH, TOUCH), m.group(1))
    art = render(svg, TOUCH)
    flat.paste(art, mask=art.getchannel("A"))
    touch = svg.with_name("apple-touch-icon.png")
    flat.save(touch, optimize=True)
    print(f"  {touch}  {TOUCH}×{TOUCH}  фон {m.group(1)}")

# .ico один на весь сайт: это запасной вариант для тех, кто не умеет SVG,
# и различать в нём книги смысла нет — берём знак полки. Лежит в корне,
# куда за ним и ходят по привычке, но страницы ссылаются на него явно:
# у проекта на GitHub Pages свой корень браузеру недоступен.
shelf = render(pathlib.Path("assets/icon.svg"), max(ICO)[0])
shelf.save("favicon.ico", sizes=ICO)
print(f"  favicon.ico  {', '.join(f'{w}×{h}' for w, h in ICO)}")
PY
