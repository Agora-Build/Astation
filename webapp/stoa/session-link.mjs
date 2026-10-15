const sessionIdPattern = /^[A-Za-z0-9-]{1,128}$/;

export function sessionIdFromPath(path) {
    return /^\/(?:stoa\/)?session\/([A-Za-z0-9-]{1,128})\/?$/.exec(path)?.[1] ?? null;
}

export function sessionIdFromInput(value) {
    const text = value.trim();
    if (sessionIdPattern.test(text)) return text;
    try {
        const url = new URL(text, "https://stoa.invalid");
        if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;
        return sessionIdFromPath(url.pathname);
    } catch {
        return null;
    }
}

export function sessionPath(id) {
    if (!sessionIdPattern.test(id)) throw new Error("Invalid session ID");
    return `/stoa/session/${id}`;
}
