import CryptoKit
import Foundation

/// The web page clients open: title, player, download button.
/// Everything user-provided is HTML-escaped; the page loads no third-party scripts.
enum SharePage {
    /// The page's only script: the Copy link button. Allowed by its hash in the CSP, so nothing else can run.
    static let copyScript = "(function(){var b=document.getElementById('copy');if(!b||!navigator.clipboard)return;b.hidden=false;b.addEventListener('click',function(){navigator.clipboard.writeText(location.href).then(function(){b.textContent='Link copied';setTimeout(function(){b.textContent='Copy link'},2000)})})})();"
    static var copyScriptHash: String {
        Data(SHA256.hash(data: Data(copyScript.utf8))).base64EncodedString()
    }

    static func html(title: String, videoURL: String, posterURL: String?, downloadName: String,
                     duration: TimeInterval, recordedAt: Date, width: Int, height: Int) -> String {
        let t = HTML.escape(title)
        let v = HTML.escape(videoURL)
        let p = posterURL.map(HTML.escape)
        let dateText = HTML.escape(recordedAt.formatted(date: .long, time: .shortened))
        let ratio = (width > 0 && height > 0) ? "\(width) / \(height)" : "16 / 9"
        let og = p.map { """
        <meta property="og:image" content="\($0)">
        <meta name="twitter:image" content="\($0)">
        """ } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex, nofollow">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-\(copyScriptHash)'; media-src * blob:; img-src * data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer">
        <title>\(t)</title>
        <meta property="og:title" content="\(t)">
        <meta property="og:type" content="video.other">
        <meta property="og:video" content="\(v)">
        <meta name="twitter:card" content="summary_large_image">
        \(og)
        <style>
          :root { --bg:#f6f6f4; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:rgba(0,0,0,.08); --accent:#2e6bd3; }
          @media (prefers-color-scheme: dark) { :root { --bg:#121214; --card:#1c1c1f; --text:#f5f5f7; --muted:#a1a1a6; --line:rgba(255,255,255,.1); } }
          * { box-sizing: border-box; }
          body { margin:0; background:var(--bg); color:var(--text); font:16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
          main { max-width: 1120px; margin: 0 auto; padding: 28px 20px 48px; }
          h1 { font-size: clamp(22px, 3vw, 30px); line-height:1.2; margin: 0 0 6px; word-wrap: break-word; }
          .meta { color: var(--muted); font-size: 14px; margin-bottom: 18px; }
          .player { background:#000; border-radius: 14px; overflow:hidden; box-shadow: 0 10px 40px rgba(0,0,0,.18); aspect-ratio: \(ratio); max-height: 80vh; margin: 0 auto; }
          video { width:100%; height:100%; display:block; background:#000; }
          .bar { display:flex; gap:12px; align-items:center; justify-content:space-between; flex-wrap:wrap; margin-top: 16px; }
          .btn { display:inline-flex; cursor:pointer; font-family:inherit; align-items:center; gap:8px; padding:10px 16px; border-radius:10px; background:var(--card); color:var(--text); text-decoration:none; border:1px solid var(--line); font-weight:600; font-size:14px; }
          .btn:hover { border-color: var(--accent); }
          .actions { display:flex; gap:8px; flex-wrap:wrap; }
          .btn.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
          footer { color: var(--muted); font-size: 13px; }
          footer a { color: var(--accent); text-decoration: none; font-weight: 600; }
          footer a:hover { text-decoration: underline; }
        </style>
        </head>
        <body>
        <main>
          <h1>\(t)</h1>
          <div class="meta">\(dateText) · \(Format.duration(duration))</div>
          <div class="player">
            <video controls playsinline preload="metadata"\(p.map { " poster=\"\($0)\"" } ?? "")>
              <source src="\(v)" type="video/mp4">
              Your browser can't play this video. <a href="\(v)">Download it</a>.
            </video>
          </div>
          <div class="bar">
            <div class="actions">
              <a class="btn" href="\(v)" download="\(HTML.escape(downloadName))">⬇︎ Download</a>
              <button class="btn primary" id="copy" type="button" hidden>Copy link</button>
            </div>
            <footer>Recorded with <a href="https://github.com/shiblucu/TRecShare" target="_blank" rel="noopener noreferrer">TRecShare</a></footer>
          </div>
        </main>
        <script>\(copyScript)</script>
        </body>
        </html>
        """
    }
}
