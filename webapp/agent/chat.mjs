import {
  Conversation,
  activity,
  messageText,
  MAX_FRAME_BYTES,
  importSessionKey,
  signedFrame,
  verifiedBody,
} from "./chat-core.mjs";
import { renderMarkdown } from "./markdown.mjs";

const parser = new globalThis.commonmark.Parser();

const $ = (id) => document.getElementById(id);
const conversation = new Conversation();
const preview = new URLSearchParams(location.search).get("preview") === "1";
let transport;
let followLatest = true;
let renderScheduled = false;
let previewSequence = 0;
let previewTimer;
let toastTimer;

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function toast(text) {
  $("toast").textContent = text;
  $("toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    $("toast").hidden = true;
  }, 2200);
}

async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast("Copied to clipboard");
  } catch {
    toast("Clipboard unavailable. Select the text to copy it.");
  }
}

function highlighted(code, text) {
  const pattern =
    /(\/\/[^\n]*|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:const|let|var|func|fn|function|return|if|else|true|false|null|nil|async|await|pub|use|import|from|export|struct|class|guard|try|throw)\b|\b\d+(?:\.\d+)?\b)/g;
  let start = 0;
  for (const match of text.matchAll(pattern)) {
    code.append(document.createTextNode(text.slice(start, match.index)));
    const value = match[0];
    const type = /^(\/\/|#)/.test(value)
      ? "comment"
      : /^["']/.test(value)
        ? "string"
        : /^\d/.test(value)
          ? "number"
          : "keyword";
    code.append(node("span", `token-${type}`, value));
    start = match.index + value.length;
  }
  code.append(document.createTextNode(text.slice(start)));
}

function markdown(text) {
  return renderMarkdown(text, {
    document,
    parser,
    codeBlock(source, language) {
      const block = node("div", "code-block");
      const header = node("div", "code-header");
      header.append(node("span", "", language));
      const button = node("button", "code-copy", "Copy code");
      button.type = "button";
      button.addEventListener("click", () => copy(source));
      header.append(button);
      const pre = node("pre");
      const code = node("code");
      highlighted(code, source);
      pre.append(code);
      block.append(header, pre);
      return block;
    },
  });
}

function messageElement(message) {
  const element = node("article", "message");
  element.dataset.role = message.role;
  element.dataset.messageId = message.id;
  const meta = node("div", "message-meta");
  meta.append(
    node("span", "message-avatar", message.role === "user" ? "YOU" : "\u2733"),
  );
  meta.append(
    node(
      "strong",
      "",
      message.role === "user"
        ? message.origin === "local"
          ? "You / Terminal"
          : "You"
        : conversation.context.agentName,
    ),
  );
  const time = node(
    "time",
    "",
    new Date(message.at).toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
    }),
  );
  time.dateTime = new Date(message.at).toISOString();
  meta.append(time);
  const content = node("div", "message-content");
  for (const part of message.parts) {
    if (part.kind === "tool") {
      const tool = node("div", "tool-part");
      tool.append(node("strong", "tool-name", part.name));
      if (part.summary) tool.append(node("code", "tool-summary", part.summary));
      content.append(tool);
    } else if (message.role === "user")
      content.append(node("p", "", part.markdown));
    else content.append(markdown(part.markdown));
  }
  const footer = node("div", "message-footer");
  if (message.role === "user") {
    const labels = {
      sending: "Sending\u2026",
      delivered: "Delivered",
      unknown: "Delivery unknown",
      failed: "Not delivered",
      refused: "Refused / check terminal",
      remote: "From chat",
    };
    const status = node(
      "span",
      "message-delivery",
      labels[message.delivery] || "",
    );
    status.dataset.delivery = message.delivery;
    footer.append(status);
  } else {
    const button = node("button", "", "Copy message");
    button.type = "button";
    button.addEventListener("click", () => copy(messageText(message)));
    footer.append(button);
  }
  if (message.outcome)
    footer.append(
      node(
        "span",
        "turn-outcome",
        message.outcome === "interrupted" ? "Interrupted" : "Turn finished",
      ),
    );
  element.append(meta, content, footer);
  return element;
}

function render() {
  renderScheduled = false;
  const context = conversation.context;
  const timeline = $("timeline");
  const previousScroll = timeline.scrollTop;
  const anchor = [...$("messages").children].find(
    (child) =>
      child.getBoundingClientRect().bottom >
      timeline.getBoundingClientRect().top,
  );
  const anchorTop = anchor?.getBoundingClientRect().top;
  const anchorId = anchor?.dataset.messageId;
  $("agent-name").textContent = context.agentName;
  $("agent-location").textContent = `${context.hostname} / Remote coding agent`;
  $("composer-agent").textContent = context.agentName;
  $("device-name").textContent = context.hostname;
  $("device-connection").textContent = preview
    ? "Sample workspace"
    : context.connected
      ? "Connected to Astation"
      : "Waiting for connection";
  $("conversation-subtitle").textContent =
    `${context.agentName} / ${context.hostname}`;
  const firstPrompt = conversation.messages.find(
    (message) => message.role === "user",
  );
  $("conversation-title").textContent =
    (firstPrompt ? messageText(firstPrompt).slice(0, 70) : "") ||
    "A new conversation";
  $("empty-state").hidden = conversation.messages.length > 0;
  const existing = new Map(
    Array.from($("messages").children, (child) => [
      `${child.dataset.role}:${child.dataset.messageId}`,
      child,
    ]),
  );
  let position = 0;
  for (const message of conversation.messages) {
    const version = JSON.stringify([
      message.parts,
      message.delivery,
      message.outcome,
      message.origin,
      message.at,
    ]);
    const old = existing.get(`${message.role}:${message.id}`);
    existing.delete(`${message.role}:${message.id}`);
    const element =
      old?.renderVersion === version ? old : messageElement(message);
    element.renderVersion = version;
    if (old && old !== element) old.replaceWith(element);
    if ($("messages").children[position] !== element)
      $("messages").insertBefore(
        element,
        $("messages").children[position] || null,
      );
    position++;
  }
  for (const old of existing.values()) old.remove();
  $("earlier-messages").hidden =
    !conversation.oldestMessageId || !context.canReopen;
  $("earlier-messages").disabled = conversation.opening;
  $("reopen-chat").hidden =
    !context.canReopen || (!conversation.closed && context.enabled);
  // Keep a draft editable while the agent works; only submission requires Ready.
  $("prompt").disabled = !context.supported || !context.connected;
  $("send").disabled = !conversation.canSend || !$("prompt").value.trim();
  $("connection-notice").textContent = conversation.notice;
  $("connection-notice").hidden = !conversation.notice;
  $("composer-note").textContent = preview
    ? "Interactive preview. These messages never reach a real agent."
    : !context.supported
      ? "Structured chat requires support from your Atem agent."
      : conversation.activeRequest
        ? "Waiting for the agent. Permission prompts remain in Open Terminal."
        : "Messages stay in this tab. Your terminal is always available in Astation.";
  renderActivity();
  if (followLatest) timeline.scrollTop = timeline.scrollHeight;
  else {
    const restored = [...$("messages").children].find(
      (child) => child.dataset.messageId === anchorId,
    );
    timeline.scrollTop =
      restored && anchorTop !== undefined
        ? previousScroll + restored.getBoundingClientRect().top - anchorTop
        : previousScroll;
  }
  $("jump-latest").hidden = followLatest;
}

function scheduleRender() {
  if (!renderScheduled) {
    renderScheduled = true;
    requestAnimationFrame(render);
  }
}

function renderActivity() {
  const value = activity(
    conversation.state,
    conversation.activityAt,
    conversation.context.connected,
  );
  if (
    conversation.context.supported === false &&
    conversation.context.connected
  )
    value.label = "Chat unavailable";
  $("activity").dataset.state = value.state;
  $("activity-label").textContent = value.label;
  $("activity").title =
    value.state === "unknown"
      ? "No recent semantic activity report is available."
      : [
          value.label,
          conversation.detail,
          conversation.since === null
            ? ""
            : `Since ${new Date(conversation.since).toLocaleString()}`,
        ]
          .filter(Boolean)
          .join(" / ");
  $("agent-progress").hidden = !["working", "waiting"].includes(value.state);
  $("agent-progress-label").textContent =
    value.state === "waiting"
      ? "Your agent needs input. Check its terminal."
      : `${conversation.context.agentName} is working`;
}

function receive(body) {
  conversation.receive(body);
  scheduleRender();
}

function previewEvent(op, data = {}) {
  receive({
    op: "event",
    event: {
      v: 1,
      op,
      generation: "preview",
      sequence: ++previewSequence,
      ...data,
    },
  });
}

function startPreview() {
  $("mode-banner").hidden = false;
  $("mode-banner").textContent =
    "Interactive preview / Sample conversation / No agent is connected";
  receive({
    op: "context",
    agentName: "Claude Code",
    hostname: "Genie",
    connected: true,
    supported: true,
    enabled: true,
    opening: true,
  });
  receive({
    op: "event",
    event: {
      v: 1,
      op: "opened",
      generation: "preview",
      sequence: 0,
      status: { state: "ready", since: Date.now() },
    },
  });
  const id = "sample-prompt";
  conversation.addPrompt(
    id,
    "Can you make the agent workspace feel more like a conversation? Keep the terminal one click away.",
  );
  const message = (requestId, text, reply) => {
    const turnId = `turn-${requestId}`;
    previewEvent("accepted", { requestId });
    previewEvent("message", {
      messageId: `user-${requestId}`,
      role: "user",
      origin: "remote",
      turnId,
      requestId,
      createdAt: Date.now(),
      parts: [{ id: "prompt", kind: "text", markdown: text }],
    });
    previewEvent("message", {
      messageId: `reply-${requestId}`,
      role: "assistant",
      turnId,
      requestId,
      createdAt: Date.now(),
      parts: [{ id: "text", kind: "text", markdown: reply }],
    });
    previewEvent("delta", {
      messageId: `reply-${requestId}`,
      part: {
        id: "tool",
        kind: "tool",
        name: "Read",
        summary: "webapp/agent/chat.mjs",
      },
    });
    previewEvent("complete", { turnId, requestId, outcome: "done" });
    previewEvent("status", { state: "ready", since: Date.now() });
  };
  message(
    id,
    messageText(conversation.messages[0]),
    'Here is a first pass at a quieter workspace.\n\n### A familiar place to build\n- Prompts sit on the right; agent replies arrive on the left.\n- **Code stays readable**, with syntax colors and a copy button.\n- Activity follows explicit agent events.\n\n```typescript\nconst conversation = {\n  agent: "Claude Code",\n  status: "ready"\n};\n```\n\n[View Astation on GitHub](https://github.com/Agora-Build/Astation).',
  );
  transport = async (body) => {
    if (body.op !== "submit") return;
    previewEvent("status", { state: "working", since: Date.now() });
    previewTimer = setTimeout(
      () =>
        message(
          body.requestId,
          body.text,
          "This is a **preview reply**. Nothing was sent to a real agent.\n\nYour message was:\n> " +
            body.text.replace(/\n/g, "\n> "),
        ),
      650,
    );
  };
  $("session-description").textContent =
    "This interactive preview uses sample data. Nothing is delivered to a real agent.";
}

async function connect() {
  const params = new URLSearchParams(location.hash.slice(1));
  const sessionId = params.get("session");
  const stationId = params.get("station");
  const secret = params.get("key");
  if (!sessionId || !stationId || !secret) {
    conversation.notice =
      "Open Connections in Astation, choose an agent, then click Open in Browser.";
    $("mode-banner").hidden = false;
    $("mode-banner").append(
      document.createTextNode("Want to look around first? "),
    );
    const link = node("a", "", "Try the interactive preview");
    link.href = "?preview=1";
    $("mode-banner").append(link);
    scheduleRender();
    return;
  }
  if (!crypto.subtle)
    throw new Error("Open this page over HTTPS to authenticate the session.");
  const key = await importSessionKey(secret);
  const nonce = crypto.randomUUID();
  let sequence = 0;
  let receivedSequence = 0;
  let lastReceived = Date.now();
  let sendQueue = Promise.resolve();
  let receiveQueue = Promise.resolve();
  const url = new URL("../ws", location.href);
  url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
  url.hash = "";
  url.search = "";
  url.searchParams.set("role", "atem");
  url.searchParams.set("code", stationId);
  url.searchParams.set("atem_id", `browser-${sessionId}`);
  const socket = new WebSocket(url);
  transport = (body) => {
    // Serialize asynchronous MAC operations so fast sends preserve sequence order.
    const operation = sendQueue.then(async () => {
      if (socket.readyState !== WebSocket.OPEN)
        throw new Error(
          "The browser connection is closed. Reopen this agent from Astation.",
        );
      socket.send(
        JSON.stringify(
          await signedFrame(key, sessionId, nonce, ++sequence, body),
        ),
      );
    });
    sendQueue = operation.catch(() => {});
    return operation;
  };
  socket.addEventListener("open", () => {
    transport({ op: "open" }).catch(fail);
  });
  socket.addEventListener("message", (event) => {
    receiveQueue = receiveQueue
      .then(async () => {
        if (
          typeof event.data !== "string" ||
          event.data.length > MAX_FRAME_BYTES + 2048
        )
          return;
        let frame;
        try {
          frame = JSON.parse(event.data);
        } catch {
          return;
        }
        if (frame.type !== "browserChat") return;
        const body = await verifiedBody(
          key,
          frame.data,
          sessionId,
          nonce,
          receivedSequence,
        );
        if (!body) return;
        if (frame.data.sequence !== receivedSequence + 1) {
          fail(
            new Error(
              "Some session messages are missing. Reopen this agent from Astation.",
            ),
          );
          socket.close();
          return;
        }
        receivedSequence = frame.data.sequence;
        lastReceived = Date.now();
        receive(body);
      })
      .catch(fail);
  });
  socket.addEventListener("close", () => {
    conversation.disconnect();
    scheduleRender();
  });
  socket.addEventListener("error", () =>
    fail(
      new Error(
        "Could not connect to the relay. Reopen the session from Astation.",
      ),
    ),
  );
  const heartbeat = setInterval(() => {
    if (socket.readyState !== WebSocket.OPEN) return;
    if (Date.now() - lastReceived > 45000) {
      fail(
        new Error(
          "Astation is not responding. Reopen this agent after it reconnects.",
        ),
      );
      socket.close();
      return;
    }
    transport({ op: "refresh" }).catch(fail);
  }, 15000);
  socket.addEventListener("close", () => clearInterval(heartbeat), {
    once: true,
  });
  $("session-description").textContent =
    "This browser session was opened on your Mac for one selected agent. It expires after one hour. The session key stays in this page\u2019s URL fragment and is not sent as a URL query to the relay.";
  conversation.notice = "Connecting to Astation\u2026";
  scheduleRender();
}

function fail(error) {
  conversation.disconnect(
    error.message || "The connection could not be established.",
  );
  scheduleRender();
}

$("composer").addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = $("prompt").value;
  const requestId = crypto.randomUUID();
  if (!transport || !conversation.addPrompt(requestId, text)) {
    scheduleRender();
    return;
  }
  $("prompt").value = "";
  $("prompt").style.height = "";
  followLatest = true;
  scheduleRender();
  try {
    await transport({ op: "submit", requestId, text });
  } catch (error) {
    conversation.updateDelivery(requestId, "unknown");
    fail(error);
  }
});
$("prompt").addEventListener("input", () => {
  $("prompt").style.height = "auto";
  $("prompt").style.height = `${Math.min($("prompt").scrollHeight, 180)}px`;
  $("send").disabled = !conversation.canSend || !$("prompt").value.trim();
});
$("prompt").addEventListener("keydown", (event) => {
  if (
    event.key === "Enter" &&
    !event.shiftKey &&
    !event.isComposing &&
    !matchMedia("(pointer: coarse)").matches
  ) {
    event.preventDefault();
    $("composer").requestSubmit();
  }
});
$("timeline").addEventListener(
  "scroll",
  () => {
    const timeline = $("timeline");
    followLatest =
      timeline.scrollHeight - timeline.scrollTop - timeline.clientHeight < 65;
    $("jump-latest").hidden = followLatest;
  },
  { passive: true },
);
$("jump-latest").addEventListener("click", () => {
  followLatest = true;
  $("timeline").scrollTop = $("timeline").scrollHeight;
  $("jump-latest").hidden = true;
});
function sidebar(open) {
  document.querySelector(".workspace").classList.toggle("sidebar-open", open);
  $("sidebar-backdrop").hidden = !open;
  $("mobile-menu").setAttribute("aria-expanded", String(open));
}
$("mobile-menu").addEventListener("click", () => sidebar(true));
$("sidebar-backdrop").addEventListener("click", () => sidebar(false));
$("conversation").addEventListener("click", () => {
  sidebar(false);
  if (conversation.canSend) $("prompt").focus();
});
$("session-details").addEventListener("click", () => {
  sidebar(false);
  $("details-dialog").showModal();
});
$("copy-conversation").addEventListener("click", () =>
  copy(
    conversation.messages
      .map(
        (message) =>
          `${message.role === "user" ? "You" : conversation.context.agentName}:\n${messageText(message)}`,
      )
      .join("\n\n"),
  ),
);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") sidebar(false);
});
window.addEventListener("pagehide", () => clearTimeout(previewTimer));
$("earlier-messages").addEventListener("click", () => {
  const before = conversation.oldestMessageId;
  if (!before || !transport) return;
  followLatest = false;
  transport({ op: "history", before }).catch(fail);
});
$("reopen-chat").addEventListener("click", () =>
  transport?.({ op: "reopen" }).catch(fail),
);
setInterval(() => {
  renderActivity();
  $("send").disabled = !conversation.canSend || !$("prompt").value.trim();
}, 1000);
if (preview) startPreview();
else connect().catch(fail);
render();
