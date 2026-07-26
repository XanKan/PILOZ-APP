(function initPilozPremiumMotion() {
  'use strict';

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = window.matchMedia('(pointer: fine)');
  const decorated = new WeakSet();
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

  function decorateView(main) {
    const root = main.firstElementChild;
    if (!root) return;

    root.classList.add('piloz-view-enter');
    const cards = [...main.querySelectorAll(cardSelector)].slice(0, 36);
    cards.forEach((card, index) => {
      card.classList.add('piloz-motion-item');
      card.style.setProperty('--piloz-order', String(Math.min(index, 12)));
      bindSpotlight(card);
    });

    requestAnimationFrame(() => root.classList.add('piloz-view-visible'));
  }

  function initViewTransitions() {
    const main = document.getElementById('main');
    if (!main) return;
    decorateView(main);

    const observer = new MutationObserver((mutations) => {
      if (!mutations.some((mutation) => mutation.addedNodes.length || mutation.removedNodes.length)) return;
      requestAnimationFrame(() => decorateView(main));
    });
    observer.observe(main, { childList: true });
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

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
