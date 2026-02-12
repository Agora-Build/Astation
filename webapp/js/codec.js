(function(root) {
    const preferredCodec = "av1";
    const fallbackCodec = "vp8";

    function pickCodec(preferred, supported) {
        if (Array.isArray(supported) && supported.includes(preferred)) {
            return preferred;
        }
        return fallbackCodec;
    }

    const api = {
        preferredCodec,
        fallbackCodec,
        pickCodec
    };

    if (typeof module !== "undefined" && module.exports) {
        module.exports = api;
    } else {
        root.AstationCodec = api;
    }
})(typeof window !== "undefined" ? window : globalThis);
