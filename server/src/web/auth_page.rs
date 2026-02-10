/// Render the HTML fallback page for auth grant/deny.
///
/// This page is shown when the Astation macOS app is not reachable locally,
/// allowing the user to grant or deny access via a web browser.
pub fn render_auth_page(session_id: &str, hostname: &str, otp: &str) -> String {
    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Astation Auth</title>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, sans-serif;
            background: #0a0a0a;
            color: #e0e0e0;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            padding: 20px;
        }}
        .container {{
            background: #1a1a2e;
            border-radius: 16px;
            padding: 48px;
            max-width: 480px;
            width: 100%;
            text-align: center;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
        }}
        h1 {{
            font-size: 24px;
            margin-bottom: 8px;
            color: #ffffff;
        }}
        .subtitle {{
            font-size: 16px;
            color: #888;
            margin-bottom: 32px;
        }}
        .hostname {{
            color: #64b5f6;
            font-weight: 600;
        }}
        .otp-display {{
            font-size: 48px;
            font-weight: 700;
            letter-spacing: 8px;
            color: #ffffff;
            background: #16213e;
            border-radius: 12px;
            padding: 24px;
            margin: 24px 0;
            font-family: 'SF Mono', 'Fira Code', monospace;
        }}
        .otp-label {{
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 2px;
            color: #666;
            margin-bottom: 8px;
        }}
        .buttons {{
            display: flex;
            gap: 16px;
            margin-top: 32px;
        }}
        .btn {{
            flex: 1;
            padding: 14px 24px;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
        }}
        .btn:disabled {{
            opacity: 0.5;
            cursor: not-allowed;
        }}
        .btn-grant {{
            background: #4caf50;
            color: white;
        }}
        .btn-grant:hover:not(:disabled) {{
            background: #43a047;
        }}
        .btn-deny {{
            background: #f44336;
            color: white;
        }}
        .btn-deny:hover:not(:disabled) {{
            background: #e53935;
        }}
        .status {{
            margin-top: 24px;
            padding: 12px;
            border-radius: 8px;
            display: none;
        }}
        .status.granted {{
            display: block;
            background: #1b5e20;
            color: #a5d6a7;
        }}
        .status.denied {{
            display: block;
            background: #b71c1c;
            color: #ef9a9a;
        }}
        .status.expired {{
            display: block;
            background: #4a4a00;
            color: #fff9c4;
        }}
        .download-link {{
            margin-top: 32px;
            padding-top: 24px;
            border-top: 1px solid #333;
        }}
        .download-link a {{
            color: #64b5f6;
            text-decoration: none;
        }}
        .download-link a:hover {{
            text-decoration: underline;
        }}
        #status-text {{
            display: none;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Astation Auth</h1>
        <p class="subtitle">
            <strong>Atem</strong> on <span class="hostname">{hostname}</span> is requesting access
        </p>

        <div class="otp-label">Verification Code</div>
        <div class="otp-display">{otp}</div>

        <div class="buttons" id="buttons">
            <button class="btn btn-grant" id="grant-btn" onclick="grantAccess()">Grant Access</button>
            <button class="btn btn-deny" id="deny-btn" onclick="denyAccess()">Deny</button>
        </div>

        <div class="status" id="status-box">
            <span id="status-text"></span>
        </div>

        <div class="download-link">
            <p>For a better experience, <a href="https://astation.agora.build/download">download the Astation macOS app</a>.</p>
        </div>
    </div>

    <script>
        const sessionId = "{session_id}";
        const otp = "{otp}";
        let polling = true;

        async function grantAccess() {{
            const grantBtn = document.getElementById('grant-btn');
            const denyBtn = document.getElementById('deny-btn');
            grantBtn.disabled = true;
            denyBtn.disabled = true;

            try {{
                const resp = await fetch(`/api/sessions/${{sessionId}}/grant`, {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }},
                    body: JSON.stringify({{ otp: otp }})
                }});

                if (resp.ok) {{
                    showStatus('granted', 'Access granted successfully.');
                    polling = false;
                }} else {{
                    const data = await resp.json();
                    showStatus('denied', data.error || 'Failed to grant access.');
                    grantBtn.disabled = false;
                    denyBtn.disabled = false;
                }}
            }} catch (e) {{
                showStatus('denied', 'Network error. Please try again.');
                grantBtn.disabled = false;
                denyBtn.disabled = false;
            }}
        }}

        async function denyAccess() {{
            const grantBtn = document.getElementById('grant-btn');
            const denyBtn = document.getElementById('deny-btn');
            grantBtn.disabled = true;
            denyBtn.disabled = true;

            try {{
                await fetch(`/api/sessions/${{sessionId}}/deny`, {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }}
                }});
                showStatus('denied', 'Access denied.');
                polling = false;
            }} catch (e) {{
                showStatus('denied', 'Network error. Please try again.');
                grantBtn.disabled = false;
                denyBtn.disabled = false;
            }}
        }}

        function showStatus(type, message) {{
            const box = document.getElementById('status-box');
            const text = document.getElementById('status-text');
            box.className = 'status ' + type;
            text.textContent = message;
            text.style.display = 'inline';
            document.getElementById('buttons').style.display = 'none';
        }}

        // Auto-refresh: poll session status every 2 seconds
        async function checkStatus() {{
            if (!polling) return;

            try {{
                const resp = await fetch(`/api/sessions/${{sessionId}}/status`);
                if (resp.ok) {{
                    const data = await resp.json();
                    if (data.status === 'granted') {{
                        showStatus('granted', 'Access has been granted.');
                        polling = false;
                    }} else if (data.status === 'denied') {{
                        showStatus('denied', 'Access has been denied.');
                        polling = false;
                    }} else if (data.status === 'expired') {{
                        showStatus('expired', 'Session has expired. Please request a new session.');
                        polling = false;
                    }}
                }}
            }} catch (e) {{
                // Silently continue polling
            }}
        }}

        setInterval(checkStatus, 2000);
    </script>
</body>
</html>"#,
        hostname = hostname,
        otp = otp,
        session_id = session_id,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_auth_page_contains_hostname() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.contains("my-machine"));
    }

    #[test]
    fn test_render_auth_page_contains_otp() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.contains("12345678"));
    }

    #[test]
    fn test_render_auth_page_contains_session_id() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.contains("test-session-id"));
    }

    #[test]
    fn test_render_auth_page_contains_title() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.contains("<title>Astation Auth</title>"));
    }

    #[test]
    fn test_render_auth_page_contains_grant_button() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.contains("Grant Access"));
    }

    #[test]
    fn test_render_auth_page_contains_deny_button() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.contains("Deny"));
    }

    #[test]
    fn test_render_auth_page_contains_download_link() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.contains("download the Astation macOS app"));
    }

    #[test]
    fn test_render_auth_page_is_valid_html() {
        let html = render_auth_page("test-session-id", "my-machine", "12345678");
        assert!(html.starts_with("<!DOCTYPE html>"));
        assert!(html.contains("</html>"));
    }
}
