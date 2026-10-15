import {
  Conversation,
  activity,
  safeLink,
  markdownBlocks,
  importSessionKey,
  signedFrame,
  verifiedBody,
} from "./chat-core.mjs";

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

function inline(parent, text) {
  const pattern =
    /(`[^`\n]+`|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^\s)]+\)|https?:\/\/[^\s<>]+)/g;
  let start = 0;
  for (const match of text.matchAll(pattern)) {
    parent.append(document.createTextNode(text.slice(start, match.index)));
    const value = match[0];
    if (value.startsWith("`"))
      parent.append(node("code", "", value.slice(1, -1)));
    else if (value.startsWith("**"))
      parent.append(node("strong", "", value.slice(2, -2)));
    else {
      const markdown = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(value);
      const href = safeLink(markdown ? markdown[2] : value);
      if (href) {
        const link = node("a", "", markdown ? markdown[1] : value);
        link.href = href;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        parent.append(link);
      } else parent.append(document.createTextNode(value));
    }
    start = match.index + value.length;
  }
  parent.append(document.createTextNode(text.slice(start)));
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
  const fragment = document.createDocumentFragment();
  const sections = markdownBlocks(text);
  for (const section of sections) {
    if (section.type === "code") {
      const language = section.language;
      const source = section.text;
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
      fragment.append(block);
      continue;
    }
    const lines = section.text.split("\n");
    let paragraph = [];
    let list;
    const flush = () => {
      if (paragraph.length) {
        const p = node("p");
        inline(p, paragraph.join("\n"));
        fragment.append(p);
        paragraph = [];
      }
      list = null;
    };
    for (const line of lines) {
      if (!line.trim()) {
        flush();
        continue;
      }
      const item = /^\s*[-*]\s+(.+)/.exec(line);
      if (item) {
        if (paragraph.length) flush();
        if (!list) {
          list = node("ul");
          fragment.append(list);
        }
        const li = node("li");
        inline(li, item[1]);
        list.append(li);
        continue;
      }
      const heading = /^(#{1,3})\s+(.+)/.exec(line);
      if (heading) {
        flush();
        const h = node(heading[1].length > 1 ? "h3" : "h2");
        inline(h, heading[2]);
        fragment.append(h);
        continue;
      }
      if (line.startsWith("> ")) {
        flush();
        const quote = node("blockquote");
        inline(quote, line.slice(2));
        fragment.append(quote);
        continue;
      }
      list = null;
      paragraph.push(line);
    }
    flush();
  }
  return fragment;
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
      message.role === "user" ? "You" : conversation.context.agentName,
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
  if (message.role === "user") content.append(node("p", "", message.text));
  else content.append(markdown(message.text));
  const footer = node("div", "message-footer");
  if (message.role === "user") {
    const labels = {
      sending: "Sending\u2026",
      delivered: "Delivered",
      unknown: "Delivery unknown",
      failed: "Not delivered",
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
    button.addEventListener("click", () => copy(message.text));
    footer.append(button);
  }
  element.append(meta, content, footer);
  return element;
}

function render() {
  renderScheduled = false;
  const context = conversation.context;
  const timeline = $("timeline");
  const previousScroll = timeline.scrollTop;
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
    firstPrompt?.text.slice(0, 70) || "A new conversation";
  $("empty-state").hidden = conversation.messages.length > 0;
  const existing = new Map(
    Array.from($("messages").children, (child) => [
      `${child.dataset.role}:${child.dataset.messageId}`,
      child,
    ]),
  );
  for (const message of conversation.messages) {
    const version = message.text + "\0" + (message.delivery || "");
    const old = existing.get(`${message.role}:${message.id}`);
    if (old?.renderVersion === version) continue;
    const element = messageElement(message);
    element.renderVersion = version;
    if (old) old.replaceWith(element);
    else $("messages").append(element);
  }
  $("prompt").disabled = !conversation.canSend;
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
  else timeline.scrollTop = previousScroll;
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
      : value.label;
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
    generation: "preview",
  });
  const id = "sample-prompt";
  conversation.addPrompt(
    id,
    "Can you make the agent workspace feel more like a conversation? Keep the terminal one click away.",
  );
  previewEvent("accepted", { requestId: id });
  previewEvent("message", {
    messageId: "sample-reply",
    requestId: id,
    text: 'Absolutely. Here\u2019s a first pass at a quieter workspace, with the conversation at its center.\n\n### A familiar place to build\n- Your prompts sit on the right; agent replies arrive on the left.\n- **Code stays readable**, with syntax colors and a copy button.\n- The activity indicator follows explicit agent events.\n\n```typescript\nconst conversation = {\n  agent: "Claude Code",\n  workspace: "Genie",\n  status: "ready"\n};\n```\n\nThe same layout adapts to a phone. And when you need the full CLI, **Open Terminal** is still right there in Astation.\n\nReference: [Astation on GitHub](https://github.com/Agora-Build/Astation).',
  });
  previewEvent("complete", { requestId: id });
  previewEvent("status", { state: "ready" });
  transport = async (body) => {
    if (body.op !== "submit") return;
    previewEvent("accepted", { requestId: body.requestId });
    previewEvent("status", { state: "working" });
    const text =
      "This is a **preview reply**, so no prompt was sent to a real code agent.\n\nIn a live conversation, your selected Atem will send the agent\u2019s structured reply here. Messages can include `inline code`, code blocks, and safe links.\n\nYour message was:\n> " +
      body.text.replace(/\n/g, "\n> ");
    const chunks = text.match(/[\s\S]{1,35}/g) || [];
    const messageId = crypto.randomUUID();
    const step = () => {
      const chunk = chunks.shift();
      if (chunk) {
        previewEvent("delta", {
          messageId,
          requestId: body.requestId,
          text: chunk,
        });
        previewTimer = setTimeout(step, 45);
      } else {
        previewEvent("complete", { requestId: body.requestId });
        previewEvent("status", { state: "ready" });
      }
    };
    previewTimer = setTimeout(step, 650);
  };
  $("session-description").textContent =
    "This is an interactive preview using sample data. You can send messages to explore the layout; nothing is delivered to a real agent.";
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
        if (typeof event.data !== "string" || event.data.length > 300000)
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
  if (!transport || !conversation.addPrompt(requestId, text)) return;
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
          `${message.role === "user" ? "You" : conversation.context.agentName}:\n${message.text}`,
      )
      .join("\n\n"),
  ),
);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") sidebar(false);
});
window.addEventListener("pagehide", () => clearTimeout(previewTimer));
setInterval(renderActivity, 1000);
if (preview) startPreview();
else connect().catch(fail);
render();
