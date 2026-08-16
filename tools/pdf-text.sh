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
import collections, os, re, sys, unicodedata
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

# Колонтитулы у книг устроены по-разному, одного правила не хватает.
# Правило выше — про номер страницы в шапке. Ещё два опираются не на вид
# строки, а на её повторяемость, и потому работают на незнакомой вёрстке.
def norm(line):
    return re.sub(r"\d+", "#", " ".join(line.split()))

def edges(text):
    ls = [l for l in text.split("\n") if l.strip()]
    return (ls[0], ls[-1]) if ls else (None, None)

pages = [doc[p].get_text("text", sort=True) for p in range(doc.page_count)]
firsts, lasts = zip(*(edges(t) for t in pages)) if pages else ((), ())

# Подвал одинаков на всей книге, меняется только номер страницы — ловим по
# частоте. Порог с запасом: у вклеек и разворотов подвала может не быть.
counts = collections.Counter(norm(l) for l in lasts if l)
FOOTERS = {form for form, n in counts.items() if n >= doc.page_count * 0.4}

# Дефис в конце строки бывает двух родов: перенос по слогам («тести-\nрование»)
# и настоящий дефис составного слова, которому не повезло с шириной колонки
# («веб-\nсервисы»). Склеивать их надо по-разному, а по виду они одинаковы.
# Различаем по самой книге: собираем пары, встреченные с дефисом посреди
# строки, — там ширина колонки ни при чём, значит дефис настоящий.
HYPHENATED = {(m.group(1).lower(), m.group(2).lower())
              for t in pages for m in re.finditer(r"(\w+)-(\w+)", t)}

# Шапка — название текущего раздела: от раздела к разделу меняется, но на
# соседних страницах повторяется. Отсюда правило: первая строка, совпадающая
# с первой строкой соседней страницы, — колонтитул, а не текст книги.
def running_head(i):
    if not firsts[i]:
        return False
    here = norm(firsts[i])
    return any(0 <= j < len(firsts) and firsts[j] and norm(firsts[j]) == here
               for j in (i - 1, i + 1))

def strip_furniture(text, i):
    text = strip_header(text, i + 1)
    lines = text.split("\n")
    top = next((k for k, l in enumerate(lines) if l.strip()), None)
    if top is not None and running_head(i):
        del lines[top]
    bottom = next((k for k in range(len(lines) - 1, -1, -1) if lines[k].strip()), None)
    if bottom is not None and norm(lines[bottom]) in FOOTERS:
        del lines[bottom]
    return "\n".join(lines)

def clean(text):
    text = unicodedata.normalize("NFKC", text)
    # Вёрстка переносит слова мягким дефисом U+00AD. Его надо убрать вместе
    # с концом строки и до того, как строки склеятся, иначе в тексте
    # останется «лю<U+00AD> бого» вместо «любого» — таких мест тут пара тысяч.
    text = re.sub(r"­\s*", "", text)
    # Слово, разорванное концом строки. Отступ в начале следующей строки
    # пропускаем: у Куликова с пробела начинается каждая строка, и без этого
    # разорванными остаются тысячи слов. Дефис сохраняем, только если книга
    # где-то пишет эту пару через дефис и посреди строки.
    def rejoin(m):
        left, right = m.group(1), m.group(2)
        dash = "-" if (left.lower(), right.lower()) in HYPHENATED else ""
        return f"{left}{dash}{right}"
    text = re.sub(r"(\w+)-\n[ \t]*(\w+)", rejoin, text)
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

# Закладок в PDF может не быть вовсе — так у Куликова, где оглавление
# набрано обычным текстом. Тогда границы берём из marks.txt рядом с книгой.
marks_path = os.path.join("draft", slug, "marks.txt")
if not marks:
    if not os.path.exists(marks_path):
        os.makedirs(os.path.dirname(marks_path), exist_ok=True)
        with open(marks_path, "w", encoding="utf-8") as f:
            f.write(
                "# Границы разделов: по строке на раздел, «<страница> <заголовок>».\n"
                "# Нужен, когда в PDF нет закладок.\n"
                "#\n"
                "# Страница — номер В ФАЙЛЕ, а не напечатанный в книге: из-за обложки\n"
                "# и титульных листов они обычно расходятся. Сверьте по любой странице,\n"
                "# прежде чем переносить номера из оглавления.\n")
        sys.exit(f"в PDF нет закладок — заполните {marks_path} и запустите снова")
    for line in open(marks_path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        page, _, title = line.partition(" ")
        if not page.isdigit() or not title.strip():
            sys.exit(f"{marks_path}: не разобрал строку «{line}»")
        marks.append((title.strip(), int(page)))
    marks.sort(key=lambda m: m[1])

if not marks:
    sys.exit(f"{marks_path} пуст — заполнить границы разделов нечем")

total = 0
index = []
for i, (title, page) in enumerate(marks):
    end = marks[i + 1][1] - 1 if i + 1 < len(marks) else doc.page_count
    start = page
    parts = []
    for p in range(start - 1, min(end, doc.page_count)):
        parts.append(strip_furniture(pages[p], p))
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
