(function initPilozPremiumMotion() {
  'use strict';

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = window.matchMedia('(pointer: fine)');
  const decorated = new WeakSet();
  let lastViewKey = '';
  let routeTransitionPending = true;
  let viewObserver = null;
  const cardSelector = [
    '.card', '.phase1-card', '.modern-card', '.modern-kpi',
    '.modern-table-shell', '.commercial-dashboard-block',
    '.commercial-kanban-card', '.erp-document-card', '.settings-card',
    '.document-list-card', '.client-card', '.catalog-card'
  ].join(',');

  function bindSpotlight(element) {
    if (!finePointer.matches || reducedMotion.matches || decorated.has(element)) return;
    decorated.add(element);
    element.addEventListener('pointermove', (event) => {
      const rect = element.getBoundingClientRect();
      element.style.setProperty('--piloz-spot-x', `${event.clientX - rect.left}px`);
      element.style.setProperty('--piloz-spot-y', `${event.clientY - rect.top}px`);
    }, { passive: true });
    element.addEventListener('pointerleave', () => {
      element.style.removeProperty('--piloz-spot-x');
      element.style.removeProperty('--piloz-spot-y');
    }, { passive: true });
  }

  function viewKey() {
    return (window.location.hash || '#dashboard').slice(1).split('?')[0] || 'dashboard';
  }

  function decorateView(main) {
    const root = main.firstElementChild;
    if (!root) return;

    const nextViewKey = viewKey();
    const enteringView = routeTransitionPending || nextViewKey !== lastViewKey;
    root.classList.toggle('piloz-view-enter', enteringView);
    root.classList.toggle('piloz-view-visible', !enteringView);
    lastViewKey = nextViewKey;
    routeTransitionPending = false;
    const cards = [...main.querySelectorAll(cardSelector)].slice(0, 36);
    cards.forEach((card, index) => {
      card.classList.add('piloz-motion-item');
      card.style.setProperty('--piloz-order', String(Math.min(index, 12)));
      bindSpotlight(card);
    });

    if (enteringView) requestAnimationFrame(() => root.classList.add('piloz-view-visible'));
  }

  function initViewTransitions() {
    const main = document.getElementById('main');
    if (!main) return;
    decorateView(main);

    viewObserver?.disconnect();
    viewObserver = new MutationObserver((mutations) => {
      if (!mutations.some((mutation) => mutation.addedNodes.length || mutation.removedNodes.length)) return;
      requestAnimationFrame(() => decorateView(main));
    });
    viewObserver.observe(main, { childList: true });
  }

  function initAmbientPointer() {
    if (!finePointer.matches || reducedMotion.matches) return;
    let frame = 0;
    document.addEventListener('pointermove', (event) => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        document.documentElement.style.setProperty('--piloz-pointer-x', `${event.clientX}px`);
        document.documentElement.style.setProperty('--piloz-pointer-y', `${event.clientY}px`);
      });
    }, { passive: true });
  }

  function start() {
    document.documentElement.classList.add('piloz-motion-ready');
    initViewTransitions();
    initAmbientPointer();
  }

  window.addEventListener('hashchange', () => {
    routeTransitionPending = true;
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
