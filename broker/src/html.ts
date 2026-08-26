// No client-side JS on purpose: a plain <form method="post"> is what lets
// SameSite=Lax plus an Origin check carry the whole CSRF story.

const STYLE = `
  :root { color-scheme: light dark; }
  body { font: 16px/1.6 ui-sans-serif, system-ui, -apple-system, sans-serif;
         max-width: 34rem; margin: 4rem auto; padding: 0 1.5rem; }
  h1 { font-size: 1.4rem; margin-bottom: .25rem; }
  .sub { opacity: .7; font-size: .9rem; margin-top: 0; }
  form { margin: 1.5rem 0 0; }
  textarea { width: 100%; box-sizing: border-box; min-height: 6rem; padding: .6rem;
             font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
             border: 1px solid currentColor; border-radius: 6px; background: transparent;
             color: inherit; }
  button { font: inherit; padding: .5rem 1.1rem; border-radius: 6px; cursor: pointer;
           border: 1px solid currentColor; background: transparent; color: inherit; }
  code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
  .ok { color: #1a7f37; }
  .bad { color: #b3261e; }
`;

const ESCAPES: Record<string, string> = {
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
};

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ESCAPES[c] as string);
}

function page(body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude review token</title><style>${STYLE}</style></head>
<body><h1>Claude review token</h1>${body}</body></html>`;
}

const PASTE_FORM = `
  <form method="post" action="/token">
    <textarea name="token" required placeholder="sk-ant-oat…" autocomplete="off" spellcheck="false"></textarea>
    <p><button type="submit">Save</button></p>
  </form>`;

export type Notice = "malformed" | null;

export function signInPage(): string {
  return page(
    `<p class="sub">Register the Claude seat your <code>/review</code> runs draw on.</p>
     <form method="get" action="/login"><button type="submit">Sign in with GitHub</button></form>`,
  );
}

export function statusPage(login: string, createdAt: Date | undefined, notice: Notice): string {
  const who = `<p class="sub">Signed in as <strong>${escapeHtml(login)}</strong>.</p>`;
  // Honest copy: nothing was checked against Anthropic, only the shape.
  const problem =
    notice === "malformed"
      ? `<p class="bad"><strong>That doesn't look like a token.</strong> <code>claude setup-token</code>
         prints one long value with no spaces — paste all of it.</p>`
      : "";

  if (!createdAt) {
    return page(
      `${who}${problem}
       <p><strong>No token registered.</strong> Reviews you request with <code>/review</code>
       will fail until you add one. Run <code>claude setup-token</code> locally and paste the output.</p>
       ${PASTE_FORM}`,
    );
  }

  const added = createdAt.toLocaleDateString("en-GB", { day: "numeric", month: "short" });
  return page(
    `${who}${problem}
     <p class="ok"><strong>Token registered ✓</strong> — added ${escapeHtml(added)}</p>
     <details><summary>Replace</summary>${PASTE_FORM}</details>
     <form method="post" action="/token/delete"><button type="submit">Remove</button></form>`,
  );
}
