/* LokalBot landing page interactions. Vanilla, no dependencies. */
(function () {
  "use strict";

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (sel, ctx) { return (ctx || document).querySelector(sel); };
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); };

  /* ---------- homepage navigation: progressively enhanced, never modal ---------- */
  var nav = $(".nav--landing");
  var menuToggle = nav && $(".nav-toggle", nav);
  if (nav && menuToggle) {
    var narrowNav = window.matchMedia("(max-width: 760px)");
    function closeMenu(returnFocus) {
      nav.classList.remove("is-open");
      menuToggle.setAttribute("aria-expanded", "false");
      menuToggle.textContent = "Menu";
      if (returnFocus) menuToggle.focus();
    }
    menuToggle.hidden = false;
    nav.setAttribute("data-menu-ready", "");
    menuToggle.addEventListener("click", function () {
      var open = menuToggle.getAttribute("aria-expanded") !== "true";
      nav.classList.toggle("is-open", open);
      menuToggle.setAttribute("aria-expanded", String(open));
      menuToggle.textContent = open ? "Close" : "Menu";
      if (open) $(".nav__links a", nav).focus();
    });
    nav.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && nav.classList.contains("is-open")) {
        e.preventDefault();
        closeMenu(true);
      }
    });
    $$(".nav__links a", nav).forEach(function (link) {
      link.addEventListener("click", function () {
        if (!narrowNav.matches) return;
        closeMenu(false);
        var href = link.getAttribute("href");
        if (href && href.charAt(0) === "#") {
          var target = document.getElementById(href.slice(1));
          if (target) {
            target.setAttribute("tabindex", "-1");
            target.focus({ preventScroll: true });
          }
        }
      });
    });
    narrowNav.addEventListener("change", function () {
      var active = document.activeElement;
      var focusWasInLinks = $(".nav__links", nav).contains(active);
      closeMenu(narrowNav.matches && focusWasInLinks);
      if (!narrowNav.matches && active === menuToggle) $(".nav__links a", nav).focus();
    });
  }

  /* ---------- scroll reveal (IntersectionObserver, no scroll listeners) ---------- */
  var reveals = $$(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.remove("reveal--pending"); e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -7% 0px" });
    reveals.forEach(function (el) { el.classList.add("reveal--pending"); io.observe(el); });
  }

  /* ---------- hero demo video: never autoplay; pause if the user scrolls away ---------- */
  var heroDemo = $(".hero__demo");
  if (heroDemo && "IntersectionObserver" in window) {
    var heroIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) {
          heroDemo.pause();
        } else if (heroDemo.preload === "none") {
          heroDemo.preload = "metadata";
        }
      });
    }, { threshold: 0.05 });
    heroIO.observe(heroDemo);
  }

  /* ---------- waveform: randomize bar timing for an organic pulse ---------- */
  if (!reduce) {
    $$("[data-wave] span").forEach(function (bar) {
      var dur = 560 + Math.random() * 720;
      bar.style.animationDuration = dur.toFixed(0) + "ms";
      bar.style.animationDelay = (-Math.random() * dur).toFixed(0) + "ms";
    });
  }

  /* ---------- cotyping demo: ghost text + Tab to accept ---------- */
  var input = $("#ctInput");
  var typedEl = $("#ctTyped");
  var ghostEl = $("#ctGhost");
  var field = $("#cotypeField");
  var cotype = field ? field.closest(".cotype") : null;

  if (input && typedEl && ghostEl && field) {
    var SNIPPETS = [
      "Following up on our sync, the on-device build is ready to ship.",
      "Thanks for the call. I'll send the recap and action items shortly.",
      "Action item: ship the on-device summary by Friday.",
      "Let's circle back on this once the transcript lands."
    ];
    var dismissed = false;

    function ghostFor(val) {
      if (!val || dismissed) return "";
      var v = val.toLowerCase();
      for (var i = 0; i < SNIPPETS.length; i++) {
        if (SNIPPETS[i].toLowerCase().indexOf(v) === 0) return SNIPPETS[i].slice(val.length);
      }
      return "";
    }
    function render() {
      typedEl.textContent = input.value;
      ghostEl.textContent = ghostFor(input.value);
    }
    function acceptWord() {
      var g = ghostFor(input.value);
      if (!g) return false;
      var m = g.match(/^\s*\S+/);
      input.value += m ? m[0] : g;
      render();
      return true;
    }

    /* seed with the static teaser so the field is meaningful before any motion */
    input.value = (typedEl.textContent || "").trim() === "" ? "" : typedEl.textContent;
    input.disabled = false;
    render();

    input.addEventListener("focus", function () { if (cotype) cotype.classList.add("is-focused"); });
    input.addEventListener("blur", function () { if (cotype) cotype.classList.remove("is-focused"); });
    input.addEventListener("input", function () { dismissed = false; render(); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Tab" && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey && ghostFor(input.value)) {
        e.preventDefault();
        acceptWord();
      } else if (e.key === "Escape") {
        dismissed = true;
        render();
      }
    });
  }
})();
