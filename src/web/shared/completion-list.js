let serial = 0;

export function completionList(input, list, {take, preview = false, visibility = () => {}}) {
  let items = [], selected = -1;
  list.id ||= `completions-${++serial}`;
  list.setAttribute('role', 'listbox');
  input.setAttribute('role', 'combobox'); input.setAttribute('aria-autocomplete', 'list');
  input.setAttribute('aria-controls', list.id);
  function highlight() {
    [...list.children].forEach((item, index) => {
      item.classList.toggle('at', index === selected);
      item.setAttribute('aria-selected', String(index === selected));
    });
    if (selected < 0) input.removeAttribute('aria-activedescendant');
    else {
      input.setAttribute('aria-activedescendant', list.children[selected].id);
      list.children[selected].scrollIntoView({block: 'nearest'});
    }
  }
  function set(next) {
    items = next; selected = -1; list.replaceChildren();
    items.forEach((text, index) => {
      const item = document.createElement('li'); item.textContent = text; item.id = `${list.id}-${index}`;
      item.setAttribute('role', 'option');
      item.addEventListener('pointerdown', event => { event.preventDefault(); accept(index); }); list.append(item);
    });
    list.hidden = !items.length; input.setAttribute('aria-expanded', String(!list.hidden));
    visibility(!list.hidden); highlight();
  }
  function accept(index = Math.max(0, selected)) {
    if (items[index] === undefined) return;
    selected = index; highlight(); take(items[index]);
  }
  function move(step) {
    selected = selected < 0 ? (step > 0 ? 0 : items.length - 1) : (selected + step + items.length) % items.length;
    highlight(); if (preview) take(items[selected]);
  }
  function key(event, enter = true) {
    if (list.hidden || event.isComposing) return false;
    const next = event.key === 'ArrowDown' || (event.ctrlKey && event.key.toLowerCase() === 'n');
    const previous = event.key === 'ArrowUp' || (event.ctrlKey && event.key.toLowerCase() === 'p');
    if (next || previous) move(next ? 1 : -1);
    else if (event.key === 'Tab' && !event.shiftKey) accept();
    else if (event.key === 'Enter' && !event.shiftKey && enter && selected >= 0) accept();
    else if (event.key === 'Escape') set([]);
    else return false;
    event.preventDefault(); event.stopPropagation(); return true;
  }
  set([]);
  return {set, key, close: () => set([]), get visible() { return !list.hidden; }};
}
