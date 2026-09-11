'use strict';

// A deliberately illustrative library; no user data or remote service is used.
const memories = [
  { id:'launch-checklist',title:'The launch checklist',app:'Notion',time:'Today · 09:12',kind:'Captured page',icon:'page',excerpt:'A smaller first release. Three things to finish before Friday.',text:'For Friday’s launch: finish the welcome flow, check the first-run copy, and publish the short getting-started guide. The new dashboard can follow in the next release.',tags:'launch friday checklist release first run' },
  { id:'launch-message',title:'The message with the missing detail',app:'Slack',time:'Today · 11:26',kind:'Saved moment',icon:'bookmark',excerpt:'The launch email should link straight to the getting-started guide.',text:'One useful detail for the launch: link the email directly to the getting-started guide. It will help people get through setup and try their first useful workflow.',tags:'launch friday email message guide' },
  { id:'launch-decision',title:'What stays in the first release',app:'Product catch-up',time:'Yesterday · 16:40',kind:'Conversation',icon:'wave',excerpt:'Keep Friday focused on a smooth first run. The dashboard can wait.',text:'Let’s keep Friday’s launch small. A smooth first run matters more than another dashboard. We’ll finish the welcome flow, review the copy, and move the dashboard to the next release.',tags:'launch friday release decision conversation first run' },
  { id:'onboarding-note',title:'One less step in onboarding',app:'Notes',time:'Today · 10:18',kind:'Saved moment',icon:'bookmark',excerpt:'Show the first useful result before introducing the advanced settings.',text:'An idea to come back to: guide someone to their first useful result, then introduce the advanced settings when they need them. A smaller first step makes the rest easier to understand.',tags:'onboarding welcome idea setup first result' },
  { id:'onboarding-page',title:'The welcome-flow reference',app:'Safari',time:'Yesterday · 14:05',kind:'Captured page',icon:'page',excerpt:'A clear next step, one screen at a time.',text:'The reference flow uses one clear action per screen. Each step explains what is needed and why, and the final step takes you directly into the product.',tags:'onboarding welcome design reference page' },
  { id:'onboarding-thread',title:'A better first-run question',app:'Slack',time:'Yesterday · 15:22',kind:'Captured text',icon:'message',excerpt:'Ask what someone wants to do before showing every feature.',text:'For onboarding, could we start with what someone wants to do today? It gives the first run a useful direction and helps us show the right feature at the right moment.',tags:'onboarding first run welcome question setup message' }
];

const form = document.querySelector('#recall-form');
const queryInput = document.querySelector('#memory-query');
const results = document.querySelector('#memory-results');
const count = document.querySelector('#result-count');
const sourceDialog = document.querySelector('#source-dialog');
const imageDialog = document.querySelector('#image-dialog');
const svgNS = 'http://www.w3.org/2000/svg';

function icon(name, className = '') {
  const svg = document.createElementNS(svgNS, 'svg');
  svg.setAttribute('aria-hidden', 'true');
  if (className) svg.setAttribute('class', className);
  const use = document.createElementNS(svgNS, 'use');
  use.setAttribute('href', `#${name}`);
  svg.append(use);
  return svg;
}

function showSource(memory) {
  document.querySelector('#source-meta').textContent = `${memory.app} · ${memory.time} · ${memory.kind}`;
  document.querySelector('#source-title').textContent = memory.title;
  document.querySelector('#source-text').textContent = memory.text;
  sourceDialog.showModal();
}

function searchMemory() {
  const query = queryInput.value.trim().toLowerCase();
  const words = query.split(/\s+/).filter(Boolean);
  const matches = memories.filter(memory => {
    const text = `${memory.title} ${memory.excerpt} ${memory.app} ${memory.tags}`.toLowerCase();
    return words.every(word => text.includes(word));
  });
  results.replaceChildren();
  count.textContent = `${matches.length} ${matches.length === 1 ? 'moment' : 'moments'}`;
  document.querySelectorAll('[data-query]').forEach(button => button.classList.toggle('selected', button.dataset.query.toLowerCase() === query));
  if (!matches.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-state';
    const title = document.createElement('strong');
    title.textContent = 'No moment in this example yet.';
    const help = document.createElement('p');
    help.textContent = 'Try “launch”, “onboarding”, or “Friday” to explore the example memory.';
    empty.append(title, help);
    results.append(empty);
    return;
  }
  matches.forEach(memory => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'memory-result';
    button.setAttribute('aria-label', `Open ${memory.title}, ${memory.app}`);
    const badge = document.createElement('span');
    badge.className = 'result-icon';
    badge.append(icon(memory.icon));
    const body = document.createElement('span');
    body.className = 'result-body';
    const title = document.createElement('strong');
    title.textContent = memory.title;
    const excerpt = document.createElement('span');
    excerpt.className = 'result-excerpt';
    excerpt.textContent = memory.excerpt;
    const meta = document.createElement('span');
    meta.className = 'result-meta';
    meta.textContent = `${memory.app} · ${memory.time}`;
    body.append(title, excerpt, meta);
    button.append(badge, body, icon('diagonal', 'result-arrow'));
    button.addEventListener('click', () => showSource(memory));
    results.append(button);
  });
}

if (typeof sourceDialog.showModal === 'function') {
  form.addEventListener('submit', event => { event.preventDefault(); searchMemory(); });
  queryInput.addEventListener('input', searchMemory);
  document.querySelectorAll('[data-query]').forEach(button => button.addEventListener('click', () => {
    queryInput.value = button.dataset.query;
    searchMemory();
  }));
  searchMemory();
  document.querySelectorAll('[data-enhance]').forEach(element => { element.hidden = false; });
  document.querySelector('[data-recall-fallback]').remove();
}

const views = {
  timeline:{src:'assets/screens/timeline-workspace.webp',title:'Timeline',alt:'LokalBot Timeline shows work sessions across apps, a day digest, and tasks alongside conversations.'},
  recall:{src:'assets/screens/quick-recall.webp',title:'Quick Recall',alt:'Quick Recall searches saved Slack context, a captured Safari page, and conversation transcripts.'},
  write:{src:'assets/screens/cotyping.webp',title:'Write',alt:'LokalBot Autocomplete shows a writing suggestion and setup for system-wide typing.'}
};
let selectedView = 'timeline';
let imageRevision = 0;
const appImage = document.querySelector('#app-image');
const appStage = document.querySelector('#open-app');
const galleryStatus = document.querySelector('#gallery-status');
function modifiedClick(event) {
  return event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey;
}
document.querySelectorAll('[data-view]').forEach(link => link.addEventListener('click', async event => {
  if (modifiedClick(event)) return;
  event.preventDefault();
  const revision = ++imageRevision;
  const key = link.dataset.view;
  const view = views[key];
  appStage.classList.remove('is-changing');
  galleryStatus.textContent = 'The Mac app';
  if (key === selectedView) return;
  try {
    // Keep the current view visible until the requested image is ready. A newer
    // selection cancels older work, including a late load or decode failure.
    const candidate = new Image();
    candidate.src = view.src;
    await candidate.decode();
    if (revision !== imageRevision) return;
    appStage.classList.add('is-changing');
    if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      await new Promise(resolve => window.setTimeout(resolve, 160));
    }
    if (revision !== imageRevision) return;
    selectedView = key;
    appImage.src = view.src;
    appImage.alt = view.alt;
    appStage.href = view.src;
    appStage.setAttribute('aria-label', `Open the full ${view.title} screenshot`);
    document.querySelectorAll('[data-view]').forEach(item => {
      const active = item === link;
      item.classList.toggle('active', active);
      if (active) item.setAttribute('aria-current', 'true');
      else item.removeAttribute('aria-current');
    });
  } catch {
    if (revision === imageRevision) galleryStatus.textContent = `Couldn’t load ${view.title}. Try again.`;
  } finally {
    if (revision === imageRevision) appStage.classList.remove('is-changing');
  }
}));
appStage.addEventListener('click', event => {
  if (modifiedClick(event) || typeof imageDialog.showModal !== 'function') return;
  event.preventDefault();
  const view = views[selectedView];
  const image = document.querySelector('#full-image');
  image.src = view.src;
  image.alt = view.alt;
  document.querySelector('#image-title').textContent = `LokalBot · ${view.title}`;
  imageDialog.showModal();
});

document.querySelectorAll('dialog').forEach(dialog => {
  dialog.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const box = dialog.getBoundingClientRect();
    if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) dialog.close();
  });
});

if ('IntersectionObserver' in window) {
  const motion = !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (motion) document.documentElement.classList.add('js-motion');
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-seen');
      observer.unobserve(entry.target);
    });
  }, {threshold:0.15});
  document.querySelectorAll('[data-reveal]').forEach(element => observer.observe(element));
}
