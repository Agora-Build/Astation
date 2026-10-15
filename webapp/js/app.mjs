// Astation Session Web App
// Agora Web SDK 4.x integration for RTC session sharing

import { ScreenPublisher } from "../lib/media/screen-share.mjs";
import { joinChannel as joinRTCChannel, publishMicrophone, subscribeTrack, closeLocalTrack } from "../lib/media/channel.mjs";

const STORAGE_KEY = "astation_user";
const EXPIRY_DAYS = 7;

let client = null;
let localAudioTrack = null;
let mediaLifetime = new AbortController();
let isMicMuted = false;
let sessionId = null;
let currentUid = null;
let currentName = null;
let remoteUsers = new Map(); // uid -> { name, audioTrack, videoTrack }
let activeVideoUid = null;
let nativeVideoSize = false;
const screenPublisher = new ScreenPublisher(AgoraRTC, async () => {
    const response = await fetch(`/api/rtc-sessions/${sessionId}/join`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: `${currentName} (screen)` })
    });
    if (!response.ok) throw new Error("Unable to allocate a screen-share identity. The session may be full or expired.");
    return response.json();
}, (state, audioUnavailable) => {
    const button = document.getElementById("share-btn");
    button.textContent = state === "stopped" ? "Share screen" : state === "stopping" ? "Stopping..." : "Stop sharing";
    button.disabled = state === "stopping";
    document.getElementById("share-audio-input").disabled = state !== "stopped";
    if (audioUnavailable) showMediaMessage("Your browser did not provide audio for this source. In Chrome or Edge, try sharing a tab and enable its audio in the picker.");
});

// --- Init ---

document.addEventListener("DOMContentLoaded", () => {
    for (const [selector, handler] of [
        ["#join-btn", handleJoin], ["#play-audio-btn", resumeRemoteAudio],
        [".sidebar-toggle", toggleSidebar], ["#sidebar-show-btn", toggleSidebar],
        ["#share-btn", toggleScreenShare], ["#video-size-btn", toggleVideoSize],
        ["#mic-btn", toggleMic], ["#leave-btn", leave]
    ]) {
        document.querySelector(selector).addEventListener("click", handler);
    }
    AgoraRTC.onAutoplayFailed = () => {
        document.getElementById("play-audio-btn").hidden = false;
    };
    new MutationObserver(updateVideoSize).observe(document.getElementById("video-main"), { childList: true, subtree: true });
    window.addEventListener("resize", updateVideoSize);
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

function saveUser(name, micEnabled) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
        name: name,
        micEnabled: micEnabled,
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
        // Restore saved mic state (default to true if not saved)
        const micEnabled = saved.micEnabled !== undefined ? saved.micEnabled : true;
        document.getElementById("mic-enabled-input").checked = micEnabled;
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

    const micEnabledInput = document.getElementById("mic-enabled-input");
    const micEnabled = micEnabledInput.checked;

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

        saveUser(name, micEnabled);
        showApp();

        document.getElementById("display-name").textContent = currentName;
        document.getElementById("channel-name").textContent = data.channel;

        await joinChannel(data.app_id, data.channel, data.token, data.uid, micEnabled);
    } catch (err) {
        showError("Connection failed: " + err.message);
    }
}

// --- Agora SDK ---

async function joinChannel(appId, channel, token, uid, micEnabled = true) {
    const lifetime = mediaLifetime = new AbortController();
    client = await joinRTCChannel(AgoraRTC, { app_id: appId, channel, token, uid }, {
        "user-published": handleUserPublished,
        "user-unpublished": handleUserUnpublished,
        "user-joined": handleUserJoined,
        "user-left": handleUserLeft,
        "token-privilege-will-expire": () => {
            showMediaMessage("Session access expires soon. Ask the host for a new share link to continue.");
        },
        "token-privilege-did-expire": async () => {
            await disconnectMedia();
            showError("Session access has expired. Open a new share link from the host.");
        }
    });
    if (lifetime.signal.aborted) {
        await client.leave();
        client = null;
        lifetime.signal.throwIfAborted();
    }

    // Create and publish local mic track if enabled
    if (micEnabled) {
        try {
            localAudioTrack = await openMicrophone();
            isMicMuted = false;
        } catch (err) {
            console.warn("Microphone access denied:", err);
            localAudioTrack = null;
            isMicMuted = true;
        }
    } else {
        isMicMuted = true;
    }

    // Update mic button UI
    updateMicButton();

    // Add self to user list
    addUserToList(uid, currentName, true);
    updateParticipantCount();
}

async function handleUserPublished(user, mediaType, subscriber = client) {
    if (user.uid === screenPublisher.uid) return;
    if (!remoteUsers.has(user.uid)) handleUserJoined(user);
    try {
        await subscribeTrack(subscriber, user, mediaType);

        if (mediaType === "video") {
            const videoMain = document.getElementById("video-main");
            videoMain.innerHTML = "";

            // Play with fit mode to maintain aspect ratio and quality
            user.videoTrack.play(videoMain, { fit: "contain" });
            activeVideoUid = user.uid;

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
    } catch (err) {
        console.error(`Failed to subscribe to ${mediaType} from UID ${user.uid}:`, err);
        // Try to continue - SDK will handle codec mismatches internally
    }
}

function handleUserUnpublished(user, mediaType) {
    if (mediaType === "video") {
        if (activeVideoUid === user.uid) clearVideo();

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
    if (user.uid === screenPublisher.uid || remoteUsers.has(user.uid)) return;
    remoteUsers.set(user.uid, {
        name: `User ${user.uid}`,
        audioTrack: null,
        videoTrack: null
    });
    addUserToList(user.uid, `User ${user.uid}`, false);
    updateParticipantCount();
}

function handleUserLeft(user) {
    if (activeVideoUid === user.uid) clearVideo();
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

function updateMicButton() {
    const btn = document.getElementById("mic-btn");
    const onIcon = document.getElementById("mic-on-icon");
    const offIcon = document.getElementById("mic-off-icon");

    if (isMicMuted || !localAudioTrack) {
        btn.classList.add("mic-muted");
        onIcon.style.display = "none";
        offIcon.style.display = "block";
    } else {
        btn.classList.remove("mic-muted");
        onIcon.style.display = "block";
        offIcon.style.display = "none";
    }
}

async function toggleMic() {
    // If no track exists, create it
    if (!localAudioTrack) {
        try {
            localAudioTrack = await openMicrophone();
            isMicMuted = false;
        } catch (err) {
            console.error("Failed to create microphone track:", err);
            localAudioTrack = null;
            return;
        }
    } else {
        isMicMuted = !isMicMuted;
        await localAudioTrack.setEnabled(!isMicMuted);
    }

    updateMicButton();

    // Update own mic indicator
    const selfItem = document.getElementById(`user-${currentUid}`);
    if (selfItem) {
        const indicator = selfItem.querySelector(".mic-indicator");
        indicator.className = `mic-indicator ${isMicMuted ? "muted" : "active"}`;
    }
}

async function openMicrophone() {
    const signal = mediaLifetime.signal;
    const track = await publishMicrophone(AgoraRTC, client, { signal });
    if (signal.aborted) {
        closeLocalTrack(track);
        signal.throwIfAborted();
    }
    return track;
}

async function disconnectMedia() {
    mediaLifetime.abort();
    await screenPublisher.stop();
    if (localAudioTrack) {
        closeLocalTrack(localAudioTrack);
        localAudioTrack = null;
    }

    if (client) {
        await client.leave();
        client = null;
    }

}

async function leave() {
    await disconnectMedia();
    window.location.href = "/";
}

async function toggleScreenShare() {
    document.getElementById("media-message").hidden = true;
    try {
        if (screenPublisher.active) await screenPublisher.stop();
        else await screenPublisher.start(document.getElementById("share-audio-input").checked);
    } catch (error) {
        showMediaMessage(`Screen sharing failed: ${error.message}`);
    }
}

function showMediaMessage(message) {
    const element = document.getElementById("media-message");
    element.textContent = message;
    element.hidden = false;
}

function resumeRemoteAudio() {
    for (const user of remoteUsers.values()) user.audioTrack?.play();
    document.getElementById("play-audio-btn").hidden = true;
}

function clearVideo() {
    activeVideoUid = null;
    document.getElementById("video-main").innerHTML = '<div class="video-placeholder"><p>Waiting for screen share...</p></div>';
}

function toggleVideoSize() {
    nativeVideoSize = !nativeVideoSize;
    document.getElementById("video-size-btn").textContent = nativeVideoSize ? "Fit to window" : "1:1 size";
    updateVideoSize();
}

function updateVideoSize() {
    const container = document.getElementById("video-main");
    container.classList.toggle("native-size", nativeVideoSize);
    const video = container.querySelector("video");
    if (!video) return;
    video.onloadedmetadata = updateVideoSize;
    video.onresize = updateVideoSize;
    const player = container.firstElementChild;
    const pixelRatio = window.devicePixelRatio || 1;
    player.style.width = nativeVideoSize && video.videoWidth ? `${video.videoWidth / pixelRatio}px` : "100%";
    player.style.height = nativeVideoSize && video.videoHeight ? `${video.videoHeight / pixelRatio}px` : "100%";
}

function toggleSidebar() {
    const sidebar = document.getElementById("sidebar");
    const showBtn = document.getElementById("sidebar-show-btn");

    if (sidebar.classList.contains("hidden")) {
        sidebar.classList.remove("hidden");
        showBtn.style.display = "none";
    } else {
        sidebar.classList.add("hidden");
        showBtn.style.display = "flex";
    }
}

// --- Utilities ---

function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
}
