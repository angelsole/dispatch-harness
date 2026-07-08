"""Open a headed browser, wait for the human to log in, save the session.

No terminal interaction needed: login is auto-detected (Firebase auth entry in
IndexedDB or localStorage, NextAuth cookie, or the app's `user` object), then
the Playwright storage state — including IndexedDB, where modern Firebase
persists sessions — is written and the browser closes itself.

Usage: python auth-capture.py <url> <output.json>
"""
import sys
import time

from playwright.sync_api import sync_playwright

LOGIN_CHECK = """async () => {
  if (Object.keys(localStorage).some(k => k.startsWith('firebase:authUser'))) return true;
  if (localStorage.getItem('user')) return true;
  if (document.cookie.includes('next-auth') || document.cookie.includes('authjs')) return true;
  try {
    const dbs = await indexedDB.databases();
    if (!dbs.some(d => d.name === 'firebaseLocalStorageDb')) return false;
    return await new Promise(resolve => {
      const req = indexedDB.open('firebaseLocalStorageDb');
      req.onsuccess = () => {
        const db = req.result;
        try {
          const store = db.transaction('firebaseLocalStorage', 'readonly')
            .objectStore('firebaseLocalStorage');
          const keys = store.getAllKeys();
          keys.onsuccess = () => { db.close(); resolve(keys.result.some(k => String(k).includes('authUser'))); };
          keys.onerror = () => { db.close(); resolve(false); };
        } catch (e) { db.close(); resolve(false); }
      };
      req.onerror = () => resolve(false);
    });
  } catch (e) { return false; }
}"""

def main():
    url, out = sys.argv[1], sys.argv[2]
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=False)
        ctx = browser.new_context()
        page = ctx.new_page()
        page.goto(url)
        print("[demo-auth] log in in the browser window — saving is automatic.", flush=True)
        deadline = time.time() + 600
        while time.time() < deadline:
            time.sleep(2)
            try:
                if page.evaluate(LOGIN_CHECK):
                    break
            except Exception:
                pass  # mid-navigation; try again
        else:
            sys.exit("[demo-auth] timed out (10 min) waiting for login")
        time.sleep(3)  # let tokens finish settling
        try:
            ctx.storage_state(path=out, indexed_db=True)
        except TypeError:  # older playwright without the kwarg
            ctx.storage_state(path=out)
        print(f"[demo-auth] session saved to {out}", flush=True)
        browser.close()

if __name__ == "__main__":
    main()
