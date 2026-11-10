// Where the Page Builder tests run (Ops Portal move, Trello #161, plan step 7). The staff pages live in two places until
// Fred says switch: the old host (the default) and the portal under /planner. The PUBLIC pages (the collector form, the
// Site file /driver) and the share link stay on the old host in both cases.
//   PLANNER_BASE=http://localhost:8080/planner   the local portal (the session goes to localStorage: no shared cookie off .unclogme.app)
//   PLANNER_BASE=https://ops.unclogme.app/planner the live portal
export const PUB = 'https://planner.unclogme.app'
const base = new URL(process.env.PLANNER_BASE || PUB)
export const H = base.origin                                   // the origin the staff pages are on
export const R = base.pathname.replace(/\/+$/, '')             // '' on the old host, '/planner' in the portal
export const PORTAL = R !== ''
// a laptop-size button: the portal kit's h-8 (32px, Fred's compact controls), the old app's 36px
export const LAPTOP_H = PORTAL ? 32 : 36
const SHARED = /(^|\.)unclogme\.app$/.test(base.hostname)

// Signs the fake session in the way the shared module reads it: the .unclogme.app cookie, or localStorage with Remember me
// on any other host (localhost). The user object is per origin in both cases.
export async function seedSession(ctx, session, user, extra) {
  if (SHARED) await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript(([s, u, shared, r]) => {
    window.__R = r   // the route prefix, for checks that run in the page
    try {
      if (!shared) { localStorage.setItem('unclogme-remember-me', 'true'); localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token', JSON.stringify(s)) }
      localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u }))
    } catch {}
  }, [session, user, SHARED, R])
}

// The CHUNK_SUB control routes the app's code through a test's own edit handler. The built app serves /assets/*.js; the
// local dev server serves each module under /src/, so both are routed.
export async function routeCode(p, handler) {
  await p.route(H + '/assets/*.js', handler)
  if (PORTAL) await p.route(H + '/src/**', handler)
}
