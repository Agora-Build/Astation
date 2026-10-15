/* The bridge accepts only locally initiated actions. Host output is always bytes. */
(() => {
  'use strict';
  const post = (op, data = {}) => window.webkit.messageHandlers.terminal.postMessage({ op, ...data });
  let term;
  let fit;
  let displayedStream = '';
  let enabled = false;
  let epoch = '';
  let measureTimer;
  function createTerminal() {
    term = new Terminal({
      allowProposedApi: true, scrollback: 0, cols: 120, rows: 40,
      disableStdin: true, cursorBlink: false, screenReaderMode: true,
      fontFamily: 'Menlo, Monaco, monospace', fontSize: 13, lineHeight: 1.12,
      theme: { background: '#14191d', foreground: '#e5e9ed', cursor: '#5ac5b6', selectionBackground: '#315867' }
    });
    fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.unicode.register(new AtemUnicode());
    term.unicode.activeVersion = 'atem-unicode-width-0.1.14';
    term.open(document.getElementById('terminal'));
  }
  const base64 = bytes => {
    let raw = '';
    for (const byte of bytes) raw += String.fromCharCode(byte);
    return btoa(raw);
  };
  const send = bytes => {
    if (!enabled || bytes.length === 0) return;
    if (bytes.length > 16384) { post('oversizedPaste'); return; }
    post('input', { bytes: base64(bytes), epoch });
  };
  function wireInput() {
    term.onData(data => send(new TextEncoder().encode(data)));
    term.onBinary(data => send(Uint8Array.from(data, character => character.charCodeAt(0))));
    term.attachCustomKeyEventHandler(event => {
      if (event.type !== 'keydown') return true;
      if (event.metaKey && !event.altKey && !event.ctrlKey) {
        if (event.key.toLowerCase() === 'c') {
          if (term.hasSelection()) post('copy', { text: term.getSelection() });
          return false;
        }
        if (event.key.toLowerCase() === 'v') { if (enabled) post('paste', { epoch }); return false; }
        if (event.key.toLowerCase() === 'a') { term.selectAll(); return false; }
      }
      return true;
    });
  }
  createTerminal();
  wireInput();
  // Prevent browser paste from bypassing the native size check and ownership epoch.
  document.addEventListener('paste', event => {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (enabled && event.isTrusted) post('paste', { epoch });
  }, true);
  document.addEventListener('contextmenu', event => event.preventDefault());

  function measure() {
    const size = fit.proposeDimensions();
    if (size) post('size', { rows: size.rows, cols: size.cols });
  }
  new ResizeObserver(() => {
    clearTimeout(measureTimer);
    measureTimer = setTimeout(measure, 120);
  }).observe(document.getElementById('viewport'));

  window.astationTerminal = {
    setControl(value, newEpoch) {
      enabled = Boolean(value);
      epoch = newEpoch;
      term.options.disableStdin = !enabled;
      term.options.cursorBlink = enabled;
      if (enabled) { term.focus(); measure(); }
    },
    applyFrame(frame, token) {
      if (displayedStream !== frame.streamId) {
        // Discard the old emulator and its pending writes across subscriptions.
        term.dispose();
        document.getElementById('terminal').replaceChildren();
        enabled = false;
        epoch = '';
        createTerminal();
        wireInput();
        displayedStream = frame.streamId;
      }
      const raw = atob(frame.bytes);
      const bytes = Uint8Array.from(raw, character => character.charCodeAt(0));
      if (frame.reset) { term.reset(); term.resize(frame.cols, frame.rows); }
      term.write(bytes, () => post('consumed', { token }));
    },
    paste(text, expectedEpoch) {
      if (!enabled || epoch !== expectedEpoch) return;
      // xterm wraps this atomic operation in the CLI's active bracketed-paste mode.
      if (new TextEncoder().encode(text).length + 12 > 16384) { post('oversizedPaste'); return; }
      term.paste(text);
    },
    copySelection() { post('copy', { text: term.getSelection() }); },
    clear() { term.reset(); },
    // Read-only hooks used by native renderer regression tests.
    inspect() {
      return {
        text: Array.from({ length: term.rows }, (_, row) => term.buffer.active.getLine(row).translateToString(true)).join('\n'),
        rows: term.rows, cols: term.cols, unicode: term.unicode.activeVersion,
        scrollback: term.options.scrollback, enabled,
        firstForeground: term.buffer.active.getLine(0).getCell(0).getFgColor()
      };
    }
  };
  post('ready');
  measure();
})();
