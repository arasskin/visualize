export function addDocumentZoom(viewport, content) {
  let zoom = 1;
  const apply = () => {
    viewport.style.setProperty('--document-zoom', String(zoom));
    content.style.fontSize = `calc(var(--document-zoom) * 1em)`;
  };
  apply();
  viewport.addEventListener('wheel', event => {
    if (!event.ctrlKey) return;
    event.preventDefault();
    zoom = Math.max(.75, Math.min(1.5, zoom * Math.exp(-event.deltaY * .002)));
    apply();
  }, {passive: false});
}
