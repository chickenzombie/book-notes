#!/usr/bin/env bash
# Пересобирает знак полки assets/icon.svg — буквы «BN» в кривых.
#
# Нужен, потому что шрифтом иконку не набрать: SVG-фавикон браузер рисует
# без доступа к CSS и веб-шрифтам. Буквы вытаскиваются из того же файла,
# которым набран заголовок полки, — assets/fonts/unbounded-800-latin.woff2.
#
#   bash tools/bn-icon.sh > assets/icon.svg
#
# Запускать только если поменялся шрифт или сам знак. После — обязательно
# `bash tools/icons.sh` (пересоберёт растр) и поднять ?v=N в <link rel="icon">
# на всех страницах, иначе у заходивших останется старый значок.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="$HOME/.venvs/icontools"
if [ ! -x "$VENV/bin/python" ]; then
  echo "→ ставлю fontTools и skia-pathops в $VENV" >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check "fonttools[woff]" skia-pathops
fi

"$VENV/bin/python" - <<'PY'
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.ttLib.removeOverlaps import removeOverlaps
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.misc.transform import Transform

FONT = "assets/fonts/unbounded-800-latin.woff2"
TEXT = "BN"
BOX = 32          # viewBox иконки
FILL = 0.76       # какую долю ширины плашки занимает знак
TRACKING = -0.02  # letter-spacing заголовка на полке
WEIGHT = 800      # его же вес
BACKDROP = "#EDEFF3"
ANGLE = 100       # наклон перламутрового градиента из assets/shelf.css
STOPS = [(0, "#2A3550"), (.18, "#6E8FE0"), (.34, "#47B7A4"), (.50, "#D9A03C"),
         (.66, "#B76FB0"), (.82, "#8878D2"), (1, "#2A3550")]

font = TTFont(FONT)
# Файл вариативный: ось wght 200–900, по умолчанию 400. На странице вес
# задаёт @font-face, а здесь ось надо закрепить, иначе выйдет Regular.
font = instancer.instantiateVariableFont(font, {"wght": WEIGHT})
# В «B» обе внутренние дырки заданы одним самопересекающимся контуром:
# движок шрифтов такое рисует верно, а SVG по правилу nonzero заливает
# верхнюю. Перекладываем контуры начисто — из двух получается три.
removeOverlaps(font)

upm = font["head"].unitsPerEm
cmap, glyphs = font.getBestCmap(), font.getGlyphSet()
paths, bounds, x = [], BoundsPen(glyphs), 0.0
for i, ch in enumerate(TEXT):
    g = glyphs[cmap[ord(ch)]]
    shift = Transform().translate(x, 0)
    pen = SVGPathPen(glyphs, ntos=lambda v: f"{v:.0f}")  # доли пикселя ни к чему
    g.draw(TransformPen(pen, shift))
    g.draw(TransformPen(bounds, shift))
    paths.append(pen.getCommands())
    x += g.width + (TRACKING * upm if i < len(TEXT) - 1 else 0)

x0, y0, x1, y1 = bounds.bounds
w, h = x1 - x0, y1 - y0
k = BOX * FILL / max(w, h)
dx = (BOX - w * k) / 2 - x0 * k
dy = (BOX - h * k) / 2 + y1 * k       # y в SVG вниз, в шрифте вверх
tf = f"translate({dx:.2f} {dy:.2f}) scale({k:.5f} {-k:.5f})"

# Направление градиента: у CSS 0deg смотрит вверх и растёт по часовой,
# то есть вектор (sin, -cos), а в экранных координатах y смотрит вниз.
import math
ux, uy = math.sin(math.radians(ANGLE)), -math.cos(math.radians(ANGLE))
half = (abs(w * k * ux) + abs(h * k * uy)) / 2
cx = cy = BOX / 2

print(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {BOX} {BOX}" role="img" aria-label="Book Notes">')
print(f'  <!-- Собрано `bash tools/bn-icon.sh` из {FONT}, ось wght={WEIGHT}.\n'
      f'       Правьте скрипт, а не этот файл. Градиент лежит на прямоугольнике\n'
      f'       и подрезается буквами — иначе радуга повторялась бы в каждой. -->')
print('  <defs>')
print(f'    <linearGradient id="bn" gradientUnits="userSpaceOnUse"\n'
      f'                    x1="{cx - ux * half:.2f}" y1="{cy - uy * half:.2f}"'
      f' x2="{cx + ux * half:.2f}" y2="{cy + uy * half:.2f}">')
for off, color in STOPS:
    print(f'      <stop offset="{off}" stop-color="{color}"/>')
print('    </linearGradient>')
print('    <clipPath id="bn-letters">')
for p in paths:
    print(f'      <path transform="{tf}" d="{p}"/>')
print('    </clipPath>')
print('  </defs>')
# Рамка во всю картинку с rx=7 — по ней tools/icons.sh находит фон для
# apple-touch-icon, менять её форму нельзя.
print(f'  <rect width="{BOX}" height="{BOX}" rx="7" fill="{BACKDROP}"/>')
print(f'  <rect width="{BOX}" height="{BOX}" fill="url(#bn)" clip-path="url(#bn-letters)"/>')
print('</svg>')
PY
