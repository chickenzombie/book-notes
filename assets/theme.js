/* ПЕРЕКЛЮЧАТЕЛЬ ТЕМЫ
   -------------------
   Всю раскраску делает CSS через light-dark(): скрипту достаточно поставить
   на <html> атрибут data-theme, чтобы снять выбор с системных настроек.

   Применение сохранённого выбора живёт не здесь, а однострочником в <head>
   каждой страницы: если ставить тему отсюда, страница успеет мигнуть
   светлой до загрузки скрипта. */
(function () {
  var root = document.documentElement;
  var btn = document.getElementById("theme");
  if (!btn) return;

  function dark() {
    var set = root.dataset.theme;
    return set ? set === "dark"
               : matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function sync() {
    btn.setAttribute("aria-pressed", String(dark()));
    btn.title = dark() ? "Светлая тема" : "Тёмная тема";
  }

  btn.addEventListener("click", function () {
    var next = dark() ? "light" : "dark";
    root.dataset.theme = next;
    try { localStorage.setItem("theme", next); } catch (e) {}
    sync();
  });

  // Пока выбор не сделан руками, следуем за системой и обновляем подпись
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", sync);
  sync();
})();
