// Astation Session Web App
// Agora Web SDK 4.x integration for RTC session sharing

const STORAGE_KEY = "astation_user";
const EXPIRY_DAYS = 7;

let client = null;
let localAudioTrack = null;
let isMicMuted = false;
let sessionId = null;
let currentUid = null;
let currentName = null;
let remoteUsers = new Map(); // uid -> { name, audioTrack, videoTrack }

// --- Init ---

document.addEventListener("DOMContentLoaded", () => {
    sessionId = extractSessionId();
    if (!sessionId) {
        showError("Invalid session URL.");
        return;
    }
    verifySession(sessionId);
});

function extractSessionId() {
    const path = window.location.pathname;
    const match = path.match(/^\/session\/([a-zA-Z0-9-]+)/);
    return match ? match[1] : null;
}

// --- Session Verification ---

async function verifySession(id) {
    try {
        const resp = await fetch(`/api/rtc-sessions/${id}`);
        if (!resp.ok) {
            showError("This session does not exist or has expired.");
            return;
        }
        const data = await resp.json();
        showNameDialog(data);
    } catch (err) {
        showError("Failed to connect to server.");
    }
}

// --- User Identity ---

function checkSavedUser() {
    try {
        const stored = localStorage.getItem(STORAGE_KEY);
        if (!stored) return null;
        const user = JSON.parse(stored);
        const daysSince = (Date.now() - user.lastUsed) / (1000 * 60 * 60 * 24);
        if (daysSince > EXPIRY_DAYS) {
            localStorage.removeItem(STORAGE_KEY);
            return null;
        }
        return user;
    } catch {
        return null;
    }
}

function saveUser(name) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
        name: name,
        lastUsed: Date.now()
    }));
}

// --- UI State Management ---

function showLoading() {
    document.getElementById("loading").style.display = "flex";
    document.getElementById("error").style.display = "none";
    document.getElementById("name-dialog").style.display = "none";
    document.getElementById("app").style.display = "none";
}

function showError(message) {
    document.getElementById("loading").style.display = "none";
    document.getElementById("error").style.display = "flex";
    document.getElementById("name-dialog").style.display = "none";
    document.getElementById("app").style.display = "none";
    document.getElementById("error-message").textContent = message;
}

function showNameDialog(sessionData) {
    document.getElementById("loading").style.display = "none";
    document.getElementById("error").style.display = "none";
    document.getElementById("name-dialog").style.display = "flex";
    document.getElementById("app").style.display = "none";

    document.getElementById("session-info").textContent =
        `Channel: ${sessionData.channel}`;

    const saved = checkSavedUser();
    if (saved) {
        document.getElementById("name-input").value = saved.name;
    }

    // Focus input
    const input = document.getElementById("name-input");
    input.focus();
    input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") handleJoin();
    });
}

function showApp() {
    document.getElementById("loading").style.display = "none";
    document.getElementById("error").style.display = "none";
    document.getElementById("name-dialog").style.display = "none";
    document.getElementById("app").style.display = "flex";
}

// --- Join Flow ---

async function handleJoin() {
    const nameInput = document.getElementById("name-input");
    const name = nameInput.value.trim();
    if (!name) {
        nameInput.focus();
        return;
    }

    const joinBtn = document.getElementById("join-btn");
    joinBtn.disabled = true;
    joinBtn.textContent = "Joining...";

    try {
        const resp = await fetch(`/api/rtc-sessions/${sessionId}/join`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name: name })
        });

        if (!resp.ok) {
            showError("Failed to join session.");
            return;
        }

        const data = await resp.json();
        currentUid = data.uid;
        currentName = data.name;

        saveUser(name);
        showApp();

        document.getElementById("display-name").textContent = currentName;
        document.getElementById("channel-name").textContent = data.channel;

        await joinChannel(data.app_id, data.channel, data.token, data.uid);
    } catch (err) {
        showError("Connection failed: " + err.message);
    }
}

// --- Agora SDK ---

async function joinChannel(appId, channel, token, uid) {
    client = AgoraRTC.createClient({ mode: "rtc", codec: "vp8" });

    // Set up event handlers before joining
    client.on("user-published", handleUserPublished);
    client.on("user-unpublished", handleUserUnpublished);
    client.on("user-joined", handleUserJoined);
    client.on("user-left", handleUserLeft);

    await client.join(appId, channel, token, uid);

    // Create and publish local mic track
    try {
        localAudioTrack = await AgoraRTC.createMicrophoneAudioTrack();
        await client.publish([localAudioTrack]);
    } catch (err) {
        console.warn("Microphone access denied:", err);
    }

    // Add self to user list
    addUserToList(uid, currentName, true);
    updateParticipantCount();
}

async function handleUserPublished(user, mediaType) {
    await client.subscribe(user, mediaType);

    if (mediaType === "video") {
        const videoMain = document.getElementById("video-main");
        videoMain.innerHTML = "";
        user.videoTrack.play(videoMain);

        // Track the video
        if (remoteUsers.has(user.uid)) {
            remoteUsers.get(user.uid).videoTrack = user.videoTrack;
        }
    }

    if (mediaType === "audio") {
        user.audioTrack.play();

        if (remoteUsers.has(user.uid)) {
            remoteUsers.get(user.uid).audioTrack = user.audioTrack;
        }
    }
}

function handleUserUnpublished(user, mediaType) {
    if (mediaType === "video") {
        const videoMain = document.getElementById("video-main");
        videoMain.innerHTML = '<div class="video-placeholder"><p>Waiting for screen share...</p></div>';

        if (remoteUsers.has(user.uid)) {
            remoteUsers.get(user.uid).videoTrack = null;
        }
    }

    if (mediaType === "audio") {
        if (remoteUsers.has(user.uid)) {
            remoteUsers.get(user.uid).audioTrack = null;
        }
    }
}

function handleUserJoined(user) {
    remoteUsers.set(user.uid, {
        name: `User ${user.uid}`,
        audioTrack: null,
        videoTrack: null
    });
    addUserToList(user.uid, `User ${user.uid}`, false);
    updateParticipantCount();
}

function handleUserLeft(user) {
    remoteUsers.delete(user.uid);
    removeUserFromList(user.uid);
    updateParticipantCount();
}

// --- User List UI ---

function addUserToList(uid, name, isSelf) {
    const list = document.getElementById("user-list");
    const existing = document.getElementById(`user-${uid}`);
    if (existing) return;

    const li = document.createElement("li");
    li.className = "user-item";
    li.id = `user-${uid}`;

    const initial = name.charAt(0).toUpperCase();
    const role = isSelf ? "You" : "Participant";

    li.innerHTML = `
        <div class="user-avatar">${initial}</div>
        <div class="user-info">
            <div class="user-name">${escapeHtml(name)}</div>
            <div class="user-role">${role}</div>
        </div>
        <div class="mic-indicator active"></div>
    `;

    list.appendChild(li);
}

function removeUserFromList(uid) {
    const el = document.getElementById(`user-${uid}`);
    if (el) el.remove();
}

function updateParticipantCount() {
    const count = document.getElementById("user-list").children.length;
    document.getElementById("participant-count").textContent = count;
}

// --- Controls ---

function toggleMic() {
    if (!localAudioTrack) return;

    isMicMuted = !isMicMuted;
    localAudioTrack.setEnabled(!isMicMuted);

    const btn = document.getElementById("mic-btn");
    const onIcon = document.getElementById("mic-on-icon");
    const offIcon = document.getElementById("mic-off-icon");

    if (isMicMuted) {
        btn.classList.add("mic-muted");
        onIcon.style.display = "none";
        offIcon.style.display = "block";
    } else {
        btn.classList.remove("mic-muted");
        onIcon.style.display = "block";
        offIcon.style.display = "none";
    }

    // Update own mic indicator
    const selfItem = document.getElementById(`user-${currentUid}`);
    if (selfItem) {
        const indicator = selfItem.querySelector(".mic-indicator");
        indicator.className = `mic-indicator ${isMicMuted ? "muted" : "active"}`;
    }
}

async function leave() {
    if (localAudioTrack) {
        localAudioTrack.stop();
        localAudioTrack.close();
        localAudioTrack = null;
    }

    if (client) {
        await client.leave();
        client = null;
    }

    window.location.href = "/";
}

// --- Utilities ---

function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
}
