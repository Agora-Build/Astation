import { preferredCodec, fallbackCodec } from "./codec.mjs";

// The UI owns rendering; this layer owns SDK setup and partial-failure cleanup.
export async function joinChannel(sdk, identity, handlers = {}) {
    const codecs = [...new Set([preferredCodec, fallbackCodec])];
    for (const [index, codec] of codecs.entries()) {
        const client = sdk.createClient({ mode: "live", codec });
        for (const [event, handler] of Object.entries(handlers)) {
            client.on(event, (...args) => handler(...args, client));
        }
        try {
            await client.setClientRole("host");
            await client.join(identity.app_id, identity.channel, identity.token, identity.uid);
            return client;
        } catch (error) {
            await client.leave();
            if (index === codecs.length - 1) throw error;
        }
    }
}

export function closeLocalTrack(track) {
    if (!track) return;
    track.stop();
    track.close();
}

export async function publishMicrophone(sdk, client, { signal } = {}) {
    signal?.throwIfAborted();
    const track = await sdk.createMicrophoneAudioTrack();
    let closed = false;
    const close = () => {
        if (closed) return;
        closed = true;
        closeLocalTrack(track);
    };
    signal?.addEventListener("abort", close, { once: true });
    try {
        signal?.throwIfAborted();
        await client.publish([track]);
        signal?.throwIfAborted();
        return track;
    } catch (error) {
        close();
        throw error;
    } finally {
        signal?.removeEventListener("abort", close);
    }
}

export async function subscribeTrack(client, user, mediaType) {
    await client.subscribe(user, mediaType);
    if (mediaType === "video") {
        try {
            await client.setRemoteVideoStreamType(user.uid, 0);
        } catch (error) {
            console.warn("High-stream selection unavailable:", error);
        }
    }
}
