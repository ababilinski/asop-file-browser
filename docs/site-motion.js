(function () {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  if (reduceMotion.matches) {
    return;
  }

  const revealTargets = Array.from(document.querySelectorAll("[data-reveal]"));
  const revealLists = Array.from(document.querySelectorAll("[data-reveal-list]"));
  const privacyScene = document.querySelector('[data-scroll-scene="privacy"]');

  if (!revealTargets.length && !revealLists.length && !privacyScene) {
    return;
  }

  document.documentElement.classList.add("motion-ready");

  if (revealTargets.length) {
    const revealObserver = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) {
            return;
          }

          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      {
        rootMargin: "0px 0px -12%",
        threshold: 0.12
      }
    );

    revealTargets.forEach((target) => revealObserver.observe(target));
  }

  if (revealLists.length) {
    const cascadeObserver = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) {
            return;
          }

          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      {
        rootMargin: "0px 0px -14%",
        threshold: 0.2
      }
    );

    const itemObserver = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) {
            return;
          }

          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      {
        rootMargin: "0px 0px -10%",
        threshold: 0.16
      }
    );

    revealLists.forEach((list) => {
      const items = Array.from(list.children);
      items.forEach((item, index) => {
        item.style.setProperty("--list-reveal-index", index);
      });

      if (list.dataset.revealList === "steps" || list.dataset.revealList === "features") {
        items.forEach((item) => itemObserver.observe(item));
      } else {
        cascadeObserver.observe(list);
      }
    });
  }

  if (!privacyScene) {
    return;
  }

  const privacyObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) {
          return;
        }

        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    {
      rootMargin: "0px 0px -8%",
      threshold: 0.16
    }
  );

  privacyObserver.observe(privacyScene);
}());
