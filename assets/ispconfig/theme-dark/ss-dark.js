/*
  LuckyStack: переключатель тёмной темы ISPConfig.
  - на загрузке ставит класс ss-dark на <html>, если выбрано в localStorage,
    либо (если выбора ещё нет) по системной теме (prefers-color-scheme: dark);
  - ssToggleTheme() — переключает и запоминает выбор. Кнопка в шапке зовёт его.
  Подключён в <head> (до отрисовки) — минимальный «мигающий» переход.
*/
(function () {
	try {
		var p = localStorage.getItem('ss-theme');
		var dark = (p === 'dark') ||
			(p === null && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
		if (dark) document.documentElement.className += ' ss-dark';
	} catch (e) {}

	window.ssToggleTheme = function () {
		try {
			var on = document.documentElement.classList.toggle('ss-dark');
			localStorage.setItem('ss-theme', on ? 'dark' : 'light');
		} catch (e) {}
	};
})();
