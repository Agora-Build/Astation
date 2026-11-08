'use strict';

// A local design prototype. It deliberately has no auth, socket or command transport.
const app = document.querySelector('#app');
const preview = document.querySelector('#preview');
const icons = {
  arrow: '<path d="m5 12 7-7 7 7M12 5v14"/>',
  back: '<path d="m14 6-6 6 6 6"/>',
  right: '<path d="m9 6 6 6-6 6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  chat: '<path d="M5 4h14v12H9l-4 4V4Z"/><path d="M9 8h6M9 12h4"/>',
  host: '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8m-4-4v4"/>',
  laptop: '<path d="M5 5h14v12H5zM2 20h20"/>',
  terminal: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3m6 0h4"/>',
  phone: '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 5h4m-3 14h2"/>',
  inbox: '<path d="M5 5h14l3 13H2L5 5Z"/><path d="M3 13h5l2 3h4l2-3h5"/>',
  account: '<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',
  shield: '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6l8-3Z"/><path d="m8 12 3 3 5-6"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  copy: '<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M16 8V3H3v13h5"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  bell: '<path d="M6 9a6 6 0 0 1 12 0c0 7 3 7 3 9H3c0-2 3-2 3-9ZM9 21h6"/>',
  external: '<path d="M14 3h7v7M21 3 10 14M11 3H3v18h18v-8"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7v1"/>',
  key: '<circle cx="8" cy="8" r="5"/><path d="m12 12 9 9m-5-5 3-3m-6 0 3-3"/>',
  globe: '<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
  mic: '<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8"/>',
  fingerprint: '<path d="M7 18c2-3 0-6 2-8 3-3 7 0 6 3-1 4 1 5 1 6M5 15c0-4-1-9 5-10 6-1 10 4 8 9M10 20c1-3 2-4 1-7M4 10c0-4 3-7 7-8m3 0c5 1 8 5 7 11"/>',
  github: '<path fill="currentColor" stroke="none" d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.86c-2.78.6-3.37-1.18-3.37-1.18-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.61.07-.61 1 .07 1.53 1.03 1.53 1.03.89 1.53 2.34 1.09 2.91.83.09-.65.35-1.09.64-1.34-2.22-.25-4.55-1.11-4.55-4.95 0-1.09.39-1.99 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.6 9.6 0 0 1 5 0c1.91-1.29 2.75-1.02 2.75-1.02.55 1.38.2 2.4.1 2.65.64.69 1.03 1.59 1.03 2.68 0 3.85-2.34 4.69-4.57 4.94.36.31.68.92.68 1.85v2.76c0 .27.18.58.69.48A10 10 0 0 0 12 2Z"/>',
};
const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.chat}</svg>`;
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const brand = () => '<div class="brand"><span class="brand-mark" aria-hidden="true">a</span>astation</div>';
const action = (label, name, css = 'primary', symbol = '') => `<button type="button" class="${css}" data-action="${name}">${symbol ? icon(symbol) : ''}${label}</button>`;
const iconButton = (name, label, symbol) => `<button type="button" class="icon-button" data-action="${name}" aria-label="${label}">${icon(symbol)}</button>`;

const hosts = [
  {id:'genie', name:'Genie', short:'dc1649f', full:'Genie-dc1649f-956631ec', system:'Linux', online:true, agents:2, work:'1 ready · 1 working'},
  {id:'studio', name:'Studio', short:'a18f03c', full:'Studio-a18f03c-example', system:'macOS', online:true, agents:1, work:'1 waiting for approval'},
  {id:'workstation', name:'Workstation', short:'83c2e9a', full:'Workstation-83c2e9a-example', system:'Linux', online:false, agents:0, work:'Last seen 2 hours ago'},
];
const previewNow = Date.now();
const agents = [
  {id:'codex', host:'genie', name:'Astation mobile', provider:'Codex', activity:'Waiting', state:'waiting', project:'Agora.Build / Astation', updatedAt:previewNow - 120000, lastMessage:'The layout is in place. Ready to run the mobile tests.'},
  {id:'claude', host:'genie', name:'Release pipeline', provider:'Claude', activity:'Working', state:'working', project:'Agora.Build / Atem', updatedAt:previewNow - 2700000, lastMessage:'Checking the release workflow and deployment steps.'},
  {id:'studio-codex', host:'studio', name:'Settings cleanup', provider:'Codex', activity:'Waiting', state:'waiting', project:'Agora.Build / Astation', updatedAt:previewNow - 720000, lastMessage:'The settings changes are ready for a test run.'},
];
const approvalRequests = [
  {id:'mobile-tests', agent:'codex', summary:'Run the mobile layout tests', command:'flutter test test/layout_test.dart', outcome:null, ruleActive:false},
  {id:'settings-tests', agent:'studio-codex', summary:'Run the settings tests', command:'swift test --filter SettingsTests', outcome:null, ruleActive:false},
];
const profiles = [
  {id:'backend-codex', name:'Backend Codex', provider:'Codex', project:'Agora.Build / Astation'},
  {id:'project-claude', name:'Project Claude', provider:'Claude', project:'Agora.Build / Atem'},
];
const welcomeFeatures = [
  {id:'agents', name:'Agent chat'},
  {id:'atem', name:'Atem', url:'https://github.com/Agora-Build/Atem'},
  {id:'vox', name:'Vox Realtime', url:'https://vox.agora.build'},
  {id:'dictation', name:'Astation Dictation'},
  {id:'approvals', name:'Approvals anywhere'},
];
const state = {screen:'login', route:'chats', chatOrigin:'chats', host:'genie', agent:'codex', sheet:null, trusted:true,
  profile:'backend-codex', approvalIndex:0, activeApprovalId:null, drafts:{}, messages:{}, expandedTools:false,
  toast:null, launching:false, returnAction:null, deferred:null, controllerElsewhere:false, switcher:null, featureIndex:0};
let toastTimer;
let launchTimer;
let conversationHold;
let cardSwipe;
let suppressReleaseClickUntil = 0;
const selectedHost = () => hosts.find(host => host.id === state.host) || hosts[0];
const selectedAgent = () => agents.find(agent => agent.id === state.agent) || agents[0];
const symbol = provider => `<span class="agent-symbol ${provider.toLowerCase()}" aria-hidden="true">${provider === 'Claude' ? '✳' : '&gt;_'}</span>`;
const status = (text, kind = 'ready') => `<span class="status-label"><span class="dot ${kind}"></span>${text}</span>`;
const pendingApprovals = () => approvalRequests.filter(request => !request.outcome);
const approvalForAgent = (agentId = state.agent) => approvalRequests.find(request => request.agent === agentId);
const recentAgents = () => [...agents].sort((a,b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id));
const shortTime = timestamp => {
  const minutes = Math.floor((Date.now() - timestamp) / 60000);
  if (minutes < 1) return 'Now';
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 1440) return `${Math.floor(minutes / 60)}h`;
  return new Intl.DateTimeFormat('en',{month:'short',day:'numeric'}).format(timestamp);
};

function renderLogin() {
  return `<section class="login">${brand()}
    <div class="login-copy"><div class="eyebrow">A LITTLE CLOSER TO YOUR AGENTS</div><h1>Your agents.<br>Within reach.</h1><p class="login-intro">Keep building. Anywhere. Your way.</p></div>
    ${renderWelcomeFeatures()}
    <div class="login-actions">${action('Continue with Agora.Build','sign-in','primary full','external')}<p class="small-note">Sign in or create an account with GitHub<br>or your Agora.Build account.</p></div>
    <div class="login-footer">YOUR MACHINES. YOUR AGENTS. YOUR CONTEXT.</div>
  </section>`;
}

function renderWelcomeFeature(feature) {
  if (feature.id === 'atem') return `<div class="visual-top"><span class="feature-symbol">${icon('terminal')}</span><div><strong>Atem</strong><p>YOUR AGENTS. YOUR MACHINE.</p></div></div><div class="atem-command" aria-hidden="true"><span>$</span> atem agent launch codex<span class="atem-cursor"></span></div><p class="feature-copy">A terminal that connects builders, AI agents and more.</p><div class="visual-bottom"><span>Explore Atem</span>${icon('external')}</div>`;
  if (feature.id === 'vox') return `<div class="visual-top"><span class="feature-symbol"><img src="assets/vox-mark.png" alt="" width="24" height="24" draggable="false"></span><div><strong>Vox Realtime</strong><p>VOICE AGENT BENCHMARKS</p></div></div><div class="feature-wave" aria-hidden="true">${[10,18,30,21,38,29,15,24,34,18,27,37,22,12,26,34,17,8].map(height => `<i style="height:${height}px"></i>`).join('')}</div><p class="feature-copy">Compare voice agents on response speed, interruptions, and conversation success.</p><div class="visual-bottom"><span>Explore Vox Realtime</span>${icon('external')}</div>`;
  if (feature.id === 'dictation') return `<div class="visual-top"><span class="feature-symbol">${icon('mic')}</span><div><strong>Astation Dictation</strong><p>YOUR VOICE, WRITTEN.</p></div></div><div class="dictation-example">“Turn this thought into<br><strong>my next prompt.</strong>”<span class="dictation-caret" aria-hidden="true"></span></div><p class="feature-copy">Push-to-talk or hands-free on your Mac.</p><div class="visual-bottom"><span>SPEAK IT. KEEP BUILDING.</span><span class="feature-spotlight">FEATURE SPOTLIGHT</span></div>`;
  if (feature.id === 'approvals') return `<div class="visual-top"><span class="feature-symbol">${icon('shield')}</span><div><strong>Approvals anywhere</strong><p>A LITTLE REVIEW. A LOT OF CONFIDENCE.</p></div></div><p class="feature-message">Know what runs.<br><strong>Give the next step your go-ahead.</strong></p><div class="feature-approval-demo" aria-hidden="true"><span>Run project tests</span><span>${icon('check')}Allow once</span></div><div class="visual-bottom"><span>REVIEW IN CONTEXT.</span><span class="feature-spotlight">FEATURE SPOTLIGHT</span></div>`;
  return `<div class="visual-top"><span class="feature-symbol">${icon('phone')}</span><div><strong>Astation mobile</strong><p>Codex on Genie</p></div>${status('Ready')}</div><p class="visual-message">The layout is in place.<br><strong>Here’s what I’d build next.</strong></p><div class="visual-bottom"><span>ONE WORKSPACE. EVERY DEVICE.</span>${icon('chat')}</div>`;
}

function renderWelcomeFeatures() {
  const feature = welcomeFeatures[state.featureIndex];
  const tag = feature.url ? 'a' : 'article';
  const link = feature.url ? `href="${feature.url}" target="_blank" rel="noopener noreferrer" draggable="false" aria-label="Explore ${feature.name} (opens in browser)"` : '';
  return `<section class="welcome-carousel" role="region" aria-roledescription="carousel" aria-label="Featured products and features"><div class="feature-stage" tabindex="0" aria-label="Featured card. Use left and right arrow keys to switch."><div role="group" aria-roledescription="slide" aria-label="${state.featureIndex + 1} of ${welcomeFeatures.length}: ${feature.name}"><${tag} class="feature-card feature-${feature.id}" ${link}>${renderWelcomeFeature(feature)}</${tag}></div></div><div class="feature-controls">${iconButton('previous-feature','Previous featured card','back')}<div class="feature-pagination" aria-label="Choose a featured card">${welcomeFeatures.map((item,index) => `<button type="button" class="feature-dot" data-action="select-feature" data-feature-index="${index}" aria-label="Show ${item.name}" aria-pressed="${index === state.featureIndex}"><span></span></button>`).join('')}</div>${iconButton('next-feature','Next featured card','right')}</div><p class="feature-position" aria-live="polite">${feature.name}<span aria-hidden="true"> · </span><span>${state.featureIndex + 1} / ${welcomeFeatures.length}</span></p></section>`;
}

function selectWelcomeFeature(index) {
  const carousel = app.querySelector('.welcome-carousel');
  if (!carousel) return;
  const focused = document.activeElement;
  const hadFocus = carousel.contains(focused);
  const focusedAction = focused?.dataset.action;
  state.featureIndex = (index + welcomeFeatures.length) % welcomeFeatures.length;
  // Update only the carousel so switching cards keeps sign-in and scroll stable.
  carousel.outerHTML = renderWelcomeFeatures();
  if (hadFocus) {
    const target = focusedAction === 'select-feature' ? app.querySelector('.feature-dot[aria-pressed="true"]') : focusedAction ? app.querySelector(`[data-action="${focusedAction}"]`) : app.querySelector('.feature-stage');
    target?.focus({preventScroll:true});
  }
}

function renderApprovalPreview(request) {
  const agent = agents.find(item => item.id === request.agent);
  const host = hosts.find(item => item.id === agent.host);
  return `<article class="home-approval-card" data-approval="${request.id}"><div class="home-approval-agent">${symbol(agent.provider)}<span><strong>${esc(agent.name)}</strong><span>${agent.provider} on ${host.name} · ${host.short}</span></span>${icon('shield')}</div><h3>${esc(request.summary)}</h3><div class="approval-command">${esc(request.command)}</div><button class="primary" data-action="review-approval" data-approval="${request.id}">Review request ${icon('right')}</button></article>`;
}

function renderChats() {
  const pending = pendingApprovals();
  const index = state.approvalIndex % (pending.length || 1);
  const recent = recentAgents();
  return `<div class="master-heading"><h1>Chats</h1>${iconButton('instances','Find or create an agent','plus')}</div><p class="master-lead">Pick up where you left off.</p>
    ${pending.length ? `<section class="home-approvals" aria-label="Pending approvals"><div class="home-section-heading"><h2>NEEDS YOUR APPROVAL</h2><span class="approval-total">${pending.length}</span></div><div class="approval-deck" aria-label="Approval ${index + 1} of ${pending.length}">${pending.length > 2 ? '<div class="approval-stack-back back-two" aria-hidden="true"></div>' : ''}${pending.length > 1 ? '<div class="approval-stack-back" aria-hidden="true"></div>' : ''}${renderApprovalPreview(pending[index])}</div>${pending.length > 1 ? `<div class="approval-deck-controls">${iconButton('previous-approval','Previous approval','back')}<span aria-live="polite">${index + 1} of ${pending.length}</span>${iconButton('next-approval','Next approval','right')}<button class="text-button" data-action="all-approvals">Show all ${icon('right')}</button></div>` : ''}</section>` : `<div class="approvals-clear">${icon('check')}No approvals waiting</div>`}
    <section class="recent-conversations" aria-label="Latest chats"><div class="home-section-heading"><h2>LATEST CHATS</h2><span>${recent.length.toString().padStart(2,'0')}</span></div>${recent.length ? `<div class="recent-chat-list">${recent.map(agent => {
      const host = hosts.find(item => item.id === agent.host);
      return `<button class="recent-chat-row ${state.route === 'chat' && state.agent === agent.id ? 'selected' : ''}" data-action="open-recent-chat" data-agent="${agent.id}">${symbol(agent.provider)}<span class="recent-chat-copy"><strong>${esc(agent.name)}</strong><span class="recent-chat-preview">${esc(agent.lastMessage)}</span><span class="recent-chat-meta">${agent.provider} · ${host.name} <span class="recent-host-id">${host.short}</span></span>${status(agent.activity,agent.state)}</span><time datetime="${new Date(agent.updatedAt).toISOString()}" title="${new Date(agent.updatedAt).toLocaleString()}">${shortTime(agent.updatedAt)}</time></button>`;
    }).join('')}</div>` : `<div class="no-chats"><p>Your conversations will appear here.</p>${action('Find an agent','instances','secondary full','host')}</div>`}</section>`;
}

function renderHosts() {
  return `<div class="master-heading"><h1>Your agents</h1>${iconButton('account','Open account','account')}</div><p class="master-lead">Choose a machine to find your agents.</p>
    <label class="search"><span class="sr-only">Find an Atem</span>${icon('search')}<input id="host-search" type="search" placeholder="Find a machine or ID" autocomplete="off"></label>
    <div class="list-heading">ONLINE <span>02</span></div><div id="host-list">${hosts.map(host => renderHostCard(host)).join('')}</div>
    <div class="workspace-foot">${icon('shield')}<span>Each device connects independently.<br>Your Mac can stay offline.</span></div>`;
}

function renderHostCard(host) {
  const hostAgents = agents.filter(agent => agent.host === host.id);
  const counts = new Map();
  for (const agent of hostAgents) counts.set(agent.activity,(counts.get(agent.activity) || 0) + 1);
  const summary = host.online ? [...counts].map(([activity,count]) => `${count} ${activity.toLowerCase()}`).join(' · ') || 'No agents running' : host.work;
  return `<section class="host-card ${host.online ? '' : 'host-offline'}" data-host-card="${host.id}">
    <div class="host-top"><span class="host-icon">${icon(host.system === 'macOS' ? 'laptop' : 'host')}</span><div class="host-title"><h2>${host.name}<span class="pill">${host.short}</span></h2><p>${host.system} · ${host.online ? `${hostAgents.length} agents` : 'Offline'}</p></div><span class="dot ${host.online ? '' : 'offline'}" role="img" aria-label="${host.online ? 'Online' : 'Offline'}"></span></div>
    <div class="host-summary">${host.online ? '<strong>●</strong>' : ''}<span>${summary}</span></div>
    <div class="host-actions"><button class="primary" data-action="open-host" data-host="${host.id}">View agents ${icon('right')}</button><button class="secondary" data-action="new-agent" data-host="${host.id}">${icon('plus')}New agent</button></div>
  </section>`;
}

function renderAgentList() {
  const host = selectedHost();
  return `<div class="back-row"><button data-action="instances">${icon('back')}All agents</button></div><div class="master-heading"><h1>${host.name}</h1>${status('Online')}</div><div class="host-meta"><span class="mono">${host.short}</span><span class="muted">·</span><span class="small-note">${host.system}</span></div>
    <div class="list-heading">AGENTS <span>${agents.filter(agent => agent.host === host.id).length.toString().padStart(2,'0')}</span></div>
    ${agents.filter(agent => agent.host === host.id).map(agent => `<button data-action="open-agent" data-agent="${agent.id}" class="agent-row ${state.route === 'chat' && state.agent === agent.id ? 'selected' : ''}">${symbol(agent.provider)}<span class="agent-row-main"><strong>${agent.name}</strong><p>${agent.provider} · ${agent.project.split(' / ')[1]}</p>${status(agent.activity,agent.state)}</span>${icon('right')}</button>`).join('')}
    <button class="new-agent-entry" data-action="new-agent" data-host="${host.id}">${icon('plus')}New agent on ${host.name}</button>
    <div class="workspace-foot">${icon('shield')}<span>${state.trusted ? 'This device has verified access.' : 'Approve this device to operate an agent.'}</span></div>`;
}

function renderEmpty() {
  return `<div class="empty-conversation"><div class="empty-orbit">${icon('chat')}</div><span class="eyebrow">YOUR WORK, STILL IN REACH</span><h2>A conversation, wherever you are.</h2><p>Choose an agent to continue its conversation, or start a new one on your Atem.</p></div>`;
}

function renderChat() {
  const agent = selectedAgent();
  const host = hosts.find(item => item.id === agent.host);
  return `<section class="chat" aria-label="Agent conversation"><header class="chat-header"><button class="icon-button chat-back" data-action="back-from-chat" aria-label="Back to ${state.chatOrigin === 'chats' ? 'chats' : 'agents'}">${icon('back')}</button>${symbol(agent.provider)}<button class="chat-heading conversation-trigger" data-action="switch-conversation" data-switcher-trigger="header" aria-label="Switch conversation, current: ${esc(agent.name)}" aria-haspopup="dialog" aria-expanded="${!!state.switcher}"><span class="chat-title">${agent.name}</span><span class="chat-subtitle">${agent.provider} on ${host.name} · ${host.short}</span></button>${status(agent.activity,agent.state)}${iconButton('details','Conversation details','more')}</header>
    <div class="timeline" id="timeline" tabindex="0" aria-label="Conversation history"><div class="day-label">TODAY · A SPACE TO BUILD SOMETHING</div>
      <div class="message user">Check the mobile layout. What should we build next?</div>
      <article class="message"><div class="message-role"><span class="mini-avatar">${agent.provider === 'Claude' ? '✳' : '&gt;_'}</span>${agent.provider.toUpperCase()}</div>
      <p>The layout is in place. I’d start with <strong>one complete conversation flow</strong>, then expand to the other devices.</p>
      <button class="tool-line" data-action="toggle-tools" aria-expanded="${state.expandedTools}">${icon('check')}Read 4 files ${icon('right')}</button>${state.expandedTools ? '<div class="tool-files">lib/workspace.dart<br>lib/conversation.dart<br>lib/approvals.dart<br>test/layout_test.dart</div>' : ''}
      <h2>Here’s what I’d build next</h2><ul><li><strong>Pick an Atem.</strong> Keep the host and agent visible.</li><li><strong>Continue the chat.</strong> Preserve paragraphs, code and links.</li><li><strong>Approve in context.</strong> See exactly what the agent wants to run.</li></ul>
      <p>I’ll check the layouts with:</p><div class="code-block"><div class="code-head"><span>SHELL</span><button data-action="copy-code">${icon('copy')}Copy</button></div><pre><span class="code-green">flutter</span> test test/layout_test.dart</pre></div>
      ${renderApprovalCard()}
      <p>The same workspace adapts to each screen:</p><div class="table-wrap"><table><thead><tr><th>Device</th><th>Workspace</th></tr></thead><tbody><tr><td>Phone</td><td>One focused conversation</td></tr><tr><td>Tablet</td><td>Agent list + conversation</td></tr><tr><td>Duo / foldable</td><td>A pane on each usable display</td></tr></tbody></table></div>
      <p>See the <a href="https://docs.flutter.dev/ui/adaptive-responsive" data-action="inspect-link">adaptive layout guide</a> for the next pass.</p><div class="message-foot"><span>Just now</span><span>Completed</span><button data-action="copy-reply" aria-label="Copy reply">${icon('copy')}</button></div></article>
      ${(state.messages[agent.id] || []).map(text => `<div class="message user">${esc(text)}</div><article class="message"><div class="message-role"><span class="mini-avatar">&gt;_</span>${agent.provider.toUpperCase()}</div><p>This is a design preview. Your message stays in this page; no agent command was sent.</p><div class="message-foot"><span>Preview only</span></div></article>`).join('')}
    </div>
    <form id="composer-form" class="composer-wrap"><div class="composer"><label class="sr-only" for="prompt">Message ${agent.provider}</label><textarea id="prompt" data-agent="${agent.id}" rows="2" placeholder="Message ${agent.provider}...">${esc(state.drafts[agent.id] || '')}</textarea><div class="composer-bottom"><span class="composer-context">${icon('lock')}${host.name} · ${agent.project.split(' / ')[1]}</span><button class="send-button" aria-label="Send message" type="submit">${icon('arrow')}</button></div></div><p class="composer-note">${state.controllerElsewhere ? 'Another device currently controls this agent.' : 'You stay in the same agent session.'}</p></form>
  </section>`;
}

function renderApprovalCard() {
  const request = approvalForAgent();
  if (!request) return '';
  if (request.outcome) return `<section class="approval-card resolved" aria-label="Resolved approval"><div class="approval-heading">${icon('check')}${esc(request.outcome)}</div><p>This request is closed. No further answer is needed.</p></section>`;
  return `<section class="approval-card" data-approval="${request.id}" aria-label="Pending approval"><div class="approval-heading">${icon('shield')}${selectedAgent().provider} needs your approval</div><p>${esc(request.summary)} on ${selectedHost().name}.</p><div class="approval-command">${esc(request.command)}</div><div class="approval-actions">${action('Allow once','allow-once')}${action('Always allow','always-allow','secondary')}${action('Deny','deny','text-button')}</div></section>`;
}

function renderAccount() {
  return `<div class="master-heading"><h1>Account</h1></div><div class="account-person"><div><h2>Brent Guo</h2><p>Signed in with Agora.Build</p></div></div>
    <div class="settings-group"><button class="settings-row" data-action="portal"><span>${icon('account')}Manage Agora.Build account</span>${icon('external')}</button><button class="settings-row" data-action="security"><span>${icon('shield')}Devices & security</span>${icon('right')}</button><button class="settings-row" data-action="notifications"><span>${icon('bell')}Notifications</span>${icon('right')}</button></div>
    <div class="settings-label">CONNECTION</div><div class="settings-group"><button class="settings-row" data-action="station"><span class="setting-copy">Station<p>station-dev.agora.build</p></span><span class="setting-value">Built-in · Dev</span></button><button class="settings-row" data-action="this-device"><span>${icon('fingerprint')}This device</span><span class="setting-value">${state.trusted ? 'Verified' : 'Set up access'}</span></button></div>
    <div class="settings-label">APP</div><div class="settings-group"><button class="settings-row" data-action="about"><span>${icon('info')}About Astation</span><span class="setting-value">0.1 · UI preview</span></button></div><button class="text-button full" data-action="sign-out">Sign out</button>`;
}

function renderShell() {
  let master;
  const showingChats = state.route === 'chats' || (state.route === 'chat' && state.chatOrigin === 'chats');
  if (showingChats) master = renderChats();
  else if (state.route === 'account') master = renderAccount();
  else master = state.route === 'instances' ? renderHosts() : renderAgentList();
  const detail = state.route === 'chat' ? renderChat() : renderEmpty();
  return `<div class="shell" data-route="${state.route}"><header class="shell-header">${brand()}<button class="icon-button" data-action="account" aria-label="Open account"><span class="avatar">BG</span></button></header><div class="shell-body"><section class="master" aria-label="${showingChats ? 'Chats and pending approvals' : state.route === 'account' ? 'Account settings' : 'Agents by Atem'}">${master}</section><section class="detail">${detail}</section></div><nav class="nav-bar" aria-label="Main navigation">${navItem('chats','Chats','chat',showingChats,pendingApprovals().length)}${navItem('instances','Agents','host',!showingChats && state.route !== 'account')}${navItem('account','Account','account',state.route === 'account')}</nav></div>`;
}

function navItem(route, label, symbol, active, badge = 0) {
  return `<button type="button" class="nav-item ${active ? 'active' : ''}" data-action="${route}" ${active ? 'aria-current="page"' : ''}>${icon(symbol)}<span>${label}</span>${badge ? `<span class="count" aria-label="${badge} pending approvals">${badge}</span>` : ''}</button>`;
}

function sheetFrame(title, content) {
  return `<div class="sheet-overlay" id="sheet-overlay" ${state.switcher ? 'inert aria-hidden="true"' : ''}><section class="sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-title" tabindex="-1"><div class="sheet-handle"></div><div class="sheet-heading"><h2 id="sheet-title">${title}</h2>${iconButton('close-sheet','Close dialog','close')}</div>${content}</section></div>`;
}

function renderSheet() {
  const kind = state.sheet;
  const request = approvalRequests.find(item => item.id === state.activeApprovalId) || approvalForAgent();
  const requestAgent = request && agents.find(item => item.id === request.agent);
  const requestHost = requestAgent && hosts.find(item => item.id === requestAgent.host);
  if (kind === 'auth') return sheetFrame('', `<div class="browser-header">${icon('lock')}AGORA.BUILD · SYSTEM BROWSER${icon('external')}</div><div class="portal-wordmark">Agora<span>.Build</span></div><h3 style="font-size:20px;font-weight:500;margin-top:22px">Welcome back.</h3><p class="sheet-intro">One account for your projects and agents.</p><div class="auth-options">${action('Continue with GitHub','complete-signin','primary github','github')}<div class="auth-divider">or</div>${action('Sign in with your account','email-signin','secondary')}</div><div class="auth-create">New to Agora.Build? <button class="text-button" data-action="create-account">Create an account</button></div><div class="prototype-label">Browser-screen preview · no real authentication</div>`);
  if (kind === 'email' || kind === 'create') return sheetFrame(kind === 'create' ? 'Create your account' : 'Welcome back', `<div class="browser-header">${icon('lock')}AGORA.BUILD · SYSTEM BROWSER${icon('external')}</div><p class="sheet-intro">${kind === 'create' ? 'Use GitHub or create an Agora.Build account, just like the Portal.' : 'Use your existing Agora.Build account.'}</p><label class="small-note" for="email-preview">Email address</label><input id="email-preview" class="sheet-field" style="min-height:0;margin:7px 0 14px" placeholder="you@example.com" type="email" disabled><label class="small-note" for="password-preview">Password</label><input id="password-preview" class="sheet-field" style="min-height:0;margin-top:7px" placeholder="Your password" type="password" disabled>${action(kind === 'create' ? 'Preview account created' : 'Preview signed in','complete-signin','primary full')}<div class="prototype-label">Fields disabled in this design preview</div>`);
  if (kind === 'launch') return sheetFrame('New agent', `<p class="sheet-intro">Start a fresh conversation on your Atem.</p><div class="run-on">${icon('host')}Run on <strong>${selectedHost().name}</strong>${status('Online')}</div><div class="sheet-section">CHOOSE A PROFILE</div>${profiles.map(profile => `<label class="profile-option">${symbol(profile.provider)}<span><strong>${profile.name}</strong><p>${profile.provider} · ${profile.project}</p></span><input type="radio" name="profile" value="${profile.id}" ${state.profile === profile.id ? 'checked' : ''}></label>`).join('')}<p class="small-note">Profiles are set up on this Atem. The project and agent settings come with the profile.</p>${action('Create agent','create-agent','primary full','plus')}<div class="native-note">${icon('lock')}Your credentials stay on the host.</div>`);
  if (kind === 'launching') return sheetFrame('New agent', `<div class="launching"><div class="empty-orbit">${icon('chat')}</div><h3>Starting your agent.</h3><p>${profiles.find(profile => profile.id === state.profile).name} on ${selectedHost().name}<br>We’ll open the conversation when it’s ready.</p><p class="small-note">Checking the original launch request.</p></div>`);
  if (kind === 'always') return sheetFrame('Always allow this command?', `<p class="sheet-intro">${requestAgent.provider} offered this exact rule for the current session.</p><div class="approval-command">${esc(request.command)}</div><div class="settings-group"><div class="settings-row"><span>Applies to</span><strong>This session</strong></div><div class="settings-row"><span>Agent</span><strong>${requestAgent.provider} on ${requestHost.name}</strong></div></div><p class="small-note">You can revoke this rule from the conversation’s approval rules.</p>${action('Always allow for this session','confirm-always','primary full')}`);
  if (kind === 'deny') return sheetFrame('Deny this request', `<p class="sheet-intro">The agent will not run this command. You can tell it why.</p><div class="approval-command">${esc(request.command)}</div><label class="small-note" for="deny-note">Message to the agent · optional</label><textarea class="sheet-field" id="deny-note" placeholder="Try a narrower test first..."></textarea>${action('Deny request','confirm-deny','primary full')}`);
  if (kind === 'all-approvals') return sheetFrame('Pending approvals', `<p class="sheet-intro">Review each request in its own conversation.</p><div class="all-approval-list">${pendingApprovals().map(renderApprovalPreview).join('') || '<div class="approvals-clear">No approvals waiting</div>'}</div>`);
  if (kind === 'takeover') return sheetFrame('Take over and send?', `<p class="sheet-intro">Brent’s Mac currently controls this agent. Sending will move control to this device.</p><div class="run-on">${icon('host')}Brent’s Mac<span class="pill">CURRENT HOLDER</span></div><p class="small-note">If the controller changes before you confirm, we’ll ask again. Your message stays as a draft.</p>${action('Take over and send','confirm-takeover','primary full')}${action('Keep as draft','close-sheet','secondary full')}`);
  if (kind === 'security') return sheetFrame('Devices & security', `<p class="sheet-intro">The Astation devices trusted by your account.</p><div class="settings-label">ASTATION DEVICES</div><div class="settings-group"><button class="settings-row" data-action="this-device"><span class="setting-copy"><strong>This phone</strong><p>This device · ${state.trusted ? 'Control access' : 'Approval needed'}</p></span><span class="setting-value">${state.trusted ? 'Verified' : 'Not verified'} ${icon('right')}</span></button><div class="settings-row"><span class="setting-copy"><strong>Brent’s Mac</strong><p>Manager · can add and remove devices</p></span><span class="setting-value">Verified</span></div><div class="settings-row"><span class="setting-copy"><strong>iPad</strong><p>View access</p></span><span class="setting-value">Verified</span></div></div>${action('Add another device','add-device','secondary full','plus')}<p class="small-note">A trusted manager confirms device additions and removals with native device authentication.</p><div class="prototype-label">Sample device list · no account changes are made</div>`);
  if (kind === 'this-device') return sheetFrame('This device', `<div class="run-on device-identity">${icon('fingerprint')}<span><strong>Astation on this phone</strong><span class="small-note">${state.trusted ? 'Verified member of your account' : 'Signed in · device approval needed'}</span></span></div><div class="settings-label">DEVICE ACCESS</div><div class="settings-group"><div class="settings-row"><span>Verification</span><span class="setting-value">${state.trusted ? 'Verified' : 'Not verified'}</span></div><div class="settings-row"><span>View agent activity</span><span class="setting-value">${state.trusted ? 'Allowed' : 'Not enabled'}</span></div><div class="settings-row"><span>Messages & approvals</span><span class="setting-value">${state.trusted ? 'Allowed' : 'Not enabled'}</span></div><div class="settings-row"><span>Manage account devices</span><span class="setting-value">Manager required</span></div></div>${state.trusted ? '<p class="small-note">This phone can connect independently. Your Mac can stay offline.</p>' : action('Set up access','enroll-this-device','primary full','shield')}<details class="receipt-details"><summary>Device identity</summary><code>Device: sample-mobile-device<br>Account: Brent Guo<br>Identity shown for this preview only</code></details>${action('View all trusted devices','security','secondary full')}`);
  if (kind === 'add-device') return sheetFrame('Add another device', `<p class="sheet-intro">Approve the new device from a trusted manager such as Brent’s Mac.</p><ol class="setup-steps"><li>Sign in to Agora.Build in Astation on the new phone, tablet or computer.</li><li>Start device setup there, then open <strong>Devices & security → Add device</strong> on your trusted manager.</li><li>Compare the safety code on both devices and approve with native device authentication.</li></ol><p class="small-note">This phone already has ${state.trusted ? 'verified access' : 'a pending setup'}. Adding another device does not restart this phone’s verification.</p><div class="prototype-label">Enrollment guide · no device is added in this preview</div>`);
  if (kind === 'enroll') return sheetFrame('Add this device', `<p class="sheet-intro">You’re signed in. Now approve this device once to access your agents.</p><ol class="setup-steps"><li>Open <strong>Devices & security → Add device</strong> in an Astation you trust.</li><li>Compare the code on both devices, then approve with Face ID, Touch ID or your device authentication.</li></ol><div class="safety-code">K7PV · AC3D · T2ZU</div><p class="small-note">Only continue if the codes match. Signing in alone does not grant device access.</p>${action('Preview trusted-device approval','verify-device','primary full','shield')}<div class="prototype-label">Example safety code · not an enrollment request</div>`);
  if (kind === 'biometric') return sheetFrame('Confirm on this device', `<div class="launching"><div class="empty-orbit">${icon('fingerprint')}</div><h3>Finish adding this device.</h3><p>The real app uses your platform’s secure device authentication.</p></div>${action('Preview successful confirmation','finish-enrollment','primary full')}<div class="prototype-label">Native confirmation preview · no system prompt</div>`);
  if (kind === 'details') return sheetFrame('Conversation', `<button class="run-on conversation-card conversation-trigger" data-action="switch-conversation" data-switcher-trigger="card" aria-label="Switch conversation, current: ${esc(selectedAgent().name)}" aria-haspopup="dialog" aria-expanded="${!!state.switcher}">${symbol(selectedAgent().provider)}<span class="conversation-card-copy"><strong>${selectedAgent().name}</strong><span class="small-note">${selectedAgent().provider} on ${selectedHost().name} · ${selectedHost().short}</span></span><span class="conversation-card-affordance">${icon('right')}</span></button><p class="switcher-hint">Touch and hold to switch conversations</p><div class="settings-group"><button class="settings-row" data-action="rules"><span>${icon('shield')}Approval rules</span>${icon('right')}</button><button class="settings-row" data-action="request-status"><span>${icon('info')}Activity & request status</span>${icon('right')}</button></div><details class="receipt-details"><summary>Connection details</summary><code>${selectedHost().full}<br>Session: sample-mobile-session<br>Device access: verified</code></details><div class="divider"></div><p class="small-note">Review scenario</p>${action(state.controllerElsewhere ? 'Simulate: control is available' : 'Simulate: another device has control','toggle-controller','secondary full')}`);
  if (kind === 'rules') return sheetFrame('Approval rules', approvalForAgent()?.ruleActive ? `<p class="sheet-intro">Allowed automatically for this session.</p><div class="approval-command">${esc(approvalForAgent().command)}</div><p class="small-note">${selectedAgent().provider} on ${selectedHost().name} · exact command · current session</p>${action('Revoke rule','revoke-rule','secondary full')}` : '<p class="sheet-intro">No always-allow rules are active in this conversation.</p>');
  if (kind === 'receipts') return sheetFrame('Activity & request status', '<p class="sheet-intro">Recent messages and their outcomes. IDs stay in details when you need to check a receipt.</p><div class="settings-group"><div class="settings-row"><span>Check the mobile layout</span><span class="status-label"><span class="dot"></span>Completed</span></div><div class="settings-row"><span>Read 4 files</span><span class="setting-value">Completed</span></div></div><details class="receipt-details"><summary>Receipt details</summary><code>Request: 5cdb84f8-example-preview<br>Outcome: completed<br>Reply: retained</code></details>');
  if (kind === 'link') return sheetFrame('Open this link?', `<p class="sheet-intro">This opens outside Astation.</p><div class="run-on mono" style="font-size:10px;overflow-wrap:anywhere">https://docs.flutter.dev/ui/adaptive-responsive</div>${action('Open in browser','open-link','primary full','external')}`);
  if (kind === 'portal') return sheetFrame('Your Agora.Build account', `<p class="sheet-intro">Manage your account, connected GitHub login and account settings in the Portal.</p><div class="run-on mono">https://dev.agora.build</div>${action('Preview return to account','close-sheet','primary full')}<div class="prototype-label">The real app opens the system browser.</div>`);
  if (kind === 'station') return sheetFrame('Station', '<p class="sheet-intro">Built-in development Station</p><div class="run-on mono" style="font-size:11px">https://station-dev.agora.build</div><p class="small-note">Production builds default to station.agora.build. Custom Stations use the separate enrollment flow. Development environment controls live here, away from the main workspace.</p>');
  if (kind === 'notifications') return sheetFrame('Notifications', '<p class="sheet-intro">Approval notifications bring you back to the exact request.</p><div class="settings-group"><div class="settings-row"><span>Approval cards in Chats</span><span class="setting-value">On</span></div><div class="settings-row"><span>Device notifications</span><span class="setting-value">Ask on device</span></div></div><p class="small-note">A notification opens the conversation and refreshes the request. Already-answered requests stay closed.</p>');
  if (kind === 'about') return sheetFrame('Astation', '<p class="sheet-intro">Your agents, wherever you are.</p><div class="settings-group"><div class="settings-row"><span>Design version</span><span class="setting-value">01</span></div><div class="settings-row"><span>Platforms</span><span class="setting-value">iOS + Android</span></div></div><p class="small-note">Phone, tablet and folding displays. This clickable prototype uses sample data only.</p>');
  return '';
}

function renderConversationSwitcher() {
  return `<div class="switcher-overlay"><section class="conversation-popover" role="dialog" aria-modal="true" aria-labelledby="switcher-title" tabindex="-1"><header class="switcher-heading"><div><h2 id="switcher-title">Switch conversation</h2><p>Recent conversations across machines</p></div>${iconButton('close-switcher','Close conversation switcher','close')}</header><div class="conversation-options">${recentAgents().map(agent => {
    const host = hosts.find(item => item.id === agent.host);
    const current = agent.id === state.agent;
    return `<button class="conversation-option ${current ? 'current' : ''}" data-action="select-conversation" data-agent="${agent.id}" ${current ? 'aria-current="true"' : ''}>${symbol(agent.provider)}<span class="conversation-option-copy"><strong>${esc(agent.name)}</strong><span class="conversation-host">${agent.provider} on ${host.name} · ${host.short}</span>${status(agent.activity,agent.state)}</span>${current ? `<span class="current-conversation" aria-label="Current conversation">${icon('check')}</span>` : ''}</button>`;
  }).join('')}</div><button class="show-all-agents" data-action="all-agents">${icon('chat')}<span>Show all agents</span>${icon('right')}</button></section></div>`;
}

function positionConversationSwitcher() {
  const popover = app.querySelector('.conversation-popover');
  const bounds = app.getBoundingClientRect();
  const detail = app.querySelector('.detail').getBoundingClientRect();
  const paneLeft = preview.dataset.device === 'duo' ? detail.left - bounds.left : 0;
  const margin = 14;
  const width = Math.min(340, bounds.width - paneLeft - margin * 2);
  popover.style.width = `${width}px`;
  popover.style.maxHeight = `${Math.min(480,bounds.height - margin * 2)}px`;
  const {anchor} = state.switcher;
  const height = popover.offsetHeight;
  const below = anchor.bottom + 8;
  const preferredTop = below + height <= bounds.height - margin ? below : anchor.top - height - 8;
  popover.style.left = `${Math.max(paneLeft + margin,Math.min(anchor.left,bounds.width - width - margin))}px`;
  popover.style.top = `${Math.max(margin,Math.min(preferredTop,bounds.height - height - margin))}px`;
}

function render() {
  const activePrompt = document.querySelector('#prompt');
  if (activePrompt) state.drafts[activePrompt.dataset.agent] = activePrompt.value;
  app.innerHTML = `<div class="base" style="height:100%" ${state.sheet || state.switcher ? 'inert' : ''}>${state.screen === 'login' ? renderLogin() : renderShell()}</div>${state.sheet ? renderSheet() : ''}${state.switcher ? renderConversationSwitcher() : ''}${state.toast ? `<div class="toast" role="status">${esc(state.toast)}</div>` : ''}`;
  if (state.switcher) {
    positionConversationSwitcher();
    app.querySelector('.conversation-option.current').focus();
  } else if (state.sheet) (app.querySelector('.auth-options button, .sheet input:not(:disabled), .sheet button:not(.icon-button)') || app.querySelector('.sheet')).focus();
}

function openConversationSwitcher(trigger) {
  const rect = trigger.getBoundingClientRect();
  const bounds = app.getBoundingClientRect();
  state.switcher = {trigger:trigger.dataset.switcherTrigger, anchor:{left:rect.left - bounds.left, top:rect.top - bounds.top, bottom:rect.bottom - bounds.top}};
  render();
}

function closeConversationSwitcher() {
  const trigger = state.switcher?.trigger;
  state.switcher = null;
  render();
  if (trigger) app.querySelector(`[data-switcher-trigger="${trigger}"]`)?.focus();
}

function cancelConversationHold() {
  clearTimeout(conversationHold?.timer);
  conversationHold = null;
}

function toast(text) {
  clearTimeout(toastTimer);
  state.toast = text;
  render();
  document.querySelector('#announcement').textContent = text;
  toastTimer = setTimeout(() => { state.toast = null; render(); }, 3800);
}

function showSheet(kind) {
  cancelConversationHold();
  state.switcher = null;
  state.returnAction = document.activeElement?.dataset.action || null;
  state.sheet = kind;
  render();
}

function closeSheet() {
  cancelConversationHold();
  state.switcher = null;
  state.sheet = null;
  render();
  if (state.returnAction) app.querySelector(`[data-action="${state.returnAction}"]`)?.focus();
}

function ensureTrusted(next) {
  if (state.trusted) { next(); return; }
  state.deferred = next;
  showSheet('enroll');
}

function changeRoute(route) {
  cancelConversationHold();
  state.switcher = null;
  state.activeApprovalId = null;
  state.route = route;
  state.sheet = null;
  state.screen = 'workspace';
  render();
}

function submitMessage() {
  const input = app.querySelector('#prompt');
  const text = input?.value.trim() || state.drafts[state.agent]?.trim();
  if (!text) return;
  state.drafts[state.agent] = text;
  if (state.controllerElsewhere) { showSheet('takeover'); return; }
  sendPreviewMessage();
}

function sendPreviewMessage() {
  const text = state.drafts[state.agent];
  if (!text) return;
  (state.messages[state.agent] ||= []).push(text);
  selectedAgent().updatedAt = Date.now();
  selectedAgent().lastMessage = text;
  state.drafts[state.agent] = '';
  const prompt = app.querySelector('#prompt');
  if (prompt) prompt.value = '';
  state.sheet = null;
  render();
  const timeline = app.querySelector('#timeline');
  if (timeline) timeline.scrollTop = timeline.scrollHeight;
}

function moveApprovalDeck(offset) {
  const count = pendingApprovals().length;
  if (!count) return;
  const focusedAction = document.activeElement?.dataset.action;
  state.approvalIndex = (state.approvalIndex + offset + count) % count;
  render();
  if (focusedAction) app.querySelector(`[data-action="${focusedAction}"]`)?.focus({preventScroll:true});
}

function openAgent(agentId, origin = state.chatOrigin, afterOpen) {
  const agent = agents.find(item => item.id === agentId);
  ensureTrusted(() => {
    state.host = agent.host;
    state.agent = agent.id;
    state.chatOrigin = origin;
    changeRoute('chat');
    afterOpen?.();
  });
}

function showApprovalSheet(kind) {
  const request = approvalForAgent();
  if (!request || request.outcome) return;
  state.activeApprovalId = request.id;
  showSheet(kind);
}

function resolveApproval(outcome) {
  const request = approvalRequests.find(item => item.id === state.activeApprovalId) || approvalForAgent();
  if (!request || request.outcome) return;
  request.outcome = outcome;
  request.ruleActive = outcome === 'Always allowed for this session';
  if (outcome === 'Denied') request.denyMessage = app.querySelector('#deny-note')?.value.trim() || '';
  const agent = agents.find(item => item.id === request.agent);
  agent.updatedAt = Date.now();
  agent.lastMessage = `${request.summary}: ${outcome.toLowerCase()}.`;
  agent.activity = outcome === 'Denied' ? 'Ready' : 'Working';
  agent.state = outcome === 'Denied' ? 'ready' : 'working';
  state.activeApprovalId = null;
  state.approvalIndex = 0;
  closeSheet();
}

const actions = {
  'previous-feature': () => selectWelcomeFeature(state.featureIndex - 1),
  'next-feature': () => selectWelcomeFeature(state.featureIndex + 1),
  'select-feature': element => selectWelcomeFeature(Number(element.dataset.featureIndex)),
  'sign-in': () => showSheet('auth'),
  'email-signin': () => showSheet('email'),
  'create-account': () => showSheet('create'),
  'complete-signin': () => { state.trusted = true; changeRoute('chats'); },
  'sign-out': () => { state.screen = 'login'; state.sheet = null; render(); },
  'instances': () => changeRoute('instances'),
  'chats': () => changeRoute('chats'),
  'sessions': () => changeRoute('sessions'),
  'back-from-chat': () => changeRoute(state.chatOrigin),
  'account': () => changeRoute('account'),
  'previous-approval': () => moveApprovalDeck(-1),
  'next-approval': () => moveApprovalDeck(1),
  'all-approvals': () => showSheet('all-approvals'),
  'open-host': element => { state.host = element.dataset.host; changeRoute('sessions'); },
  'open-agent': element => openAgent(element.dataset.agent,'sessions'),
  'open-recent-chat': element => openAgent(element.dataset.agent,'chats'),
  'switch-conversation': openConversationSwitcher,
  'close-switcher': closeConversationSwitcher,
  'select-conversation': element => openAgent(element.dataset.agent),
  'all-agents': () => changeRoute('instances'),
  'new-agent': element => { state.host = element.dataset.host || state.host; ensureTrusted(() => showSheet('launch')); },
  'create-agent': () => {
    if (state.launching) return;
    state.launching = true;
    showSheet('launching');
    launchTimer = setTimeout(() => {
      state.launching = false;
      const profile = profiles.find(item => item.id === state.profile);
      const id = `preview-agent-${agents.length}`;
      agents.push({id, host:state.host, name:'New conversation', provider:profile.provider, project:profile.project, activity:'Ready', state:'ready', updatedAt:Date.now(), lastMessage:'New conversation. What would you like to build?'});
      hosts.find(item => item.id === state.host).agents += 1;
      state.agent = id;
      state.chatOrigin = 'sessions';
      changeRoute('chat');
      toast('Preview agent created. No process was launched.');
    }, 950);
  },
  'allow-once': () => resolveApproval('Allowed once'),
  'always-allow': () => showApprovalSheet('always'),
  'confirm-always': () => resolveApproval('Always allowed for this session'),
  'deny': () => showApprovalSheet('deny'),
  'confirm-deny': () => resolveApproval('Denied'),
  'review-approval': element => {
    const request = approvalRequests.find(item => item.id === element.dataset.approval);
    if (!request) return;
    openAgent(request.agent,'chats',() => app.querySelector(`.approval-card[data-approval="${request.id}"]`)?.scrollIntoView({block:'center'}));
  },
  'verify-device': () => showSheet('biometric'),
  'finish-enrollment': () => { state.trusted = true; const next = state.deferred; state.deferred = null; closeSheet(); if (next) next(); else toast('Verified-device state previewed. No enrollment was sent.'); },
  'security': () => showSheet('security'),
  'this-device': () => showSheet('this-device'),
  'add-device': () => showSheet('add-device'),
  'enroll-this-device': () => showSheet('enroll'),
  'details': () => showSheet('details'),
  'rules': () => showSheet('rules'),
  'request-status': () => showSheet('receipts'),
  'revoke-rule': () => { const request = approvalForAgent(); if (request) request.ruleActive = false; closeSheet(); toast('Rule-revocation preview. The next matching command would need approval.'); },
  'toggle-controller': () => { state.controllerElsewhere = !state.controllerElsewhere; closeSheet(); },
  'confirm-takeover': () => { state.controllerElsewhere = false; sendPreviewMessage(); },
  'toggle-tools': () => { state.expandedTools = !state.expandedTools; render(); },
  'inspect-link': () => showSheet('link'),
  'open-link': () => { window.open('https://docs.flutter.dev/ui/adaptive-responsive','_blank','noopener,noreferrer'); closeSheet(); },
  'portal': () => showSheet('portal'),
  'station': () => showSheet('station'),
  'notifications': () => showSheet('notifications'),
  'about': () => showSheet('about'),
  'close-sheet': closeSheet,
  'copy-code': async () => { try { await navigator.clipboard.writeText('flutter test test/layout_test.dart'); toast('Command copied.'); } catch { toast('Copy from the displayed command.'); } },
  'copy-reply': async () => { try { await navigator.clipboard.writeText('Build one complete conversation flow, then expand to other devices.'); toast('Reply copied.'); } catch { toast('Select the reply text to copy.'); } },
};

document.addEventListener('pointerdown', event => {
  if (!event.isPrimary || event.button !== 0) return;
  const deck = event.target.closest('.approval-deck, .feature-stage');
  cardSwipe = deck && app.contains(deck) ? {pointerId:event.pointerId, x:event.clientX, y:event.clientY, kind:deck.classList.contains('feature-stage') ? 'feature' : 'approval'} : null;
  const trigger = event.target.closest('[data-switcher-trigger]');
  if (!trigger || !app.contains(trigger) || event.button !== 0 || !event.isPrimary) return;
  cancelConversationHold();
  conversationHold = {x:event.clientX, y:event.clientY, pointerId:event.pointerId, opened:false};
  conversationHold.timer = setTimeout(() => {
    if (!trigger.isConnected) { cancelConversationHold(); return; }
    conversationHold.opened = true;
    openConversationSwitcher(trigger);
  },500);
});
document.addEventListener('pointermove', event => {
  if (!conversationHold || conversationHold.pointerId !== event.pointerId || conversationHold.opened) return;
  if (Math.hypot(event.clientX - conversationHold.x,event.clientY - conversationHold.y) > 10) cancelConversationHold();
});
document.addEventListener('pointerup', event => {
  if (cardSwipe?.pointerId === event.pointerId) {
    const dx = event.clientX - cardSwipe.x;
    const dy = event.clientY - cardSwipe.y;
    if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.5) {
      suppressReleaseClickUntil = performance.now() + 120;
      if (cardSwipe.kind === 'feature') selectWelcomeFeature(state.featureIndex + (dx < 0 ? 1 : -1));
      else moveApprovalDeck(dx < 0 ? 1 : -1);
    }
  }
  cardSwipe = null;
  // A hold replaces its target; ignore the release click on the new overlay.
  if (conversationHold?.opened) suppressReleaseClickUntil = performance.now() + 120;
  cancelConversationHold();
});
document.addEventListener('pointercancel', () => { cardSwipe = null; cancelConversationHold(); });
document.addEventListener('scroll', () => { cardSwipe = null; cancelConversationHold(); }, true);
document.addEventListener('contextmenu', event => {
  const trigger = event.target.closest('[data-switcher-trigger]');
  if (!trigger || !app.contains(trigger)) return;
  event.preventDefault();
  cancelConversationHold();
  openConversationSwitcher(trigger);
});
document.addEventListener('click', event => {
  if (event.detail && performance.now() < suppressReleaseClickUntil) {
    event.preventDefault();
    return;
  }
  if (event.target.classList.contains('switcher-overlay')) { closeConversationSwitcher(); return; }
  const element = event.target.closest('[data-action]');
  if (!element || !app.contains(element)) return;
  event.preventDefault();
  actions[element.dataset.action]?.(element);
});
document.addEventListener('submit', event => {
  if (event.target.id !== 'composer-form') return;
  event.preventDefault();
  ensureTrusted(submitMessage);
});
document.addEventListener('change', event => {
  if (event.target.name === 'profile') state.profile = event.target.value;
});
document.addEventListener('input', event => {
  if (event.target.id === 'prompt') state.drafts[event.target.dataset.agent] = event.target.value;
  if (event.target.id === 'host-search') {
    const query = event.target.value.toLowerCase();
    for (const card of app.querySelectorAll('[data-host-card]')) {
      const host = hosts.find(item => item.id === card.dataset.hostCard);
      card.hidden = !`${host.full} ${host.name} ${host.system}`.toLowerCase().includes(query);
    }
  }
});
document.addEventListener('keydown', event => {
  if (!state.sheet && !state.switcher && event.target.closest('.welcome-carousel') && ['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) {
    event.preventDefault();
    const index = event.key === 'Home' ? 0 : event.key === 'End' ? welcomeFeatures.length - 1 : state.featureIndex + (event.key === 'ArrowRight' ? 1 : -1);
    selectWelcomeFeature(index);
    return;
  }
  if (!state.sheet && !state.switcher) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    if (state.switcher) closeConversationSwitcher(); else closeSheet();
    return;
  }
  const dialog = app.querySelector(state.switcher ? '.conversation-popover' : '.sheet');
  const focusables = [...dialog.querySelectorAll('button:not(:disabled), input:not(:disabled), textarea, a[href]')];
  if (state.switcher && ['ArrowDown','ArrowUp','Home','End'].includes(event.key)) {
    event.preventDefault();
    const index = focusables.indexOf(document.activeElement);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? focusables.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + focusables.length) % focusables.length;
    focusables[next]?.focus();
    return;
  }
  if (event.key !== 'Tab') return;
  const first = focusables[0], last = focusables.at(-1);
  if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
  else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
});
document.querySelector('#devices').addEventListener('click', event => {
  const button = event.target.closest('[data-device]');
  if (!button) return;
  cancelConversationHold();
  state.switcher = null;
  preview.dataset.device = button.dataset.device;
  for (const item of document.querySelectorAll('#devices button')) item.setAttribute('aria-pressed',String(item === button));
  render();
});
document.querySelector('.review-scenes').addEventListener('click', event => {
  const scene = event.target.closest('[data-scene]')?.dataset.scene;
  if (!scene) return;
  cancelConversationHold();
  clearTimeout(launchTimer); state.launching = false; state.sheet = null; state.switcher = null; state.toast = null;
  state.screen = scene === 'login' ? 'login' : 'workspace';
  state.host = 'genie'; state.agent = 'codex';
  state.chatOrigin = 'chats';
  if (scene === 'login') render();
  else if (scene === 'chat') changeRoute('chat');
  else if (scene === 'launch') { state.route = 'sessions'; state.trusted = true; showSheet('launch'); }
  else if (scene === 'enroll') { state.trusted = false; state.route = 'chats'; state.deferred = null; showSheet('enroll'); }
  else changeRoute(scene);
});

render();
