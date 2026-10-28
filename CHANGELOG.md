# Changelog

## 1.0.0 - 2026-10-28

- First release for Enonic XP 8.1 and later.
- Adds the Privatus Analytics script to the head of every page in live mode.
- Site config: site ID, the five tracking modules (engage, auto, vitals, clicks, ask) and "Automatically add script to page" for headless sites.
- Adds no script when the site ID is missing or does not look like a site ID.
- Allows the tracker in the site's Content Security Policy when one is set, with a nonce when the policy needs one.
