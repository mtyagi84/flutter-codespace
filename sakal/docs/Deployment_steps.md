# Deploying SAKAL to Cloudflare (Worker with static assets)

`sakal-erp` is a **Cloudflare Worker with static assets**, not a Cloudflare Pages project.
Config lives in `sakal/wrangler.jsonc`:

```json
{
  "name": "sakal-erp",
  "compatibility_date": "2026-08-09",
  "assets": { "directory": "build/web" }
}
```

Live at `https://sakal-erp.mtyagi84.workers.dev` (plus one custom domain bound in the dashboard).
Always use `wrangler deploy` — never `wrangler pages deploy`, which targets a different
Cloudflare product and will try to create an unrelated new Pages project instead of
updating this Worker.

## One-time setup (already done, kept here for reference)

API credentials are stored as **GitHub Codespaces secrets** (`CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_ACCOUNT_ID`) — https://github.com/settings/codespaces (or the repo's own
Settings → Secrets and variables → Codespaces). GitHub injects them as environment
variables automatically every time a Codespace for this repo starts — no `export`
needed, and the token never lives in any file in this repo. If a Codespace was already
running when the secrets were added, stop/rebuild it once to pick them up.

`wrangler login`'s browser OAuth flow does not work reliably in a headless Codespace
(no browser to auto-open `xdg-open`, and the callback can't always reach back into the
container) — the API-token env vars above are what `wrangler` actually authenticates
with instead; no interactive login step is needed at all.

## Every deploy — 4 commands

```bash
cd /workspaces/flutter-codespace/sakal
git pull
flutter clean && flutter pub get
flutter build web --release --no-wasm-dry-run
wrangler deploy
```

`--no-wasm-dry-run` skips an extra, purely informational compile pass (checking
whether this app could theoretically also target WebAssembly — irrelevant, since we
only ever ship the normal JS build). That pass has been getting killed (exit -15,
i.e. SIGTERM) on this Codespace's memory budget, taking the whole build down with
it even though the real build would have succeeded — always pass this flag here.

No flags needed on `wrangler deploy` — `wrangler.jsonc` already declares the Worker
name and the assets directory. Don't add `--base-href` to the build unless you've
deliberately configured Cloudflare to serve this app under a subpath — a Worker/Pages
site is served from its own domain root by default, so the build's default (`/`) is
correct almost always.

## Verify after every deploy

1. Open the live URL, hard refresh (Ctrl+Shift+R) to bypass any stale cached version.
2. Spot-check the app visually — icons, a couple of screens.
3. If something looks wrong: DevTools → Network tab → reload → check for any 404,
   especially `assets/fonts/MaterialIcons-Regular.otf` (icon font) or
   `assets/FontManifest.json`.

## If you ever need to sanity-check the build BEFORE deploying

Isolates "is this a build problem or a deploy problem":

```bash
cd build/web
python3 -m http.server 8000
```

Open the Codespace's forwarded port 8000. If something's broken here too, it's a
build/pubspec issue, not a deploy one.

## Real bug fixed here (2026-09-06), for reference

Icons were missing on the live site despite the build itself being correct — traced
to `wrangler deploy` never having actually pushed a current `assets/fonts/
MaterialIcons-Regular.otf` (the previous deploy process, using the wrong `wrangler
pages deploy` command against the wrong product, wasn't updating this Worker at all).
Confirmed fixed: the corrective `wrangler deploy` run explicitly listed
`assets/fonts/MaterialIcons-Regular.otf` as one of only 4 newly-uploaded files.

Where to put the API token safely: GitHub Codespaces secrets
Instead of exporting it manually every session (or worse, saving it in a repo file), store it once as a Codespaces secret — GitHub injects it automatically as an environment variable every time a Codespace for this repo starts, and it never touches any file in git.

Go to https://github.com/settings/codespaces (your personal secrets) — or if you want it scoped to just this repo, go to the repo itself → Settings → Secrets and variables → Codespaces.
Click New secret.
Name: CLOUDFLARE_API_TOKEN, Value: your token.
Repeat for CLOUDFLARE_ACCOUNT_ID.
Under "Repository access," make sure it's enabled for flutter-codespace (your repo).
Stop and restart your Codespace (or rebuild it) — secrets are only injected at Codespace start, not into an already-running one.
Once that's done, every future Codespace session already has both variables set — no export needed, ever again.

Since the token that's currently sitting in your Deployment_steps.md history (and was pasted here) was exposed in plaintext, it's worth a 30-second regenerate even for a test env — Cloudflare dashboard → API Tokens → find it → Roll (or delete and create a new one), then update the Codespaces secret with the new value. Your call, not pushing on it further either way.

Next-time deployment steps (clean version)

cd /workspaces/flutter-codespace/sakal
git pull
flutter clean && flutter pub get
flutter build web --release
wrangler deploy
That's it — no wrangler login, no exporting tokens (Codespaces secret handles that), no --project-name flag (already in wrangler.jsonc). Then hard-refresh the live URL and spot-check it once.

Let me update your notes file to reflect this as the final, clean process:
