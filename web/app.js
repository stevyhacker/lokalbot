/* LokalBot landing page interactions. Vanilla, no dependencies. */
(function () {
  "use strict";

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (sel, ctx) { return (ctx || document).querySelector(sel); };
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); };

  /* ---------- scroll reveal (IntersectionObserver, no scroll listeners) ---------- */
  var reveals = $$(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -7% 0px" });
    reveals.forEach(function (el) { io.observe(el); });
  }

  /* ---------- hero demo video: honor reduced motion, pause offscreen ---------- */
  var heroDemo = $(".hero__demo");
  if (heroDemo) {
    if (reduce) {
      heroDemo.removeAttribute("autoplay");
      heroDemo.pause();
    } else if ("IntersectionObserver" in window) {
      var heroIO = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            var p = heroDemo.play();
            if (p && p.catch) { p.catch(function () {}); }
          } else {
            heroDemo.pause();
          }
        });
      }, { threshold: 0.1 });
      heroIO.observe(heroDemo);
    }
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
    render();

    field.addEventListener("mousedown", function (e) {
      e.preventDefault();
      input.focus();
      var L = input.value.length;
      try { input.setSelectionRange(L, L); } catch (_) {}
    });
    input.addEventListener("focus", function () { stopAuto(); if (cotype) cotype.classList.add("is-focused"); });
    input.addEventListener("blur", function () { if (cotype) cotype.classList.remove("is-focused"); });
    input.addEventListener("input", function () { dismissed = false; stopAuto(); render(); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Tab" && ghostFor(input.value)) {
        e.preventDefault();
        stopAuto();
        acceptWord();
      } else if (e.key === "Escape") {
        dismissed = true;
        render();
      }
    });

    /* autoplay loop, only while in view and motion is allowed */
    var timers = [];
    var stopped = false;
    function stopAuto() {
      stopped = true;
      timers.forEach(clearTimeout);
      timers = [];
    }
    function at(fn, ms) {
      var t = setTimeout(function () { if (!stopped) fn(); }, ms);
      timers.push(t);
    }
    function runAuto() {
      if (stopped) return;
      var prefix = "Following up on";
      input.value = "";
      render();
      var d = 420;
      for (var i = 1; i <= prefix.length; i++) {
        (function (n, delay) { at(function () { input.value = prefix.slice(0, n); render(); }, delay); })(i, d);
        d += 65;
      }
      d += 520;
      (function step() {
        at(function () {
          if (acceptWord()) { step(); }
          else { at(function () { runAuto(); }, 1900); }
        }, d);
        d = 360;
      })();
    }

    if (!reduce && "IntersectionObserver" in window) {
      var demoIO = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting && !stopped) { runAuto(); demoIO.disconnect(); }
        });
      }, { threshold: 0.5 });
      demoIO.observe(cotype || field);
    }
  }
})();
