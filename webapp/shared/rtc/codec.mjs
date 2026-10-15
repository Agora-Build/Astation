export const preferredCodec = "h264";
export const fallbackCodec = "vp8";

export function pickCodec(preferred, supported) {
    if (Array.isArray(supported) && supported.includes(preferred)) {
        return preferred;
    }
    return fallbackCodec;
}
