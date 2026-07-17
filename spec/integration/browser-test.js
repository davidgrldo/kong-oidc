// Drives the OIDC authorization-code (browser) flow end to end against a real
// Keycloak, using a headless Chromium. Run inside the compose network so
// `kong` and `keycloak` resolve the same way for the browser and for Kong.
const { chromium } = require("playwright");

const BASE = "http://kong:8000";
const PROTECTED = BASE + "/headers"; // httpbin echoes received headers as JSON
const LOGIN_RE = /\/realms\/kong\/protocol\/openid-connect\/auth/;

function fail(msg) {
  console.error("BROWSER E2E FAILED:", msg);
  process.exit(1);
}

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();

  // 1. Unauthenticated request is redirected to the Keycloak login page.
  await page.goto(PROTECTED, { waitUntil: "domcontentloaded" });
  if (!LOGIN_RE.test(page.url())) {
    fail("expected redirect to Keycloak login, landed at " + page.url());
  }
  console.log("  ok: unauthenticated request redirected to Keycloak login");

  // 2. Submit the login form; expect to land back on the app, authenticated.
  await page.fill("#username", "alice");
  await page.fill("#password", "alice-password");
  await Promise.all([
    page.waitForURL((u) => u.toString().startsWith(BASE), { timeout: 30000 }),
    page.click("#kc-login"),
  ]);

  // 3. Upstream received the injected, verified identity header.
  let body = await page.evaluate(() => document.body.innerText);
  const m = body.match(/"X-Userinfo":\s*"([^"]+)"/i);
  if (!m) fail("X-Userinfo not injected after login: " + body.slice(0, 300));
  const decoded = Buffer.from(m[1], "base64").toString("utf8");
  if (!/alice/i.test(decoded)) {
    fail("X-Userinfo did not carry the verified identity: " + decoded.slice(0, 200));
  }
  console.log("  ok: logged in, upstream received verified X-Userinfo");

  // 4. The session cookie authenticates subsequent requests without re-login.
  await page.goto(PROTECTED, { waitUntil: "domcontentloaded" });
  if (!page.url().startsWith(BASE)) fail("unexpected re-auth on session reuse: " + page.url());
  body = await page.evaluate(() => document.body.innerText);
  if (!/"X-Userinfo"/i.test(body)) fail("session was not reused");
  console.log("  ok: existing session reused without re-login");

  // 5. Hitting logout_path clears the plugin session cookie. Use a
  //    no-redirect request so the follow-on redirect to a protected page
  //    (which Keycloak SSO would silently re-authenticate) can't mask it.
  const before = (await ctx.cookies(BASE)).filter((c) => c.httpOnly && c.value);
  if (before.length === 0) fail("expected a session cookie after login");
  await ctx.request.get(BASE + "/logout", { maxRedirects: 0 });
  const after = await ctx.cookies(BASE);
  const survived = before.find((b) => {
    const still = after.find((a) => a.name === b.name);
    return still && still.value && still.value.length > 4;
  });
  if (survived) fail("logout did not clear the session cookie: " + survived.name);
  console.log("  ok: logout cleared the session cookie");

  await browser.close();
  console.log("BROWSER E2E PASSED");
})().catch((e) => fail(e && e.message ? e.message : String(e)));
