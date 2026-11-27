# Orbito website

The download page for Orbito: plain HTML, CSS and JavaScript, no build step.

| File | What it is |
|---|---|
| `index.html` | The page |
| `styles.css` | Styles (black and graphite, orange accent) |
| `main.js` | The waitlist, the hero demo, command tabs, bug reports |
| `install.sh` | The one-line installer for when Orbito is public (not linked from the page yet) |
| `favicon.svg` | Tab icon |

**Preview locally:** `python3 -m http.server 8787 --directory website`, then open http://127.0.0.1:8787.

**Deploy:** on Vercel or Netlify, import the repo and set the root directory to `website` (no build
command). On your own domain, the install command automatically points at `<your domain>/install.sh`;
anywhere else it uses the copy in this repo on GitHub.

**Waitlist:** sign-ups go to a free [Formspree](https://formspree.io) form. Create a form there,
copy its ID (the part after `/f/` in the endpoint) into `WAITLIST_FORM_ID` at the top of `main.js`,
and submissions arrive in your Formspree dashboard and email. A hidden field filters out simple bots.

**Launch day:** swap the waitlist for download buttons and link `install.sh`, which installs the
latest GitHub release's `Orbito-<version>.zip`.

**Source code links** (the GitHub icon in the nav, "View the code" in the hero and "Source code" in
the footer) carry `data-code-soon` and open a "the code isn't public yet, join the waitlist" popup.
When you open-source the repo, point them at `https://github.com/Niket420/Orbito` and remove
`data-code-soon`.

**Bug reports** open a pre-filled GitHub issue in a new tab; nothing is sent from the page itself.
