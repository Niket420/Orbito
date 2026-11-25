// Orbito website: release info from GitHub, the hero demo, command tabs and bug reports.

const REPO = "Niket420/Orbito";
const RAW_INSTALL_URL = `https://raw.githubusercontent.com/${REPO}/main/website/install.sh`;

document.documentElement.classList.add("js");
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ---------- Install command ---------- */
// Hosted on our own domain: install.sh lives next to this page. Anywhere else (a local
// preview, GitHub Pages under a path), fall back to the copy in the GitHub repo.
const onOwnDomain = location.protocol === "https:" && !/github\.io$|localhost|127\.0\.0\.1/.test(location.hostname);
const installURL = onOwnDomain ? `${location.origin}/install.sh` : RAW_INSTALL_URL;
const installCommand = `curl -fsSL ${installURL} | bash`;
for (const button of $$("[data-copy]")) {
  button.dataset.copy = installCommand;
  const code = $("code", button);
  code.textContent = button.classList.contains("copy-cmd--block")
    ? installCommand
    : `curl -fsSL ${installURL.replace(/^https:\/\//, "")} | bash`;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
    } catch {
      const range = document.createRange();
      range.selectNodeContents(code);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      return;
    }
    const state = $(".copy-cmd__state", button);
    button.classList.add("is-copied");
    state.textContent = "Copied";
    setTimeout(() => { button.classList.remove("is-copied"); state.textContent = "Copy"; }, 1800);
  });
}

/* ---------- Nav ---------- */
const nav = $(".nav");
const onScroll = () => nav.classList.toggle("is-scrolled", scrollY > 8);
addEventListener("scroll", onScroll, { passive: true });
onScroll();

const menuButton = $(".nav__menu");
const mobileMenu = $("#mobile-menu");
menuButton.addEventListener("click", () => {
  const open = menuButton.getAttribute("aria-expanded") !== "true";
  menuButton.setAttribute("aria-expanded", String(open));
  mobileMenu.hidden = !open;
});
for (const link of $$("a", mobileMenu)) {
  link.addEventListener("click", () => { menuButton.setAttribute("aria-expanded", "false"); mobileMenu.hidden = true; });
}

const navLinks = $$(".nav__links a");
const spy = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    for (const link of navLinks) link.classList.toggle("is-active", link.hash === `#${entry.target.id}`);
  }
}, { rootMargin: "-45% 0px -50% 0px" });
for (const link of navLinks) { const section = $(link.hash); if (section) spy.observe(section); }

/* ---------- Scroll reveal ---------- */
const reveal = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add("is-in");
    reveal.unobserve(entry.target);
  }
}, { rootMargin: "0px 0px -8% 0px" });
$$(".reveal").forEach((el, i) => {
  el.style.transitionDelay = `${Math.min(i % 5, 4) * 60}ms`;
  reveal.observe(el);
});

/* ---------- Count-up ---------- */
const counter = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    counter.unobserve(entry.target);
    const target = Number(entry.target.dataset.count);
    const start = performance.now();
    const tick = (now) => {
      const t = Math.min(1, (now - start) / 900);
      entry.target.textContent = Math.round(target * (1 - Math.pow(1 - t, 3)));
      if (t < 1) requestAnimationFrame(tick);
    };
    reducedMotion ? (entry.target.textContent = target) : requestAnimationFrame(tick);
  }
});
$$("[data-count]").forEach((el) => counter.observe(el));

/* ---------- Latest release from GitHub ---------- */
const escapeHTML = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function loadReleases() {
  let releases;
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=6`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!response.ok) return;
    releases = (await response.json()).filter((r) => !r.draft);
  } catch {
    return;  // offline or rate limited: the page already says "early access"
  }
  const latest = releases.find((r) => !r.prerelease) || releases[0];
  if (!latest) return;

  const asset = latest.assets.find((a) => /\.dmg$/i.test(a.name)) || latest.assets.find((a) => /\.zip$/i.test(a.name));
  const version = latest.tag_name.replace(/^v/i, "");
  $$("[data-version-label]").forEach((el) => (el.textContent = `Version ${version}`));
  const status = $("[data-release-status]");
  status.classList.add("is-live");
  status.textContent = `Latest: version ${version}, released ${new Date(latest.published_at).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" })}.`;

  if (asset) {
    for (const link of $$("[data-download]")) {
      if (link.closest(".nav") || link.hasAttribute("data-download-direct") || link.closest(".hero__cta")) {
        link.href = asset.browser_download_url;
      }
    }
    $$("[data-download-label]").forEach((el) => (el.textContent = `Download for macOS · ${version}`));
  }

  // Real releases go on top of the hand-written history.
  const log = $("[data-changelog]");
  const items = releases.slice(0, 4).map((r) => {
    const date = new Date(r.published_at).toLocaleDateString(undefined, { month: "short", year: "numeric" });
    const notes = (r.body || "").split("\n").map((l) => l.replace(/^[-*#\s]+/, "").trim()).filter(Boolean)[0] || "";
    return `<li><time>${escapeHTML(date)}</time><div><h3>${escapeHTML(r.name || r.tag_name)}</h3>`
      + (notes ? `<p>${escapeHTML(notes.slice(0, 220))}</p>` : "")
      + `<a href="${escapeHTML(r.html_url)}" target="_blank" rel="noopener">Release notes</a></div></li>`;
  });
  log.insertAdjacentHTML("afterbegin", items.join(""));
}
loadReleases();
// Until there's a release, "Download" points at the install section, and the manual link at Releases.
$$("[data-download-direct]").forEach((el) => (el.href = `https://github.com/${REPO}/releases/latest`));

/* ---------- Command catalogue ---------- */
const COMMANDS = {
  "Apps & windows": [
    ["Switch back to Slack", "Brings the app you were just in to the front"],
    ["Put Safari on the left half", "Tiles the window to half the screen"],
    ["Make this full screen", "Toggles full screen for the front window"],
    ["Hide everything else", "Hides every app except the one in front"],
    ["Move this to the other display", "Sends the window to your next screen"],
    ["Force quit Xcode", "Ends a frozen app", true],
  ],
  "Screen & web": [
    ["What's on my screen?", "Reads the front window and answers in the notch"],
    ["Translate the selected text to Hindi", "Reads your selection and translates it"],
    ["Click Sign in", "Finds the button by its label and presses it"],
    ["New tab, then search for flights to Goa", "Runs editing and browser commands in order"],
    ["Screenshot this window", "Saves it to your Desktop"],
    ["Click Delete account", "Buttons like Delete, Buy or Send always ask", true],
  ],
  "Files": [
    ["Open my Downloads folder", "Opens it in Finder"],
    ["Find my resume PDF", "Searches your files with Spotlight"],
    ["Open my resume", "Finds the best match and opens it"],
    ["New folder called Projects on the Desktop", "Creates it and shows it in Finder"],
    ["Delete this file", "Moves the Finder selection to the Trash", true],
    ["What did I copy?", "Reads back the clipboard"],
  ],
  "System": [
    ["Volume 30", "Sets the volume to 30%"],
    ["Make it brighter", "Turns the display brightness up"],
    ["Turn on dark mode", "Switches the system appearance"],
    ["How much battery do I have?", "Answers with the level and charging state"],
    ["Open Bluetooth settings", "Jumps straight to that pane"],
    ["Lock my Mac", "Locks the screen right away", true],
  ],
  "Everyday": [
    ["Remind me at 6 to call mom", "Adds it to Reminders with an alert"],
    ["Set a timer for 10 minutes", "Creates a reminder that goes off in 10 minutes"],
    ["What's on my calendar tomorrow?", "Lists tomorrow's events"],
    ["Note: buy milk and eggs", "Creates a new note in Notes"],
    ["Next song", "Skips the track in whatever is playing"],
    ["Draft an email to Rahul about Friday", "Opens a draft; you press Send yourself"],
  ],
};

const tabs = $("[data-tabs]");
const panel = $("[data-commands]");
function showCategory(name) {
  for (const button of $$("button", tabs)) button.setAttribute("aria-selected", String(button.dataset.name === name));
  panel.innerHTML = COMMANDS[name].map(([say, does, asks], i) =>
    `<div class="cmd" style="animation-delay:${i * 40}ms"><span class="cmd__say">${say}</span>`
    + `<span class="cmd__does">${does}</span>`
    + `<span class="badge${asks ? " badge--ask" : ""}">${asks ? "Asks first" : "Runs right away"}</span></div>`).join("");
}
tabs.innerHTML = Object.keys(COMMANDS).map((name) =>
  `<button role="tab" data-name="${name}" aria-selected="false">${name}</button>`).join("");
tabs.addEventListener("click", (event) => {
  const button = event.target.closest("button");
  if (button) showCategory(button.dataset.name);
});
tabs.addEventListener("keydown", (event) => {
  if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
  const buttons = $$("button", tabs);
  const index = buttons.findIndex((b) => b.getAttribute("aria-selected") === "true");
  const next = buttons[(index + (event.key === "ArrowRight" ? 1 : buttons.length - 1)) % buttons.length];
  next.focus();
  showCategory(next.dataset.name);
});
showCategory(Object.keys(COMMANDS)[0]);

/* ---------- Robot ---------- */
const bot = $("[data-bot]");
const eyes = { l: $('[data-eye="l"]'), r: $('[data-eye="r"]') };
const EYE_SHAPES = {  // width, height, corner radius (centred on the eye's spot)
  idle: [16, 24, 8], listening: [20, 20, 10], thinking: [15, 19, 7.5],
  executing: [22, 9, 4.5], waiting: [22, 22, 11], completed: [22, 8, 4], error: [20, 6, 3],
};
const EYE_CENTRES = { l: [96, 110], r: [144, 110] };
let lookX = 0, lookY = 0;

function drawEyes() {
  const [w, h, r] = EYE_SHAPES[bot.dataset.state] || EYE_SHAPES.idle;
  const lift = bot.dataset.state === "thinking" ? -5 : 0;
  for (const side of ["l", "r"]) {
    const [cx, cy] = EYE_CENTRES[side];
    const eye = eyes[side];
    eye.setAttribute("x", cx - w / 2 + lookX);
    eye.setAttribute("y", cy - h / 2 + lookY + lift);
    eye.setAttribute("width", w);
    eye.setAttribute("height", h);
    eye.setAttribute("rx", r);
  }
}
function setBotState(state) {
  bot.dataset.state = state;
  drawEyes();
}
// The eyes follow the pointer a little.
addEventListener("pointermove", (event) => {
  const box = bot.getBoundingClientRect();
  const dx = event.clientX - (box.left + box.width / 2);
  const dy = event.clientY - (box.top + box.height * 0.45);
  const distance = Math.hypot(dx, dy) || 1;
  const pull = Math.min(1, distance / 400);
  lookX = (dx / distance) * 6 * pull;
  lookY = (dy / distance) * 4 * pull;
  drawEyes();
}, { passive: true });
(async function blink() {
  while (!reducedMotion) {
    await sleep(2400 + Math.random() * 2400);
    bot.classList.add("is-blinking");
    await sleep(120);
    bot.classList.remove("is-blinking");
  }
})();
drawEyes();

/* ---------- Hero demo ---------- */
const notch = $("[data-notch]");
const notchTitle = $("[data-notch-title]");
const notchTrail = $("[data-notch-trail]");
const notchExtra = $("[data-notch-extra]");
const caption = $(".caption");
const captionText = $("[data-caption]");
const winA = $("[data-win-a]");
const winB = $("[data-win-b]");

const TRAIL = {
  listening: '<span class="wavebar"><i></i><i></i><i></i><i></i><i></i></span>',
  working: '<span class="dots"><i></i><i></i><i></i></span>',
  done: '<span class="ok-icon"></span>',
  approval: '<span class="hand-icon"></span>',
};

function setNotch(phase, title = "", trail = "", extra = "") {
  notch.dataset.phase = phase;
  notch.dataset.extra = String(Boolean(extra));
  notchTitle.textContent = title;
  notchTrail.innerHTML = trail;
  notchExtra.innerHTML = extra;
}

async function say(text) {
  caption.classList.add("is-on");
  captionText.textContent = "";
  for (const char of text) {
    captionText.innerHTML = `${escapeHTML(captionText.textContent + char)}<span class="cursor"></span>`;
    await sleep(reducedMotion ? 0 : 38 + Math.random() * 40);
  }
  captionText.textContent = text;
}

const SCENES = [
  {
    speech: "Put Safari on the left half",
    steps: [["Switch to Safari"], ["Window: left half", () => winA.classList.add("is-left")]],
    result: "Done. Safari is on the left.",
  },
  {
    speech: "What's on my screen?",
    steps: [["Read the screen", () => winA.classList.add("is-reading")]],
    result: "An article on the rise and fall of Nokia.",
    after: () => winA.classList.remove("is-reading"),
  },
  {
    speech: "Delete this file",
    approval: "Allow: Move the selected item to the Trash?",
    reply: "Yes",
    steps: [["Move to Trash", () => winB.classList.add("is-hidden")]],
    result: "Moved 1 item to the Trash.",
  },
  {
    speech: "Remind me in 10 minutes to stretch",
    steps: [["Add reminder"]],
    result: () => `I'll remind you at ${new Date(Date.now() + 600000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}.`,
  },
];

async function playScene(scene) {
  setBotState("listening");
  setNotch("listening", "Listening…", TRAIL.listening);
  await sleep(500);
  await say(scene.speech);
  await sleep(700);

  setNotch("confirming", `“${scene.speech}”`, "", '<div class="countdown"><i></i></div>');
  await sleep(1200);

  caption.classList.remove("is-on");
  setBotState("thinking");
  setNotch("thinking", "Thinking…", TRAIL.working);
  await sleep(1300);

  if (scene.approval) {
    setBotState("waiting");
    setNotch("approval", scene.approval, TRAIL.approval,
      '<div class="notch__buttons"><span>Deny · say “no”</span><span class="allow">Allow · say “yes”</span></div>');
    await sleep(900);
    setBotState("listening");
    await say(scene.reply);
    $(".notch__buttons .allow")?.classList.add("is-pressed");
    await sleep(500);
    caption.classList.remove("is-on");
  }

  setBotState("executing");
  for (const [title, effect] of scene.steps) {
    setNotch("working", title, TRAIL.working);
    await sleep(450);
    effect?.();
    await sleep(650);
  }

  setBotState("completed");
  setNotch("done", typeof scene.result === "function" ? scene.result() : scene.result, TRAIL.done);
  await sleep(2600);
  scene.after?.();
  setNotch("hidden");
  setBotState("idle");
}

async function resetWindows() {
  winA.classList.remove("is-left", "is-reading");
  winB.classList.remove("is-hidden");
}

let demoRunning = false;
async function runDemo() {
  if (demoRunning) return;
  demoRunning = true;
  for (let i = 0; ; i = (i + 1) % SCENES.length) {
    if (i === 0) await resetWindows();
    await sleep(1100);
    await playScene(SCENES[i]);
  }
}

const clock = $("[data-clock]");
const updateClock = () => {
  clock.textContent = new Date().toLocaleTimeString([], { weekday: "short", hour: "numeric", minute: "2-digit" });
};
updateClock();
setInterval(updateClock, 30000);

if (reducedMotion) {
  setNotch("done", "Done. Safari is on the left.", TRAIL.done);
  setBotState("completed");
} else {
  new IntersectionObserver((entries, observer) => {
    if (entries.some((e) => e.isIntersecting)) { observer.disconnect(); runDemo(); }
  }).observe($(".screen"));
}

/* ---------- Bug report → pre-filled GitHub issue ---------- */
const form = $("[data-bug-form]");
const formError = $("[data-form-error]");
const KIND_LABELS = { bug: "bug", speech: "speech", crash: "crash", install: "install", idea: "enhancement" };

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const data = Object.fromEntries(new FormData(form));
  const title = data.title.trim();
  const titleInput = form.elements.title;
  if (!title) {
    titleInput.setAttribute("aria-invalid", "true");
    formError.textContent = "Add a short title so we know what this is about.";
    titleInput.focus();
    return;
  }
  titleInput.removeAttribute("aria-invalid");
  formError.textContent = "";

  const kind = form.elements.kind.selectedOptions[0].textContent;
  const body = [
    `**Type:** ${kind}`,
    "",
    "### What I said and what happened",
    data.what.trim() || "_Not filled in_",
    "",
    "### What I expected",
    data.expected.trim() || "_Not filled in_",
    "",
    "### Environment",
    `- macOS: ${data.macos}`,
    `- Orbito version: ${data.version.trim() || "unknown"}`,
    `- App in front: ${data.app.trim() || "not given"}`,
    "",
    "<!-- Screenshots or the relevant lines of ~/Library/Application Support/Orbito/backend.log help a lot. -->",
  ].join("\n");

  const url = new URL(`https://github.com/${REPO}/issues/new`);
  url.searchParams.set("title", title);
  url.searchParams.set("body", body);
  url.searchParams.set("labels", KIND_LABELS[data.kind] || "bug");
  window.open(url.toString(), "_blank", "noopener");
});
form.elements.title.addEventListener("input", (event) => {
  if (event.target.value.trim()) { event.target.removeAttribute("aria-invalid"); formError.textContent = ""; }
});
