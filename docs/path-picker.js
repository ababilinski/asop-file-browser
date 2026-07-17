(function () {
  const picker = document.querySelector(".path-picker");

  if (!picker) {
    return;
  }

  const tabs = Array.from(picker.querySelectorAll('[role="tab"]'));
  const panels = tabs
    .map((tab) => document.getElementById(tab.getAttribute("aria-controls")))
    .filter(Boolean);
  const nestedPaths = {
    "usb-debugging": "developer-options",
    "wifi-debugging": "developer-options"
  };

  function selectPath(path, moveToPanel) {
    const requestedPath = path;
    const parentPath = nestedPaths[requestedPath] || requestedPath;
    const selectedTab = tabs.find((tab) => tab.dataset.path === parentPath) || tabs[0];
    const selectedPath = selectedTab.dataset.path;

    tabs.forEach((tab) => {
      const isSelected = tab === selectedTab;
      tab.classList.toggle("is-selected", isSelected);
      tab.setAttribute("aria-selected", String(isSelected));
      tab.tabIndex = isSelected ? 0 : -1;
    });

    panels.forEach((panel) => {
      panel.hidden = panel.id !== selectedPath;
    });

    if (requestedPath && !nestedPaths[requestedPath] && window.location.hash !== `#${selectedPath}`) {
      history.replaceState(null, "", `${window.location.pathname}${window.location.search}#${selectedPath}`);
    }

    if (moveToPanel) {
      const selectedPanel = document.getElementById(requestedPath) || document.getElementById(selectedPath);
      const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      selectedPanel.scrollIntoView({ behavior: reduceMotion ? "auto" : "smooth", block: "start" });
    } else if (nestedPaths[requestedPath]) {
      requestAnimationFrame(() => document.getElementById(requestedPath).scrollIntoView({ block: "start" }));
    }
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => selectPath(tab.dataset.path, true));
    tab.addEventListener("keydown", (event) => {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
        return;
      }

      event.preventDefault();
      const offset = event.key === "ArrowRight" ? 1 : -1;
      const nextIndex = (index + offset + tabs.length) % tabs.length;
      tabs[nextIndex].focus();
      selectPath(tabs[nextIndex].dataset.path, false);
    });
  });

  window.addEventListener("hashchange", () => {
    selectPath(window.location.hash.slice(1), false);
  });

  selectPath(window.location.hash.slice(1), false);
}());
