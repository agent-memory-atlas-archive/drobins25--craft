# Annotate overlay

The comment-mode overlay that lets someone point at a page and have Claude read what they said. It is one self-contained script, and every delivery installs this same source unchanged:

- **Served by the listener** for a live inject on a project page (localhost, 127.0.0.1 or file://): `GET /overlay.js` returns the fence below, and `annotate-run.sh loader` prints the one line that loads it.
- **Pasted** on an external page, and on any page that refuses the served script: the fence goes to `evaluate_script` as the body of `() => { ... }`.
- **Spliced by `bake`** for a mockup round: `annotate-run.sh bake` writes the stamps and the fence into the page file.

The listener and `bake` read the fence below at run time, through one extractor, so the three deliveries are the same bytes. Nothing in the script knows which delivery it came from except two stamps the delivering flow writes into the page first (see [The stamps](#the-stamps)).

The script is the only copy. Flows reference this file and never retype, trim, or fork the block below, because a second copy drifts and a drifted overlay posts to the wrong place or leaves nodes behind.

## What the overlay does

A strip with three controls sits in a corner of the page: `COMMENT MODE: OFF` / `COMMENT MODE: ON`, `CLEAR PINS`, and `SEND TO CLAUDE`, with a `MARKUP - N marks` readout. With comment mode on, a thin red proof border frames the viewport and a click on any element opens a comment box. Saving it drops a numbered pin anchored to that element. Clicking a pin opens a popover with the full comment, plus EDIT and DELETE. `SEND TO CLAUDE` posts the full current set to the session's capture channel. `CLEAR PINS` tells the channel the set is void, then wipes the page.

The page under review stays the hero. There is no tint, dim, or shadow over the page: comment mode is carried by the border, the strip, and the pins, because the people using this judge the page pixel by pixel.

## Rules the source keeps, and what each protects

- **Install guard.** The source opens with `if (window.__craftAnnotateInstalled) return;`. A page that is re-injected after navigation, or injected twice by mistake, must not grow two strips. The canonical clear deletes the flag so a deliberate re-install still works.
- **Placement.** The style element goes in `head`; the sheet and strip go in `body` as the last children. Framework re-renders reconcile only their own root, so anything appended inside it is eventually eaten. Pins are inserted just before the strip so the strip stays last.
- **Namespaced handles.** `ca-style`, `ca-sheet`, `ca-strip` are ids; every other real node carries `data-craft-annotate-injected`. The canonical clear is total by construction because of that attribute. The overlay never sets the marker owned by the dial flow, because dial's bulk clear and several analyzers run on arrival and would silently delete unsent pins.
- **No port in the source.** The channel base is `'http://127.0.0.1:' + window.__craftAnnotatePort`. Each session's listener has its own OS-assigned port, stamped into its own pages. A literal in shared source would point every page at one session. An absent stamp means SEND shows `NOT ARMED - no craft session listening` while everything else keeps working locally. A stamp that is present but a request the browser refuses to send (a page policy that does not allow 127.0.0.1) shows `BLOCKED BY PAGE - ask Claude to read pins directly`: the pins are still in the page's local storage, and the session reads them from there.
- **Inert until asked.** An injected page makes no network request before a user gesture. The loader's one script request is the delivery itself, made by the flow and never by the overlay. Only a page stamped as baked opens the event stream, exactly once at load, and reloads itself on the `reload` event. A dropped stream retries quietly with a bounded backoff. There is no polling.
- **Honest confirmation.** `RETURNED` is stamped only inside the resolved-200 branch of the SEND post, and every pin in the delivered set then gains a visible sent-stamp. A non-200 reply shows `NOT ARMED - no craft session listening` and stamps nothing. A request the browser rejects outright, with the port stamped, is a refusal by the page or the browser, never a listener state: it shows `BLOCKED BY PAGE - ask Claude to read pins directly` and stamps nothing. Every other channel failure is quiet; SEND alone is loud. A stamp written from a swallowed error is a lie the user acts on.
- **Send-only.** The only request carrying pins is the one inside the SEND handler. Unsent pins live in the page and in local storage and nowhere else, so a pin the user never sent can never reach the channel.
- **SEND commits first.** An open comment box is saved through the normal save path before the set is collected, so a comment mid-typing is never dropped from the set it visibly belongs to.
- **CLEAR is authoritative.** The clear post goes first, then the wipe of DOM nodes, in-memory state, the counter, and the page-path-keyed storage entry. The post does not wait on the wipe and the wipe does not wait on the post. The strip then reads `CLEARED` and `MARKUP - 0 marks`.
- **Numbers are labels.** Deleting a pin renumbers the survivors contiguously. Nothing outside the page reasons about a pin's number as an identity.
- **Detached pins.** A pin whose anchor no longer resolves after a live edit docks above the strip in a flagged detached state, keeping its number and comment. Pins are re-checked when the page changes, not only on the next overlay event. A comment never silently vanishes.
- **Text, never markup.** Comments are written with `textContent`. A comment containing `<` must render as typed, not execute.
- **Storage keyed by page path.** Pins rehydrate from local storage under a key that includes the page path, plus the hash route when the app routes with the hash: a fragment that starts with `#/` or `#!/` is a route, its own query cut off; any other fragment is an in-page anchor and changes nothing. The pin's `page` carries the same hash route, so a pin names the route it was made on. Browsers treat all local files as one storage origin, so an unkeyed store bleeds stale pins across unrelated pages. The key is read from the path and hash route at every access, so it follows client-side navigation, by path or by hash: the old path's pins are hidden and wait in storage until the user returns, and the new path's pins show without a click. Storage is best-effort: unavailable storage means memory-only pins and no error.
- **One component lookup.** The source sets `window.__craftAnnotateComponentOf = componentOf;` right after defining it, so the pin-to-source probe asks the page for the component of any element, an ancestor included, instead of carrying a second copy of the fiber walk that would drift. The annotate clear does not delete it: the next install overwrites it.
- **Total teardown.** Every document-level handler, the page-change observer and the stream stop themselves the moment the strip is no longer attached, so a clear followed by a re-install never leaves a ghost handler creating pins.
- **Self-styled strip.** The host page's reset is hostile by default. The strip pins `position: fixed` at `z-index: 2147483000` and sets its own font, size, line height, colour, background, and box sizing.
- **Motion.** The sheet fades in over 200ms and out over 120ms; a pin settles in 150ms; the send button lifts 4px while the request is in flight. Under `prefers-reduced-motion: reduce` every duration is 0 and the stamps still show.

## The overlay source

The whole block is one self-invoking expression: served as a script it runs as is, and pasted it rides inside `() => { ... }`. The `CA` constants at the top are the only definition of the overlay's colours and geometry; they are local to this script and are not read from, or written to, any page palette or shared style source.

```overlay-source
(() => {
  if (window.__craftAnnotateInstalled) return;
  window.__craftAnnotateInstalled = true;

  const CA = {
    proofBorder: '2px solid #c8102e',
    pinMark: '#c8102e',
    pinText: '#ffffff',
    stripBg: 'rgba(16,16,19,0.95)',
    stripText: '#e8eaef',
    stripEdge: 'rgba(210,215,225,0.3)',
    stripActionHover: 'rgba(210,215,225,0.55)',
    commentSurface: '#ffffff',
    commentShadow: '0 8px 30px rgba(0,0,0,0.35)',
    commentText: '#111111',
    mono: 'ui-monospace,Menlo,Consolas,monospace',
    sans: 'system-ui,-apple-system,Segoe UI,sans-serif',
    zTop: 2147482999
  };
  const MARK = 'data-craft-annotate-injected';
  const NOT_ARMED = 'NOT ARMED - no craft session listening';
  const BLOCKED_BY_PAGE = 'BLOCKED BY PAGE - ask Claude to read pins directly';

  const css = [
    '#ca-sheet{position:fixed;top:0;left:0;right:0;bottom:0;box-sizing:border-box;border:' + CA.proofBorder + ';pointer-events:none;opacity:0;transition:opacity 120ms ease;z-index:2147482990}',
    'body.ca-mode #ca-sheet{opacity:1;transition-duration:200ms}',
    '#ca-strip{position:fixed;right:16px;bottom:16px;z-index:2147483000;display:flex;align-items:center;gap:10px;box-sizing:border-box;padding:8px 10px;border-radius:8px;font-family:' + CA.mono + ';font-size:12px;line-height:1.2;color:' + CA.stripText + ';background:' + CA.stripBg + ';text-align:left;letter-spacing:.05em}',
    '#ca-strip *{box-sizing:border-box}',
    '#ca-strip button{margin:0;font:600 12px/1.2 ' + CA.mono + ';letter-spacing:.05em;text-transform:none;color:' + CA.stripText + ';background:transparent;border:1px solid ' + CA.stripEdge + ';border-radius:8px;padding:8px 14px;cursor:pointer;transition:transform 150ms ease,border-color 150ms ease}',
    '#ca-clear:hover,#ca-send:hover{border-color:' + CA.stripActionHover + '}',
    '#ca-send.ca-lift{transform:translateY(-4px)}',
    '#ca-toggle.on{border-color:' + CA.pinMark + ';color:' + CA.pinText + '}',
    '#ca-readout{white-space:nowrap}',
    '#ca-status{white-space:nowrap;font-weight:700}',
    '#ca-status:empty{display:none}',
    '.ca-pin{position:absolute;z-index:' + CA.zTop + ';width:22px;height:22px;margin:0;padding:0;box-sizing:border-box;border-radius:50%;border:2px solid ' + CA.pinMark + ';background:' + CA.pinMark + ';color:' + CA.pinText + ';font:700 11px/1 ' + CA.mono + ';display:flex;align-items:center;justify-content:center;cursor:pointer;transform:translate(-11px,-11px);animation:ca-settle 150ms ease}',
    '@keyframes ca-settle{from{transform:translate(-11px,-11px) scale(.6)}to{transform:translate(-11px,-11px) scale(1)}}',
    '.ca-pin.ca-sent{background:' + CA.commentSurface + ';color:' + CA.pinMark + '}',
    '.ca-pin.ca-sent::after,.ca-pin.ca-detached::after{position:absolute;top:50%;left:100%;margin-left:4px;transform:translateY(-50%);padding:1px 3px;border:1px solid ' + CA.pinMark + ';background:' + CA.commentSurface + ';color:' + CA.pinMark + ';font:700 8px/1 ' + CA.mono + ';letter-spacing:.08em;white-space:nowrap}',
    '.ca-pin.ca-sent::after{content:"SENT"}',
    '.ca-pin.ca-detached{position:fixed;transform:none;animation:none;border-style:dashed;background:' + CA.commentSurface + ';color:' + CA.pinMark + '}',
    '.ca-pin.ca-detached::after{content:"DETACHED";left:auto;right:100%;margin:0 4px 0 0}',
    '.ca-box,.ca-popover{position:absolute;z-index:' + CA.zTop + ';box-sizing:border-box;background:' + CA.commentSurface + ';color:' + CA.commentText + ';box-shadow:' + CA.commentShadow + ';border-radius:8px;padding:8px 10px;font:12.5px/1.4 ' + CA.sans + ';text-align:left}',
    '.ca-box textarea{display:block;width:240px;height:60px;margin:0;padding:0;box-sizing:border-box;background:transparent;color:' + CA.commentText + ';border:none;outline:none;font:12.5px/1.4 ' + CA.sans + ';resize:none}',
    '.ca-hint{margin-top:4px;font:10px/1.2 ' + CA.mono + ';color:#555555}',
    '.ca-popover{max-width:260px}',
    '.ca-popover b{display:block;margin-bottom:4px;font:700 11px/1.2 ' + CA.mono + ';color:' + CA.pinMark + ';letter-spacing:.05em}',
    '.ca-popover p{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}',
    '.ca-popover textarea{display:block;width:240px;height:60px;margin:0;padding:4px;box-sizing:border-box;font:12.5px/1.4 ' + CA.sans + ';color:' + CA.commentText + ';background:#ffffff;border:1px solid #bbbbbb;resize:none}',
    '.ca-popover .ca-actions{display:flex;gap:8px;margin-top:8px}',
    '.ca-popover button{margin:0;padding:3px 8px;font:700 10px/1.2 ' + CA.mono + ';letter-spacing:.06em;color:' + CA.commentText + ';background:#ffffff;border:1px solid #bbbbbb;border-radius:6px;cursor:pointer}',
    'body.ca-mode,body.ca-mode *{cursor:crosshair !important}',
    'body.ca-mode #ca-strip button,body.ca-mode .ca-pin,body.ca-mode .ca-popover button{cursor:pointer !important}',
    'body.ca-mode .ca-box textarea,body.ca-mode .ca-popover textarea{cursor:text !important}',
    '@media (prefers-reduced-motion: reduce){#ca-sheet,#ca-strip button,.ca-pin{transition-duration:0ms !important;animation-duration:0ms !important}}'
  ].join('');

  const mk = (tag, cls) => {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    el.setAttribute(MARK, '');
    return el;
  };

  const style = document.createElement('style');
  style.id = 'ca-style';
  style.textContent = css;
  document.head.appendChild(style);

  const sheet = document.createElement('div');
  sheet.id = 'ca-sheet';
  document.body.appendChild(sheet);

  const strip = document.createElement('div');
  strip.id = 'ca-strip';
  const readout = mk('span');
  readout.id = 'ca-readout';
  const status = mk('span');
  status.id = 'ca-status';
  const clearBtn = mk('button');
  clearBtn.id = 'ca-clear';
  clearBtn.textContent = 'CLEAR PINS';
  const sendBtn = mk('button');
  sendBtn.id = 'ca-send';
  sendBtn.textContent = 'SEND TO CLAUDE';
  const toggle = mk('button');
  toggle.id = 'ca-toggle';
  toggle.textContent = 'COMMENT MODE: OFF';
  [readout, status, clearBtn, sendBtn, toggle].forEach(el => strip.appendChild(el));
  document.body.appendChild(strip);

  let entries = [];
  let seq = 0;
  let mode = false;
  let sending = false;
  let openBox = null;
  let openPop = null;
  let stream = null;
  let retryTimer = null;

  const base = () => window.__craftAnnotatePort ? 'http://127.0.0.1:' + window.__craftAnnotatePort : null;
  const say = text => { status.textContent = text; };
  const paintReadout = () => { readout.textContent = 'MARKUP - ' + entries.length + ' marks'; };

  // A fragment that starts with #/ or #!/ is a client-side route (its own query cut off);
  // any other fragment is an in-page anchor and does not change which pins show.
  const hashRoute = () => /^#!?\//.test(location.hash) ? location.hash.split('?')[0] : '';
  const storeKey = () => 'ca-annotations:' + location.pathname + hashRoute();

  const persist = () => {
    try {
      localStorage.setItem(storeKey(), JSON.stringify(entries.map(en => Object.assign({}, en.d, { sent: en.sent }))));
    } catch (e) { /* storage unavailable: pins stay memory-only */ }
  };

  // Registers a document-level handler that unregisters itself, and stops the stream,
  // once the strip has been removed from the page.
  const on = (target, type, fn, capture) => {
    const handler = e => {
      if (!strip.isConnected) {
        target.removeEventListener(type, handler, capture);
        stopStream();
        return;
      }
      fn(e);
    };
    target.addEventListener(type, handler, capture);
  };

  const stopStream = () => {
    clearTimeout(retryTimer);
    if (stream) { stream.close(); stream = null; }
  };

  const cssPath = el => {
    const p = [];
    while (el && el.nodeType === 1 && p.length < 5) {
      let s = el.tagName.toLowerCase();
      if (el.id) { p.unshift('#' + el.id); break; }
      if (el.classList.length) s += '.' + [...el.classList].slice(0, 2).join('.');
      p.unshift(s);
      el = el.parentElement;
    }
    return p.join(' > ');
  };

  // Nearest framework component name over the target and its ancestors, else null. Never throws.
  const componentOf = el => {
    try {
      for (let hops = 0; el && hops < 12; hops++, el = el.parentElement) {
        const fk = Object.keys(el).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
        if (fk) {
          for (let f = el[fk], d = 0; f && d < 40; f = f.return, d++) {
            const t = f.type;
            if (typeof t === 'function') return t.displayName || t.name || null;
          }
        }
        const v3 = el.__vueParentComponent;
        if (v3 && v3.type) return v3.type.name || v3.type.__name || null;
        const v2 = el.__vue__;
        if (v2 && v2.$options && v2.$options.name) return v2.$options.name;
      }
    } catch (e) {}
    return null;
  };
  window.__craftAnnotateComponentOf = componentOf;

  const boxOf = el => {
    const r = el.getBoundingClientRect();
    return {
      x: Math.round(r.left + window.scrollX),
      y: Math.round(r.top + window.scrollY),
      width: Math.round(r.width),
      height: Math.round(r.height)
    };
  };

  const makeData = (n, text, x, y, target) => {
    const d = {
      n: n,
      text: text,
      x: x,
      y: y,
      selector: cssPath(target),
      nearText: (target.textContent || '').trim().slice(0, 60),
      ts: Date.now(),
      page: location.href.split(/[?#]/)[0] + hashRoute(),
      box: boxOf(target),
      component: componentOf(target)
    };
    if (window.__craftAnnotateContext != null) d.candidate = window.__craftAnnotateContext;
    return d;
  };

  const anchorOf = d => {
    try { return d.selector ? document.querySelector(d.selector) : null; } catch (e) { return null; }
  };

  // Attached pins sit at their page coordinates; pins whose anchor is gone dock above the strip.
  const settle = () => {
    let docked = 0;
    entries.forEach(en => {
      const detached = !anchorOf(en.d);
      en.node.classList.toggle('ca-detached', detached);
      en.node.classList.toggle('ca-sent', en.sent);
      en.node.title = en.d.text;
      if (detached) {
        en.node.style.left = 'auto';
        en.node.style.top = 'auto';
        en.node.style.right = (60 + docked * 70) + 'px';
        en.node.style.bottom = '64px';
        docked++;
      } else {
        en.node.style.left = en.d.x + 'px';
        en.node.style.top = en.d.y + 'px';
        en.node.style.right = '';
        en.node.style.bottom = '';
      }
    });
  };

  const closePopover = () => {
    if (openPop) { openPop.el.remove(); openPop = null; }
  };

  const renumber = () => {
    entries.forEach((en, i) => {
      en.d.n = i + 1;
      en.node.firstChild.textContent = String(i + 1);
    });
    seq = entries.length;
  };

  const removeEntry = en => {
    closePopover();
    en.node.remove();
    entries = entries.filter(other => other !== en);
    renumber();
    persist();
    paintReadout();
    say('');
  };

  const editEntry = (en, text) => {
    en.d.text = text;
    en.sent = false;
    persist();
    settle();
    say('');
  };

  const buildPin = (n, x, y) => {
    const node = mk('div', 'ca-pin');
    const label = document.createElement('span');
    label.textContent = String(n);
    node.appendChild(label);
    node.style.left = x + 'px';
    node.style.top = y + 'px';
    document.body.insertBefore(node, strip);
    return node;
  };

  const openPopoverFor = en => {
    closePopover();
    commitOpenBox();
    settle();
    const el = mk('div', 'ca-popover');
    const head = document.createElement('b');
    const flags = (en.node.classList.contains('ca-detached') ? ' - DETACHED' : '') + (en.sent ? ' - SENT' : '');
    head.textContent = '#' + en.d.n + flags;
    const body = document.createElement('p');
    body.textContent = en.d.text || '(no text)';
    const actions = document.createElement('div');
    actions.className = 'ca-actions';
    const editBtn = document.createElement('button');
    editBtn.textContent = 'EDIT';
    const delBtn = document.createElement('button');
    delBtn.textContent = 'DELETE';
    actions.appendChild(editBtn);
    actions.appendChild(delBtn);
    el.appendChild(head);
    el.appendChild(body);
    el.appendChild(actions);
    const r = en.node.getBoundingClientRect();
    el.style.left = (window.scrollX + r.right + (en.sent ? 48 : 8)) + 'px';
    el.style.top = (window.scrollY + r.top) + 'px';
    document.body.insertBefore(el, strip);
    openPop = { el: el, en: en };
    delBtn.addEventListener('click', e => { e.stopPropagation(); removeEntry(en); });
    editBtn.addEventListener('click', e => {
      e.stopPropagation();
      const ta = document.createElement('textarea');
      ta.value = en.d.text;
      el.replaceChild(ta, body);
      actions.remove();
      ta.focus();
      ta.addEventListener('keydown', ev => {
        if (ev.key === 'Enter' && !ev.shiftKey) {
          ev.preventDefault();
          const text = ta.value.trim();
          if (text) editEntry(en, text);
          closePopover();
        }
        if (ev.key === 'Escape') closePopover();
      });
    });
  };

  const adopt = (d, sent, node) => {
    const en = { d: d, sent: sent, node: node };
    node.addEventListener('click', e => {
      e.stopPropagation();
      if (openPop && openPop.en === en) { closePopover(); return; }
      openPopoverFor(en);
    });
    entries.push(en);
    return en;
  };

  const commitOpenBox = () => {
    if (openBox) openBox.commit();
  };

  const startComment = e => {
    commitOpenBox();
    const x = e.pageX;
    const y = e.pageY;
    const target = e.target;
    const n = ++seq;
    const pin = buildPin(n, x, y);
    const box = mk('div', 'ca-box');
    box.style.left = (x + 14) + 'px';
    box.style.top = (y + 6) + 'px';
    const ta = document.createElement('textarea');
    ta.placeholder = 'what is wrong here?';
    const hint = document.createElement('div');
    hint.className = 'ca-hint';
    hint.textContent = 'Enter = save / Esc = cancel';
    box.appendChild(ta);
    box.appendChild(hint);
    document.body.insertBefore(box, strip);
    ta.focus();
    const finish = () => { box.remove(); openBox = null; };
    const cancel = () => { finish(); pin.remove(); seq--; };
    const commit = () => {
      const text = ta.value.trim();
      if (!text) { cancel(); return; }
      adopt(makeData(n, text, x, y, target), false, pin);
      finish();
      persist();
      settle();
      paintReadout();
      say('');
    };
    openBox = { commit: commit, cancel: cancel };
    ta.addEventListener('keydown', ev => {
      if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); commit(); }
      if (ev.key === 'Escape') cancel();
    });
  };

  const setMode = next => {
    mode = next;
    toggle.classList.toggle('on', next);
    toggle.textContent = next ? 'COMMENT MODE: ON' : 'COMMENT MODE: OFF';
    document.body.classList.toggle('ca-mode', next);
  };

  const currentSet = () => entries.map(en => Object.assign({}, en.d));

  const markSent = () => {
    entries.forEach(en => { en.sent = true; });
    persist();
    settle();
  };

  const send = () => {
    if (sending) return;
    commitOpenBox();
    settle();
    const set = currentSet();
    if (!set.length) { say('NOTHING TO SEND'); return; }
    const root = base();
    if (!root) { say(NOT_ARMED); return; }
    sending = true;
    sendBtn.classList.add('ca-lift');
    fetch(root + '/pins', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(set)
    }).then(res => {
      sending = false;
      sendBtn.classList.remove('ca-lift');
      if (!res.ok) { say(NOT_ARMED); return; }
      markSent();
      say('RETURNED');
    }).catch(() => {
      sending = false;
      sendBtn.classList.remove('ca-lift');
      say(BLOCKED_BY_PAGE);
    });
  };

  const clearAll = () => {
    const root = base();
    if (root) {
      fetch(root + '/clear', { method: 'POST' }).catch(() => {});
    }
    closePopover();
    entries.forEach(en => en.node.remove());
    document.querySelectorAll('.ca-pin,.ca-box,.ca-popover').forEach(el => el.remove());
    openBox = null;
    entries = [];
    seq = 0;
    try { localStorage.removeItem(storeKey()); } catch (e) { /* storage unavailable */ }
    paintReadout();
    say('CLEARED');
  };

  // Loads the pins stored under the current path; runs at install and after a path change.
  const rehydrate = () => {
    try {
      const stored = JSON.parse(localStorage.getItem(storeKey()) || '[]');
      if (Array.isArray(stored)) {
        stored.forEach(a => {
          if (!a || typeof a.n !== 'number' || typeof a.x !== 'number' || typeof a.y !== 'number') return;
          const sent = a.sent === true;
          const d = Object.assign({}, a);
          delete d.sent;
          adopt(d, sent, buildPin(d.n, d.x, d.y));
        });
        renumber();
      }
    } catch (e) { /* unreadable storage: start empty */ }
  };

  // The page route (path plus hash route) this overlay last rendered pins for.
  let renderedRoute = location.pathname + hashRoute();

  // A client-side route change keeps the document, so the old path's pins are hidden
  // (their data is already persisted) and the new path's are shown.
  const checkPath = () => {
    if (location.pathname + hashRoute() === renderedRoute) return;
    renderedRoute = location.pathname + hashRoute();
    closePopover();
    if (openBox) openBox.cancel();
    entries.forEach(en => en.node.remove());
    entries = [];
    seq = 0;
    rehydrate();
    settle();
    paintReadout();
  };

  rehydrate();
  settle();
  paintReadout();

  toggle.addEventListener('click', e => { e.stopPropagation(); setMode(!mode); });
  sendBtn.addEventListener('click', e => { e.stopPropagation(); send(); });
  clearBtn.addEventListener('click', e => { e.stopPropagation(); clearAll(); });

  on(document, 'click', e => {
    if (!mode || e.target.closest('#ca-strip,[' + MARK + ']')) return;
    e.preventDefault();
    e.stopPropagation();
    startComment(e);
  }, true);
  on(document, 'click', e => {
    if (!openPop || e.target.closest('.ca-popover,.ca-pin')) return;
    closePopover();
  }, true);
  on(document, 'keydown', e => { if (e.key === 'Escape') closePopover(); }, false);
  on(window, 'popstate', checkPath, false);
  on(window, 'hashchange', checkPath, false);
  if (window.navigation) on(window.navigation, 'currententrychange', checkPath, false);

  // pushState is not promised to fire an event, so any DOM change also checks the path.
  // One frame of debounce; the observer stops with the strip.
  let framePending = false;
  const watcher = new MutationObserver(() => {
    if (framePending) return;
    framePending = true;
    requestAnimationFrame(() => {
      framePending = false;
      if (!strip.isConnected) { watcher.disconnect(); stopStream(); return; }
      checkPath();
      settle();
    });
  });
  watcher.observe(document.body, { childList: true, subtree: true });

  if (window.__craftAnnotateBaked && base()) {
    let delay = 1000;
    const connect = () => {
      if (!strip.isConnected) return;
      stream = new EventSource(base() + '/events');
      stream.addEventListener('open', () => { delay = 1000; });
      stream.addEventListener('reload', () => { location.reload(); });
      stream.onerror = () => {
        stopStream();
        retryTimer = setTimeout(connect, delay);
        delay = Math.min(delay * 2, 30000);
      };
    };
    connect();
  }
})();
```

Two details of the source worth knowing before editing it. Pins hold their page coordinates and are re-checked against the live page each time the set is settled, which is how a pin whose anchor was removed moves to the dock without being lost. Pins that were part of an acknowledged SEND stay stamped until they are edited, so sent-versus-new always reads at a glance; the strip's `RETURNED` is cleared by the next add, edit, or delete.

## The canonical annotate clear

This is the literal every flow runs to strip the overlay, stated once. It is safe to run unconditionally: on a page that was never annotated every step is a no-op.

```annotate-clear
document.getElementById('ca-style')?.remove(); document.getElementById('ca-sheet')?.remove(); document.getElementById('ca-strip')?.remove(); document.querySelectorAll('[data-craft-annotate-injected],.ca-pin,.ca-popover,.ca-box').forEach(el => el.remove()); document.body.classList.remove('ca-mode'); delete window.__craftAnnotateInstalled;
```

Removing the strip is what retires the overlay's handlers and any open stream: each one notices the strip is gone the next time it fires and unregisters itself. Pins the user has not sent stay in local storage; the clear removes the page's overlay, not the user's work. A flow that wants the channel emptied as well posts the tombstone separately (below).

## The stamps

The delivering flow writes these before the overlay source runs. The port is the one printed when the session's listener was armed.

```annotate-stamp
window.__craftAnnotatePort = <port>;
window.__craftAnnotateBaked = true;
window.__craftAnnotateContext = '<candidate letter>';
```

- `__craftAnnotatePort` is stamped by every delivery. Without it the overlay still annotates locally and SEND reports `NOT ARMED - no craft session listening`. With it, a page whose policy blocks the request reports `BLOCKED BY PAGE - ask Claude to read pins directly`, and the pins wait in local storage under `ca-annotations:<pathname>` for the session to read.
- `__craftAnnotateBaked` is stamped only by a mockup round written to disk. It is the single switch that makes the page hold the event stream open. Raw-tab and dial injections never stamp it.
- `__craftAnnotateContext` is optional and owned by the dial flow: the bare candidate letter string (for example `"B"`), never an object. Each pin copies it verbatim into a `candidate` field.

On a project page the loader line stamps the port itself and never stamps the baked flag or a context. For a raw tab pasted as the fallback, run the stamp and the source in one injection, in that order. A baked page's stamps are the first two lines of the one `ca-overlay` script element that `annotate-run.sh bake` writes; the overlay source follows them in that same element, and no flow writes them by hand.

## The channel protocol

The channel is a per-session listener on `127.0.0.1`. Pages reach it from any origin, including a local file, so it answers CORS preflight and sets an allow-origin header on every response.

| Request | Meaning | Body | Answer |
|---|---|---|---|
| `POST /pins` | replace the working set with exactly this array | JSON array of pin objects | 200 with `{ok, seq, count}` |
| `POST /clear` | void the working set (tombstone) | none | 200 with `{ok, seq, cleared}` |
| `GET /events` | hold a stream open; the listener pushes `event: reload` with `data: reload` when a new round is written | none | `text/event-stream` |
| `GET /overlay.js` | the overlay fence, read from this file on every request | none | 200 `text/javascript` (404 JSON when the fence is missing) |
| `GET /health` | liveness and connection count | none | `{ok, port, clients}` |

A pin object is `{n, text, x, y, selector, nearText, ts, page, box, component}` (`page` is the address without query or hash, `box` the target's rounded rect in document coordinates, `component` the nearest framework component name or null) plus `candidate` when the context stamp is present. `n` is a display label that changes when a pin is deleted; the channel treats the whole array as one atomic set and never merges it with a previous one. The overlay uses only `POST /pins`, `POST /clear` and `GET /events`; `GET /overlay.js` is requested by the loader the flow injects, and `GET /health` exists for the flows, which check it before opening a browser.

## Reading pins back

Whatever flow reads a sent set quotes each `text` as the user's exact words. Never paraphrase it, relabel it, or merge two comments into one.
