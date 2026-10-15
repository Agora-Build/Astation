use axum::{
    extract::OriginalUri,
    http::{header, HeaderValue},
    response::{IntoResponse, Redirect, Response},
    routing::get,
    Router,
};

pub fn router<S: Clone + Send + Sync + 'static>() -> Router<S> {
    Router::new()
        .route("/chat", get(directory))
        .route("/chat/", get(index))
        .route("/chat/chat.css", get(styles))
        .route("/chat/chat-core.mjs", get(core))
        .route("/chat/chat.mjs", get(script))
        .route("/chat/mark.svg", get(mark))
}

async fn directory(OriginalUri(uri): OriginalUri) -> Response {
    let target = match uri.query() {
        Some(query) => format!("/chat/?{}", query),
        None => "/chat/".to_owned(),
    };
    let mut response = Redirect::permanent(&target).into_response();
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.headers_mut().insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    response
}

fn asset(content_type: &'static str, body: &'static str) -> Response {
    let mut response = body.into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    headers.insert("x-content-type-options", HeaderValue::from_static("nosniff"));
    headers.insert("x-frame-options", HeaderValue::from_static("DENY"));
    headers.insert(
        "content-security-policy",
        HeaderValue::from_static(
            "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; \
             img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        ),
    );
    headers.insert(
        "permissions-policy",
        HeaderValue::from_static("camera=(), microphone=(), geolocation=()"),
    );
    response
}

async fn index() -> Response {
    asset("text/html; charset=utf-8", include_str!("agent_chat/index.html"))
}

async fn styles() -> Response {
    asset("text/css; charset=utf-8", include_str!("agent_chat/chat.css"))
}

async fn core() -> Response {
    asset("text/javascript; charset=utf-8", include_str!("agent_chat/chat-core.mjs"))
}

async fn script() -> Response {
    asset("text/javascript; charset=utf-8", include_str!("agent_chat/chat.mjs"))
}

async fn mark() -> Response {
    asset("image/svg+xml", include_str!("agent_chat/mark.svg"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::{to_bytes, Body}, http::{Request, StatusCode}};
    use tower::ServiceExt;

    #[tokio::test]
    async fn chat_assets_are_embedded_with_security_headers_and_correct_mime() {
        let app: Router = router();
        for (path, mime, marker) in [
            ("/chat/", "text/html; charset=utf-8", "id=\"composer\""),
            ("/chat/chat.css", "text/css; charset=utf-8", "--paper"),
            ("/chat/chat-core.mjs", "text/javascript; charset=utf-8", "class Conversation"),
            ("/chat/chat.mjs", "text/javascript; charset=utf-8", "startPreview"),
            ("/chat/mark.svg", "image/svg+xml", "<svg"),
        ] {
            let response = app.clone().oneshot(Request::builder()
                .uri(path).body(Body::empty()).unwrap()).await.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.headers()[header::CONTENT_TYPE], mime);
            assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
            assert_eq!(response.headers()["referrer-policy"], "no-referrer");
            assert_eq!(response.headers()["x-content-type-options"], "nosniff");
            let csp = response.headers()["content-security-policy"].to_str().unwrap();
            assert!(csp.contains("frame-ancestors 'none'"));
            assert!(!csp.contains("unsafe-inline"));
            let body = to_bytes(response.into_body(), 1_000_000).await.unwrap();
            assert!(String::from_utf8(body.to_vec()).unwrap().contains(marker));
        }
    }

    #[tokio::test]
    async fn chat_only_serves_declared_assets_and_canonicalizes_the_directory() {
        let app: Router = router();
        let redirect = app.clone().oneshot(Request::builder()
            .uri("/chat").body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(redirect.status(), StatusCode::PERMANENT_REDIRECT);
        assert_eq!(redirect.headers()[header::LOCATION], "/chat/");
        let preview = app.clone().oneshot(Request::builder()
            .uri("/chat?preview=1").body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(preview.headers()[header::LOCATION], "/chat/?preview=1");
        for path in ["/chat/secret", "/chat/../main.rs"] {
            let response = app.clone().oneshot(Request::builder()
                .uri(path).body(Body::empty()).unwrap()).await.unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND);
        }
    }
}
