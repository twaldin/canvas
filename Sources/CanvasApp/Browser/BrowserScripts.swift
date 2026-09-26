import WebKit

/// Page-side half of the cmux subset. Runs in its own content world so pages can neither see
/// nor break it, while acting on the same DOM (events it dispatches reach page listeners).
@MainActor
enum BrowserScripts {
    static let world = WKContentWorld.world(name: "canvas-cmux")
    /// Message handler (in `world`) for page activity: `changed`, `ready`, `load`.
    static let messageName = "canvasBrowser"

    /// Prefix for calls into the helper: installs it first on documents that loaded before the
    /// user script could run (the initial about:blank, pages restored from the back cache).
    static let ensure = "if (!window.__canvasCmux) {\n\(source)\n}\n"

    static let source = #"""
    (() => {
      if (window.__canvasCmux) return;
      const post = (kind) => { try { window.webkit.messageHandlers.canvasBrowser.postMessage(kind); } catch {} };
      const fail = (code, message) => { const error = new Error(message); error.name = code; throw error; };

      // Snapshot refs (e1, e2, …) name elements until the next snapshot replaces them.
      let refs = new Map();

      function resolve(selector) {
        const ref = /^@?(e\d+)$/.exec(selector);
        if (ref) {
          const element = refs.get(ref[1])?.deref();
          if (!element || !element.isConnected) fail('not_found', `ref ${selector} is gone; take a new snapshot`);
          return element;
        }
        let element;
        try { element = document.querySelector(selector); } catch { fail('invalid_params', `invalid selector ${selector}`); }
        if (!element) fail('not_found', `no element matches ${selector}`);
        return element;
      }

      function exists(selector) {
        try { return !!resolve(selector); } catch (error) { if (error.name === 'not_found') return false; throw error; }
      }

      // MARK: roles and names (enough of ARIA for agents to pick targets)

      const inputRoles = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
        image: 'button', range: 'slider', number: 'spinbutton', search: 'searchbox', email: 'textbox', tel: 'textbox',
        url: 'textbox', text: 'textbox', password: 'textbox', '': 'textbox' };
      const tagRoles = { A: (el) => el.hasAttribute('href') ? 'link' : null, BUTTON: () => 'button',
        SELECT: (el) => el.multiple || el.size > 1 ? 'listbox' : 'combobox', TEXTAREA: () => 'textbox',
        INPUT: (el) => el.type === 'hidden' ? null : (inputRoles[el.type] ?? 'textbox'), SUMMARY: () => 'button',
        H1: () => 'heading', H2: () => 'heading', H3: () => 'heading', H4: () => 'heading', H5: () => 'heading', H6: () => 'heading',
        IMG: (el) => el.getAttribute('alt') === '' ? null : 'img', NAV: () => 'navigation', MAIN: () => 'main',
        HEADER: () => 'banner', FOOTER: () => 'contentinfo', ASIDE: () => 'complementary', FORM: () => 'form',
        UL: () => 'list', OL: () => 'list', LI: () => 'listitem', TABLE: () => 'table', TR: () => 'row',
        TD: () => 'cell', TH: () => 'columnheader', LABEL: () => 'label', P: () => 'paragraph', DIALOG: () => 'dialog',
        FIELDSET: () => 'group', LEGEND: () => 'legend', OPTION: () => 'option', IFRAME: () => 'iframe' };
      const interactiveRoles = new Set(['link', 'button', 'checkbox', 'radio', 'textbox', 'searchbox', 'combobox', 'listbox',
        'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'option', 'menuitemcheckbox', 'menuitemradio', 'treeitem']);

      const roleOf = (el) => el.getAttribute('role')?.split(' ')[0] || tagRoles[el.tagName]?.(el) || null;
      const clean = (text, limit = 100) => (text || '').replace(/\s+/g, ' ').trim().slice(0, limit);

      function nameOf(el) {
        const labelled = el.getAttribute('aria-labelledby');
        if (labelled) {
          const text = labelled.split(' ').map((id) => document.getElementById(id)?.innerText || '').join(' ');
          if (clean(text)) return clean(text);
        }
        const direct = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title');
        if (clean(direct)) return clean(direct);
        if (el.labels && el.labels.length) return clean([...el.labels].map((label) => label.innerText).join(' '));
        if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value || el.type);
        if (el.placeholder) return clean(el.placeholder);
        if (['INPUT', 'SELECT', 'TEXTAREA'].includes(el.tagName)) return clean(el.name);
        return clean(el.innerText);
      }

      function isVisible(el) {
        if (el.getAttribute('aria-hidden') === 'true') return false;
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      }

      const isInteractive = (el, role) => interactiveRoles.has(role) || el.isContentEditable
        || (el.hasAttribute('onclick') && !['BODY', 'HTML'].includes(el.tagName))
        || (el.tabIndex >= 0 && el.hasAttribute('tabindex'));

      function describe(el, role) {
        let line = `${role || 'generic'}`;
        const name = nameOf(el);
        if (name) line += ` ${JSON.stringify(name)}`;
        if (role === 'heading') line += ` [level=${el.tagName[1] || el.getAttribute('aria-level') || 2}]`;
        if ('checked' in el && (role === 'checkbox' || role === 'radio')) line += el.checked ? ' [checked]' : '';
        if (el.disabled) line += ' [disabled]';
        if (['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider'].includes(role) && 'value' in el && el.value && el.type !== 'password') {
          line += `: ${JSON.stringify(clean(el.value, 200))}`;
        }
        return line;
      }

      // Interactive: a flat list of what an agent can act on. Otherwise: the semantic outline.
      function snapshot(interactive, maxDepth) {
        refs = new Map();
        const entries = {};
        const lines = [];
        let next = 1;
        const add = (el, role, depth) => {
          const ref = `e${next++}`;
          refs.set(ref, new WeakRef(el));
          entries[ref] = { role: role || 'generic', name: nameOf(el) };
          lines.push(`${'  '.repeat(depth)}- ${describe(el, role)} [ref=${ref}]`);
        };
        const walk = (el, depth) => {
          for (const child of el.children) {
            if (!isVisible(child) && child.tagName !== 'OPTION') continue;
            const role = roleOf(child);
            const actionable = isInteractive(child, role);
            let shown = false;
            if (interactive ? actionable : (actionable || (role && !['generic', 'none', 'presentation', 'label', 'legend'].includes(role)))) {
              if (!interactive && depth >= (maxDepth ?? Infinity)) continue;
              add(child, role, interactive ? 0 : depth);
              shown = true;
            }
            if (child.shadowRoot) walk(child.shadowRoot, shown ? depth + 1 : depth);
            if (!['SELECT', 'BUTTON', 'A'].includes(child.tagName) || !shown) walk(child, shown ? depth + 1 : depth);
          }
        };
        if (document.body) walk(document.body, 0);
        const page = { title: document.title, url: location.href, ready_state: document.readyState };
        if (!interactive) {
          page.text = document.body ? document.body.innerText : '';
          page.html = document.documentElement.outerHTML;
        }
        return { snapshot: lines.join('\n'), refs: entries, page, url: location.href, title: document.title, ready_state: document.readyState };
      }

      // MARK: actions

      const center = (el) => { const r = el.getBoundingClientRect(); return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }; };
      const mouse = (el, type, extra = {}) => {
        const Kind = type.startsWith('pointer') ? PointerEvent : MouseEvent;
        return el.dispatchEvent(new Kind(type, { bubbles: true, cancelable: true, composed: true, view: window, button: 0, buttons: type.endsWith('down') ? 1 : 0, ...center(el), ...extra }));
      };
      const fire = (el, type) => el.dispatchEvent(new Event(type, { bubbles: true, cancelable: type !== 'change' && type !== 'input' ? true : false }));
      const focusable = (el) => typeof el.focus === 'function';

      function click(el, detail = 1) {
        el.scrollIntoView({ block: 'center', inline: 'center' });
        mouse(el, 'pointerdown', { detail }); mouse(el, 'mousedown', { detail });
        if (focusable(el)) el.focus({ preventScroll: true });
        mouse(el, 'pointerup', { detail }); mouse(el, 'mouseup', { detail });
        el.click();
      }

      // Sets a form control's value the way user input does, so framework listeners see it.
      function setValue(el, value) {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
          : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (setter) setter.call(el, value); else el.value = value;
      }

      function insertText(el, text) {
        if (el.isContentEditable) {
          document.execCommand('insertText', false, text);
          return;
        }
        if (!('value' in el)) fail('invalid_params', `${el.tagName.toLowerCase()} does not take text`);
        let start = el.value.length, end = start;
        try { start = el.selectionStart ?? start; end = el.selectionEnd ?? end; } catch {}
        setValue(el, el.value.slice(0, start) + text + el.value.slice(end));
        try { el.setSelectionRange(start + text.length, start + text.length); } catch {}
        el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
      }

      function key(el, type, init) {
        return el.dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true, composed: true, ...init }));
      }

      const keyNames = { Return: 'Enter', Esc: 'Escape', Space: ' ', Del: 'Delete', Up: 'ArrowUp', Down: 'ArrowDown', Left: 'ArrowLeft', Right: 'ArrowRight' };
      const tabbable = () => [...document.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable=""], [contenteditable="true"]')]
        .filter((el) => !el.disabled && el.tabIndex >= 0 && isVisible(el));

      function press(combo) {
        const parts = combo.split('+');
        const name = keyNames[parts.at(-1)] ?? parts.at(-1);
        const mods = new Set(parts.slice(0, -1).map((m) => m.toLowerCase()));
        const init = { key: name, code: name.length === 1 ? (/\d/.test(name) ? `Digit${name}` : `Key${name.toUpperCase()}`) : name,
          ctrlKey: mods.has('control') || mods.has('ctrl'), shiftKey: mods.has('shift'), altKey: mods.has('alt') || mods.has('option'),
          metaKey: mods.has('meta') || mods.has('command') || mods.has('cmd') };
        const target = document.activeElement || document.body;
        const proceed = key(target, 'keydown', init);
        if (proceed && !init.ctrlKey && !init.metaKey && !init.altKey) {
          if (name === 'Enter') {
            if (target instanceof HTMLTextAreaElement || target.isContentEditable) insertText(target, '\n');
            else if (target.form && target instanceof HTMLInputElement) target.form.requestSubmit();
            else if (target instanceof HTMLButtonElement || target instanceof HTMLAnchorElement) target.click();
          } else if (name === 'Tab') {
            const order = tabbable();
            const index = order.indexOf(target);
            const next = order[(index + (init.shiftKey ? -1 : 1) + order.length) % order.length];
            next?.focus();
          } else if (name === ' ' && (target instanceof HTMLButtonElement || (target instanceof HTMLInputElement && ['checkbox', 'radio', 'button', 'submit'].includes(target.type)))) {
            target.click();
          } else if (name === 'Backspace' && 'value' in target && typeof target.value === 'string') {
            const start = target.selectionStart ?? target.value.length, end = target.selectionEnd ?? start;
            const from = start === end ? Math.max(0, start - 1) : start;
            setValue(target, target.value.slice(0, from) + target.value.slice(end));
            fire(target, 'input');
          } else if (name.length === 1 && (('value' in target && typeof target.value === 'string') || target.isContentEditable)) {
            insertText(target, name);
          }
        }
        key(target, 'keyup', init);
        return {};
      }

      function act(action, selector, text) {
        const el = resolve(selector);
        switch (action) {
          case 'click': click(el); break;
          case 'dblclick': click(el, 1); click(el, 2); mouse(el, 'dblclick', { detail: 2 }); break;
          case 'hover':
            el.scrollIntoView({ block: 'center', inline: 'center' });
            for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) mouse(el, type);
            break;
          case 'focus': if (focusable(el)) el.focus(); break;
          case 'check': case 'uncheck': {
            const want = action === 'check';
            if (!('checked' in el)) fail('invalid_params', `${selector} is not a checkbox or radio`);
            if (el.checked !== want) click(el);
            if (el.checked !== want) { el.checked = want; fire(el, 'input'); fire(el, 'change'); }
            break;
          }
          case 'scroll_into_view': el.scrollIntoView({ block: 'center', inline: 'center' }); break;
          case 'type':
            if (focusable(el)) el.focus();
            for (const character of text) {
              const init = { key: character };
              if (key(el, 'keydown', init)) { key(el, 'keypress', init); insertText(el, character); }
              key(el, 'keyup', init);
            }
            break;
          case 'fill':
            if (focusable(el)) el.focus();
            if (el.isContentEditable) {
              el.textContent = text;
              fire(el, 'input');
            } else {
              if (!('value' in el)) fail('invalid_params', `${selector} is not a form field`);
              setValue(el, text);
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: text }));
              fire(el, 'change');
            }
            break;
          default: fail('invalid_params', `unknown action ${action}`);
        }
        return {};
      }

      // Resolves when the selector matches, or false after `timeout` ms.
      function waitFor(selector, timeout) {
        if (exists(selector)) return Promise.resolve(true);
        return new Promise((done) => {
          const observer = new MutationObserver(() => { if (exists(selector)) { observer.disconnect(); clearTimeout(timer); done(true); } });
          const timer = setTimeout(() => { observer.disconnect(); done(false); }, timeout);
          observer.observe(document, { subtree: true, childList: true, attributes: true });
        });
      }

      // Page activity, coalesced, so the tile can refresh its snapshot and wake waiters.
      let pending = null;
      const changed = () => { if (!pending) pending = setTimeout(() => { pending = null; post('changed'); }, 300); };
      const start = () => {
        new MutationObserver(changed).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
        for (const type of ['input', 'change', 'scroll', 'resize']) addEventListener(type, changed, { capture: true, passive: true });
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { post('ready'); start(); }, { once: true });
      else { post('ready'); start(); }
      if (document.readyState !== 'complete') addEventListener('load', () => post('load'), { once: true });

      window.__canvasCmux = { snapshot, act, press, exists, waitFor,
        scroll(dx, dy) { scrollBy(dx, dy); return { scroll_x: scrollX, scroll_y: scrollY }; },
        readyState: () => document.readyState };
    })();
    """#
}
