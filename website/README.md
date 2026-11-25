# Orbito website

The download page for Orbito: plain HTML, CSS and JavaScript, no build step.

| File | What it is |
|---|---|
| `index.html` | The page |
| `styles.css` | Styles (black and graphite, orange accent) |
| `main.js` | Latest release from the GitHub API, the hero demo, command tabs, bug reports |
| `install.sh` | The one-line installer (`curl -fsSL …/install.sh \| bash`) |
| `favicon.svg` | Tab icon |

**Preview locally:** `python3 -m http.server 8787 --directory website`, then open http://127.0.0.1:8787.

**Deploy:** on Vercel or Netlify, import the repo and set the root directory to `website` (no build
command). On your own domain, the install command automatically points at `<your domain>/install.sh`;
anywhere else it uses the copy in this repo on GitHub.

**Releases:** the page reads `Niket420/Orbito` releases. Until the first one exists it says "Early
access". Once a release has an `Orbito-<version>.zip` (and optionally `Orbito-<version>.zip.sha256`),
the Download buttons, the version label, the changelog and `install.sh` all pick it up automatically.

**Bug reports** open a pre-filled GitHub issue in a new tab; nothing is sent from the page itself.
