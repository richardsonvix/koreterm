# koreterm.com

Static site for `koreterm.com`, deployed to Cloudflare Pages. Hand-written
HTML, one stylesheet, four small ES modules, no framework and no npm
dependencies.

| File              | Purpose                                               |
| ----------------- | ----------------------------------------------------- |
| `index.html`      | Landing page                                          |
| `why-koreterm.html` | About page: identity, measurements, verification      |
| `404.html`        | Not-found page                                        |
| `styles.css`      | Whole stylesheet, `nc-` prefixed classes              |
| `app.js`          | Theme toggle; the 404 page's requested-path text      |
| `version.js`      | Latest-release fetch for the version text             |
| `install.js`      | Clipboard copy for the install commands               |
| `terminal.js`     | Scripted hero demo (also imported by the tests)       |
| `assets/`         | Favicon, self-hosted fonts, app captures, social card |
| `tests/`          | `node --test` units                                   |
| `_headers`        | Cloudflare Pages cache and security headers           |

## Editing

1. Edit the HTML, CSS, or JS.
2. Run `node scripts/build-site-assets.mjs` from the repo root. It rewrites
   the `?v=` cache keys and the CSP hash for the shared inline theme
   bootstrap, which must stay byte-identical on every page.
3. Run the checks:

```powershell
node --test site/tests/*.test.mjs
```

The copy checks fail on claims the project cannot back: package-manager
commands that are not published yet, DirectX wording for the terminal
renderer, wrong config paths, silent-update wording, parity claims, and any
cross-terminal performance claim. `tests/trust.test.mjs` pins the
trust page's stated limits so they cannot be softened by accident. Marketing
copy is checked against `README.md`, `docs/status.md`,
`docs/getting-started.md`, `docs/verify-release.md`, and the two migration
guides; when they disagree, tighten the site until the claim holds.

The CSP allows no inline event handlers, and its only third-party origin is
`https://api.github.com` for the GitHub Releases version fetch, which is the
only outbound request. Fonts and images are self-hosted.

## Design

The page is chrome and the terminal is the content. Everything outside a
terminal window uses the shadcn zinc scale: the tokens at the top of
`styles.css` carry a light and a dark value through `light-dark()`. The only
color on the site is inside terminal windows, taken from koreterm's default
colors (dark) and the GitHub Light Default theme (light). Light and dark
follow the visitor's system until they press the toggle, which then sticks.

Geist sets all text and JetBrains Mono sets commands and terminals. Both are
self-hosted, OFL-licensed, and ship with their licenses. `geist.woff2` is
`Geist-Variable` from the `geist` npm package 1.8.1, instanced to weights
400 to 600 and subset to Latin with fontTools, keeping its name records.
`OFL-Geist.txt` is `OFL.txt` from `vercel/geist-font`, whose copyright notice
is the one in the font; the npm package's own `LICENSE.txt` carries an older
notice.

Only the hero demo moves. It pauses off-screen and in hidden tabs, and under
`prefers-reduced-motion` it shows still frames that the step buttons switch
between. Its palette rows, their order and the status line copy what the app
showed for "split" in the captures. `tests/terminal.test.mjs` checks each
row's title, description, action and shown shortcut, the status format, and
every key chip on the landing page against `src/input/command.zig`,
`src/cli/testdata/default_keybinds_windows.txt` and
`src/apprt/win32/overlay_view.zig`; `tests/demo.test.mjs` runs the demo itself
against a fake DOM and a hand-advanced clock (pause, resume, step switches,
a hidden page, reduced motion); `tests/install.test.mjs` checks that each copy
button copies the command shown beside it.

The `shot-*.webp` files are real captures of the app, one per theme, from a
build with renderer test tools on a private desktop: the panes come from the
app's own readback and the chrome from `PrintWindow`. The restored-session
shots come from a real restart of that copy with
`window-save-state-scrollback` set, each pane scrolled to the top. The
terminal content is staged (a demo repository with a placeholder author), and
the terminal shots are cropped to their top 600 rows. The social card,
`koreterm-social.jpg`, is rendered from HTML around one of the captures.

## Deployment

koreterm does not deploy this site. The Cloudflare Pages workflow came from the
project koreterm is forked from and was removed with its release-copy checks.
