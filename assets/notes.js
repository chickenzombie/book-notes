/* ДВИЖОК КОНСПЕКТА
   ----------------
   Скрипт ничего не рисует. Пункты лежат в HTML готовой разметкой — страница
   читается с выключенным JS, находится поиском и сохраняется целиком; здесь
   только надстройка: фильтр, поиск, полоса прочитанного и кнопка «наверх».

   Что нужно от разметки:
     .sect[id][data-chip]   раздел; id — ключ фильтра, data-chip — подпись кнопки
     --hue на .sect         цвет раздела, из него берётся точка на кнопке
     .card                  пункт; для поиска берутся его h3 и p
     #q #chips              поле поиска и место под кнопки разделов
     #status #empty #reset  строка счётчика и состояние «ничего не нашлось»
     #progress #totop       фурнитура; необязательны, без них скрипт не падает

   Панель и фурнитуру показывает CSS по классу js на <html> — его ставит
   однострочник в <head> страницы. */
(() => {
  const $ = (id) => document.getElementById(id);
  const sects = [...document.querySelectorAll(".sect")];
  if (!sects.length) return;

  const q = $("q"), chipsBox = $("chips"), status = $("status"),
        empty = $("empty"), reset = $("reset"),
        bar = $("progress"), toTop = $("totop");

  /* «ё» и «е» в русском тексте пишут вперемешку — приводим к одной букве,
     иначе поиск по «еще» не найдёт «ещё». */
  const norm = (s) => s.toLowerCase().replace(/ё/g, "е").replace(/\s+/g, " ").trim();

  const cards = sects.flatMap((s) =>
    [...s.querySelectorAll(".card")].map((el) => ({
      el,
      sect: s,
      /* Индексируем только текст пункта: номер в маркере иначе даёт
         ложные совпадения на любой цифре в запросе. */
      text: norm([...el.querySelectorAll("h3,p")].map((n) => n.textContent).join(" ")),
    }))
  );

  let active = "all";

  /* ФИЛЬТР */
  function apply() {
    const term = norm(q.value);
    let shown = 0;

    for (const s of sects) {
      const catOk = active === "all" || active === s.id;
      let n = 0;
      for (const c of cards) {
        if (c.sect !== s) continue;
        const ok = catOk && (!term || c.text.includes(term));
        c.el.hidden = !ok;
        if (ok) n++;
      }
      s.hidden = n === 0;
      /* При поиске введение к главе только мешает: человек ищет пункт,
         а не рассказ о главе. */
      const intro = s.querySelector(".intro");
      if (intro) intro.hidden = !!term;
      shown += n;
    }

    for (const b of chipsBox.children) b.setAttribute("aria-pressed", b.dataset.cat === active);
    if (empty) empty.hidden = shown > 0;
    if (status) {
      status.textContent = shown === cards.length
        ? `Показаны все ${cards.length}`
        : `Найдено ${shown} из ${cards.length}`;
    }
    onScroll(); // высота страницы изменилась — полоса и кнопка считаются от неё
  }

  /* КНОПКИ РАЗДЕЛОВ */
  function addChip(cat, label, hue) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "chip";
    b.dataset.cat = cat;
    b.setAttribute("aria-pressed", cat === active);
    b.innerHTML = hue ? `<span class="dot" style="color:${hue}"></span>` : "";
    b.append(label);
    b.addEventListener("click", () => { active = cat; apply(); });
    chipsBox.append(b);
  }

  addChip("all", `Все ${cards.length}`, "");
  for (const s of sects) {
    addChip(s.id, s.dataset.chip || s.querySelector("h2")?.textContent || s.id,
            getComputedStyle(s).getPropertyValue("--hue").trim());
  }

  /* ФУРНИТУРА
     Полоса и кнопка считаются от прокручиваемой высоты, а она меняется
     при фильтрации, — поэтому onScroll зовётся и из apply. */
  function onScroll() {
    const scrollable = document.documentElement.scrollHeight - innerHeight;
    if (bar) bar.style.transform = `scaleX(${scrollable > 0 ? Math.min(scrollY / scrollable, 1) : 0})`;
    if (toTop) toTop.classList.toggle("on", scrollable > 240 && scrollY > scrollable / 2);
  }
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", onScroll);

  toTop?.addEventListener("click", () => {
    const reduce = matchMedia("(prefers-reduced-motion:reduce)").matches;
    scrollTo({ top: 0, behavior: reduce ? "auto" : "smooth" });
  });

  /* Ссылка из оглавления на раздел, спрятанный фильтром, не приводила никуда:
     браузеру нечего показывать, и он остаётся на месте. Открываем раздел
     и доводим до него сами. */
  function gotoHash() {
    const target = location.hash && document.querySelector(location.hash);
    if (!target || !sects.includes(target)) return;
    if (target.hidden || active !== "all") {
      active = "all";
      q.value = "";
      apply();
    }
    target.scrollIntoView?.();
  }
  addEventListener("hashchange", gotoHash);

  q.addEventListener("input", apply);
  reset?.addEventListener("click", () => { active = "all"; q.value = ""; apply(); q.focus(); });

  apply();
  gotoHash();
})();
