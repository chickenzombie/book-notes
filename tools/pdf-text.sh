#!/usr/bin/env bash
# Разбирает PDF книги на текст по главам — в draft/<slug>/text/, вне репозитория.
#
# Нужен, потому что книгу нельзя просто отдать модели целиком: 400 страниц
# не помещаются ни в один контекст. Конспект собирается по главам, и резать
# их удобнее по встроенному оглавлению, чем вслепую по номерам страниц.
#
#   bash tools/pdf-text.sh "sources/Фуллстек тестирование.pdf" [slug]
#
# Сами книги лежат в sources/ — эта папка целиком в .gitignore, чтобы файл
# на 14 МБ не уехал в репозиторий вместе с конспектом.
#
# Slug по умолчанию берётся из имени файла. Скрипт печатает размеры глав —
# по ним видно, какие главы придётся делить на части.
#
# Раскладка на книгу:
#   draft/<slug>/text/   извлечённый текст глав, его пересоздаёт этот скрипт
#   draft/<slug>/notes/  выжимки по главам, их пишут руками и не восстановить
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?укажите путь к PDF}"
SLUG="${2:-}"

# PyMuPDF ставится в отдельный venv: в системный Python 3.12 pip не пускает
# (PEP 668), а poppler-utils требует root, которого может не быть.
VENV="$HOME/.venvs/pdftools"
if [ ! -x "$VENV/bin/python" ]; then
  echo "→ ставлю PyMuPDF в $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check pymupdf
fi

SRC="$SRC" SLUG="$SLUG" "$VENV/bin/python" - <<'PY'
import os, re, sys, unicodedata
import pymupdf

src = os.environ["SRC"]
doc = pymupdf.open(src)

slug = os.environ["SLUG"] or os.path.splitext(os.path.basename(src))[0]
slug = re.sub(r"[^\w]+", "-", slug.lower(), flags=re.U).strip("-")

# Извлечённый текст — в text/, отдельно от выжимок в notes/. Книг будет
# больше одной, и вперемешку два десятка глав и десяток конспектов в одной
# папке уже не разобрать. notes/ заводим сразу, чтобы её не забыли создать.
out = os.path.join("draft", slug, "text")
os.makedirs(out, exist_ok=True)
os.makedirs(os.path.join("draft", slug, "notes"), exist_ok=True)

# Колонтитул повторяется на каждой странице и в конспекте только мешает.
# Выглядит он как «Название раздела<em-space><em-space>103» в самом начале
# страницы — по номеру страницы его и опознаём.
def strip_header(text, pageno):
    head, sep, rest = text.partition("\n")
    if sep and re.search(r"[ - \s]+%d\s*$" % pageno, head):
        return rest
    if sep and re.match(r"^\s*%d[ - \s]" % pageno, head):
        return rest
    return text

def clean(text):
    text = unicodedata.normalize("NFKC", text)
    # Вёрстка переносит слова мягким дефисом U+00AD. Его надо убрать вместе
    # с концом строки и до того, как строки склеятся, иначе в тексте
    # останется «лю<U+00AD> бого» вместо «любого» — таких мест тут пара тысяч.
    text = re.sub(r"­\s*", "", text)
    # Обычный перенос по слогам: «тести-\nрование» → «тестирование»
    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)
    # Одиночный перенос внутри абзаца — это ширина колонки, а не конец мысли
    text = re.sub(r"(?<![.!?:;»\n])\n(?![\n\s•\t])", " ", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    # Ссылки на источники книга ломает по строкам так же, как обычные слова
    text = re.sub(r"(https?://)\s+", r"\1", text)
    return text.strip()

# Границы глав — из оглавления: верхний уровень, где заголовок не служебный.
toc = doc.get_toc()
marks = []
for lvl, title, page in toc:
    if lvl > 2:
        continue
    title = " ".join(title.split())
    if re.fullmatch(r"Глава\s*\d+", title):
        continue  # номер главы и её название идут отдельными записями
    if marks and marks[-1][1] == page:
        continue
    marks.append((title, page))
marks.sort(key=lambda m: m[1])

if not marks:
    sys.exit("в PDF нет оглавления — режьте по страницам вручную")

total = 0
index = []
for i, (title, page) in enumerate(marks):
    end = marks[i + 1][1] - 1 if i + 1 < len(marks) else doc.page_count
    start = page
    parts = []
    for p in range(start - 1, min(end, doc.page_count)):
        t = doc[p].get_text("text", sort=True)
        parts.append(strip_header(t, p + 1))
    body = clean("\n".join(parts))

    name = re.sub(r"[^\w]+", "-", title.lower(), flags=re.U).strip("-")[:48]
    fn = f"{i:02d}-{name}.txt"
    with open(os.path.join(out, fn), "w", encoding="utf-8") as f:
        f.write(f"# {title}\n# стр. {start}–{end}\n\n{body}\n")

    total += len(body)
    index.append((fn, title, start, end, len(body)))
    print(f"  {len(body):>7} симв.  стр.{start:>4}–{end:<4} {title[:52]}")

with open(os.path.join(out, "00-index.md"), "w", encoding="utf-8") as f:
    f.write(f"# {os.path.basename(src)}\n\n{doc.page_count} страниц, {len(index)} разделов\n\n")
    for fn, title, start, end, n in index:
        f.write(f"- [{title}]({fn}) — стр. {start}–{end}, {n} симв.\n")

# Грубая прикидка: на кириллице токен выходит примерно в 2.5 символа
print(f"\nвсего {total} симв. (~{total // 1000}k), примерно {total // 2500}k токенов")
print(f"разложено в {out}/")
PY
