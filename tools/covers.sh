#!/usr/bin/env bash
# Готовит обложки книг для полки — books/<slug>/cover.jpg.
#
# Обложка нужна, чтобы книга узнавалась на полке раньше, чем прочитано
# название. Файлы кладутся в репозиторий: страница не должна ходить за
# картинками на сторонние домены, как не ходит за шрифтами.
#
#   bash tools/covers.sh
#
# ОТКУДА БЕРЁТСЯ КАРТИНКА, по убыванию приоритета:
#
#   1. sources/covers/<slug>.(jpg|jpeg|png|webp) — положенная руками.
#      Это главный путь: у издательств оригиналы крупнее, чем то, что
#      отдаёт витрина магазина. Скрипт всегда предпочитает такой файл.
#   2. Запасной источник, прописанный ниже для каждой книги: первая
#      страница PDF или карточка товара на сайте издательства. Нужен,
#      чтобы обложки восстанавливались, если sources/ потеряется —
#      папка целиком в .gitignore.
#
# В репозиторий попадает только результат — books/<slug>/cover.jpg.
# Если исходник мельче нужного, скрипт скажет об этом, но соберёт: лучше
# мыльная обложка, чем пустое место.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="$HOME/.venvs/icontools"
if [ ! -x "$VENV/bin/python" ]; then
  echo "→ ставлю Pillow и PyMuPDF в $VENV" >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check pillow pymupdf
fi

"$VENV/bin/python" - <<'PY'
import io, pathlib, subprocess
import pymupdf
from PIL import Image, ImageFilter

# 2:3 — пропорция книжной обложки. Размер с запасом на экраны с удвоенной
# плотностью: на полке картинка показывается примерно вдвое меньше.
W, H = 800, 1200
QUALITY = 88

MANUAL = pathlib.Path("sources/covers")

def manual(slug):
    """Обложка, положенная руками, — она главнее любой автоматики."""
    for ext in ("jpg", "jpeg", "png", "webp"):
        p = MANUAL / f"{slug}.{ext}"
        if p.exists():
            return p
    return None

def trim_margins(im):
    """Отрезает однотонные поля по краям. У части книг «обложка» — это
    титульный лист: рисунок занимает лишь часть страницы, а остальное белое
    поле да строчка копирайта внизу. На полке такая карточка выглядит
    документом, а не книгой."""
    px, w, h = im.load(), im.width, im.height
    step = max(1, w // 200)
    def filled(y):
        return sum(1 for x in range(0, w, step) if sum(px[x, y]) < 720) > (w / step) * 0.12
    rows, best, cur = [filled(y) for y in range(h)], (0, 0), (0, 0)
    for y, on in enumerate(rows + [False]):
        if on:
            cur = (cur[0] or y, y)
        else:
            if cur[1] - cur[0] > best[1] - best[0]:
                best = cur
            cur = (0, 0)
    top, bot = best
    if bot - top < h * 0.2:          # сплошной рисунок — резать нечего
        return im
    cols = [x for x in range(w) if any(sum(px[x, y]) < 720 for y in range(top, bot, 4))]
    return im.crop((min(cols), top, max(cols) + 1, bot + 1))

def save(im, slug, origin):
    im = im.convert("RGB")
    if im.width < W or im.height < H:
        print(f"  ⚠ {slug}: исходник {im.width}×{im.height} мельче {W}×{H} — "
              f"будет мыло. Положите крупнее в {MANUAL}/{slug}.jpg")
    ratio, target = im.width / im.height, W / H
    if abs(ratio - target) / target < 0.15:
        # Настоящая обложка: пропорция почти совпадает, обрезаем по центру
        scale = max(W / im.width, H / im.height)
        im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
        left, top = (im.width - W) // 2, (im.height - H) // 2
        im = im.crop((left, top, left + W, top + H))
    else:
        # Рисунок другой пропорции — вписываем целиком и достраиваем поля.
        # Обрезать нельзя: срежет название. Поля не заливаем одним цветом:
        # у рисунка вдоль края идёт растяжка, и ровная заливка дала бы
        # заметный шов. Вместо этого растягиваем сами краевые строки и
        # столбцы — цвет вдоль шва совпадает точь-в-точь, и продолжение
        # рисунка не читается как приклеенное.
        scale = min(W / im.width, H / im.height)
        art = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
        x0, y0 = (W - art.width) // 2, (H - art.height) // 2
        # Растягиваем сам рисунок на весь кадр и сильно размываем: получается
        # поле из его же красок, без единого чужого цвета. Просто растянуть
        # краевую строку нельзя — в ней проходит граница диагонального клина,
        # и достройка выходит в вертикальную полоску.
        back = art.resize((W, H), Image.LANCZOS).filter(
            ImageFilter.GaussianBlur(max(W, H) // 12))
        im = back
        im.paste(art, (x0, y0))
    out = pathlib.Path("books") / slug / "cover.jpg"
    im.save(out, quality=QUALITY, optimize=True, progressive=True)
    print(f"  {out}  {W}×{H}  {out.stat().st_size // 1024} КБ  ← {origin}")

def build(slug, fallback, crop_to_art=False):
    """crop_to_art — свойство конкретной книги, а не догадка по картинке.
    У Куликова «обложка» это титульный лист: рисунок занимает верх страницы,
    ниже белое поле и строчка копирайта. У остальных настоящие обложки, и
    резать их нельзя ни при каких условиях: у O’Reilly фон белый, и любая
    автоматика «найди заполненную область» отрежет книге голову."""
    if (m := manual(slug)):
        im, origin = Image.open(m).convert("RGB"), f"руками, {m.name}"
    else:
        im, origin = fallback()
    if crop_to_art:
        before = im.size
        im = trim_margins(im)
        print(f"    поля отрезаны: {before[0]}×{before[1]} → {im.size[0]}×{im.size[1]}")
    save(im, slug, origin)

def pdf_page(path):
    def go():
        doc = pymupdf.open(path)
        xref = doc[0].get_images(full=True)[0][0]
        im = Image.open(io.BytesIO(doc.extract_image(xref)["image"])).convert("RGB")
        return im, f"первая страница {pathlib.Path(path).name[:28]}"
    return go

def url(u):
    def go():
        raw = subprocess.run(["curl", "-sSL", "--max-time", "30", u],
                             capture_output=True, check=True).stdout
        return Image.open(io.BytesIO(raw)).convert("RGB"), "сайт издательства"
    return go

# «Фулстек-тестирование»: настоящая обложка O’Reilly, резать нечего.
build("fullstack-testing", pdf_page("sources/Фуллстек тестирование.pdf"))

# Куликов: и в PDF, и в присланном файле это титульный лист — только у него
# отрезаем поля и достраиваем кадр до книжной пропорции.
build("testirovanie-po",
      pdf_page("sources/Software Testing - Base Course (Svyatoslav Kulikov) - 3rd edition - RU-1.pdf"),
      crop_to_art=True)

# «Жемчужины»: PDF у нас нет, обложку отдаёт сайт издательства «Питер» —
# тот самый, на который ведёт ссылка в подвале конспекта. Берём из og:image
# карточки товара: по адресам вида /upload/sg/<isbn>/C/N.jpg лежит не
# обложка, а развороты книги, и первый из них — оглавление.
build("zhemchuzhiny-razrabotki",
      url("https://cdn.insales-shop.ru/images/products/1/35/807018531/44611986.jpg"))
PY
