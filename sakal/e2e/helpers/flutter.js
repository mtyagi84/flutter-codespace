// Flutter Web renders everything to a <canvas> by default — nothing is
// visible to Playwright's text/role-based selectors until the app's
// accessibility (semantics) tree is turned on. Flutter auto-injects a tiny,
// normally-invisible "enable accessibility" placeholder element once the
// engine has booted far enough to be ready for it; triggering it turns on
// the real semantics DOM overlay, after which getByText/getByRole work
// normally.
//
// Confirmed by direct inspection (2026-10-11):
//   - The placeholder (`<flt-semantics-placeholder role="button"
//     tabindex="0" aria-label="Enable accessibility">`) is positioned at
//     `left:-1px; top:-1px; width:1px; height:1px` — genuinely off-viewport
//     on purpose (assistive tech only, never a sighted mouse user). A real
//     Playwright mouse click (even `force: true`) resolves to a
//     coordinate-based CDP event at (-1,-1); `elementFromPoint` returns
//     null outside the viewport, so the event hits nothing and silently
//     no-ops. A synthetic `dispatchEvent(new MouseEvent('click'))` also
//     silently no-ops — Flutter's own listener needs a real activation,
//     which the element's native `.click()` DOM method satisfies.
//   - The element does not exist in the DOM at all until the engine has
//     booted far enough to create it — on a fresh page load of a sizeable
//     release build (CanvasKit + the compiled app bundle), that can take
//     several real seconds. Checking for it too early and concluding
//     "already enabled, nothing to click" (absent == done) was the actual
//     bug in an earlier version of this helper: it raced the engine boot,
//     "finished" having clicked nothing, and the real placeholder only
//     appeared afterwards, already too late for the caller's next
//     assertion.
async function enableSemantics(page) {
  const placeholder = await page
    .waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 30000 })
    .catch(() => null);

  if (!placeholder) return; // never appeared — already enabled, or a non-Chromium path

  await page.evaluate((el) => el.click(), placeholder);

  await page
    .waitForSelector('flt-semantics-placeholder', { state: 'detached', timeout: 10000 })
    .catch(() => {});

  // Let the semantics host finish populating real content after the
  // placeholder is gone.
  await page.waitForTimeout(300);
}

// Confirmed by direct inspection (2026-10-11): once semantics is enabled,
// Flutter's CanvasKit renderer still paints all actual pixels to a canvas
// — there is no real DOM text content for MOST widgets, only the
// `aria-label` Flutter writes onto each `<flt-semantics>` node for
// assistive tech (nearby Text widgets are frequently MERGED into one
// node's combined aria-label — e.g. a heading + its body paragraph can
// appear as a single accessible name). `page.getByText(...)` can't see
// any of that.
//
// BUT a later phase found this isn't universal: some widgets (e.g. a
// plain centered error/placeholder `Text`, confirmed live on New Sale's
// "No shift is open on this till." guard) render as a REAL DOM text node
// instead — confirmed via Playwright's own accessibility snapshot showing
// `text: ...` rather than a `[aria-label]` attribute on a group/heading.
// Flutter's semantics-merging behavior is widget-structure-dependent, not
// predictable from the outside, so match BOTH forms rather than guessing
// per screen: `:text()` is Playwright's own substring text-content
// selector (comma = OR, same as CSS).
// Real bug found live (2026-10-11): Flutter's own screen-reader live-region
// announcement of a snackbar message (a `<flt-announcement-polite>` element,
// permanently off-screen by design — it exists only for assistive tech) can
// contain the SAME substring as a real, later, on-screen piece of text (e.g.
// a snackbar reading "SI/HO/2026/00042 completed." vs. that same invoice
// number appearing as a real, clickable list row moments later) — and
// without exclusion, `.first()` can match the stale, permanently-invisible
// announcement instead of the real element, making a subsequent `.click()`
// retry forever against something "visible, enabled and stable" but
// "outside of the viewport". Excluded by default here so every caller gets
// this for free; a caller that genuinely needs the announcement itself
// (rare) can query `flt-announcement-polite` directly instead of using this
// helper.
function textVisible(page, text) {
  const escaped = text.replace(/"/g, '\\"');
  return page.locator(`[aria-label*="${escaped}"]:not(flt-announcement-polite), :text("${escaped}"):not(flt-announcement-polite)`).first();
}

// Real bug found live (2026-10-11): `page.getByLabel(label).fill(value)`
// silently left one out of three sequential fields empty on this app's
// Administrator Sign-In form (Client No. and Password filled correctly,
// Username did not) — `.fill()` sets a native input's value directly
// rather than dispatching real keystrokes, which doesn't always reach
// Flutter's web text-input bridge reliably across several fields filled
// in quick succession. A real click-then-type sequence (mirroring actual
// user typing, which is exactly what Flutter's text input client is
// built to handle) is the reliable alternative for any text field in
// this app.
async function typeInto(page, label, value) {
  const field = page.getByLabel(label);
  await field.click();
  // The very first keystroke typed immediately after the click can be
  // lost — Flutter's web text-input bridge needs a brief moment after
  // focus before it's actually ready to receive input (confirmed live:
  // "Admin" arrived as "dmin" without this wait).
  await page.waitForTimeout(150);
  await page.keyboard.type(value, { delay: 30 });
}

module.exports = { enableSemantics, textVisible, typeInto };
