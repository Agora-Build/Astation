(function(root) {
    class ScreenPublisher {
        constructor(sdk, allocateIdentity, onStateChange) {
            this.sdk = sdk;
            this.allocateIdentity = allocateIdentity;
            this.onStateChange = onStateChange;
            this.identity = null;
            this.session = null;
        }

        get uid() { return this.identity?.uid; }
        get active() { return this.session !== null; }

        async start(captureAudio) {
            if (this.active) return;
            const session = { tracks: [], closedTracks: new Set(), client: null, cancelled: false, starting: true };
            this.session = session;
            this.onStateChange("starting");
            try {
                // Invoke the browser picker directly from the Share button's user gesture.
                const captured = await this.sdk.createScreenVideoTrack({
                    encoderConfig: { width: { max: 8192 }, height: { max: 8192 }, frameRate: 60 },
                    optimizationMode: "detail"
                }, captureAudio ? "auto" : "disable");
                session.tracks = Array.isArray(captured) ? captured : [captured];
                if (session.cancelled) return;
                const video = session.tracks[0];
                video.on("track-ended", () => {
                    if (this.session === session) this.stop().catch(console.error);
                });
                // Use the selected source dimensions instead of the SDK's default 1080p profile.
                const settings = video.getMediaStreamTrack().getSettings();
                if (settings.width && settings.height) {
                    await video.setEncoderConfiguration({
                        width: settings.width, height: settings.height, frameRate: 60
                    });
                }
                if (session.cancelled) return;
                if (!this.identity) this.identity = await this.allocateIdentity();
                if (session.cancelled) return;
                const identity = this.identity;
                session.client = this.sdk.createClient({ mode: "live", codec: "h264" });
                await session.client.setClientRole("host");
                if (session.cancelled) return;
                await session.client.join(identity.app_id, identity.channel, identity.token, identity.uid);
                if (session.cancelled) return;
                await session.client.publish(session.tracks);
                if (session.cancelled) return;
                this.onStateChange("sharing", captureAudio && session.tracks.length === 1);
            } catch (error) {
                if (!session.cancelled) {
                    await this.stop();
                    throw error;
                }
            } finally {
                session.starting = false;
                if (session.cancelled) {
                    this.closeTracks(session);
                    await this.leaveClient(session);
                    this.finishStop(session);
                }
            }
        }

        async stop() {
            const session = this.session;
            if (!session) return;
            if (session.cancelled) return session.leavePromise;
            session.cancelled = true;
            this.closeTracks(session);
            this.onStateChange("stopping");
            if (!session.starting) {
                await this.leaveClient(session);
                this.finishStop(session);
            }
        }

        async leaveClient(session) {
            if (session.client && !session.leavePromise) {
                session.leavePromise = session.client.leave().catch(error => console.warn("Screen client cleanup failed:", error));
            }
            await session.leavePromise;
        }

        finishStop(session) {
            if (this.session === session) {
                this.session = null;
                this.onStateChange("stopped");
            }
        }

        closeTracks(session) {
            for (const track of session.tracks) {
                if (session.closedTracks.has(track)) continue;
                session.closedTracks.add(track);
                track.stop();
                track.close();
            }
        }
    }

    if (typeof module !== "undefined" && module.exports) module.exports = { ScreenPublisher };
    else root.AstationScreenShare = { ScreenPublisher };
})(typeof window !== "undefined" ? window : globalThis);
