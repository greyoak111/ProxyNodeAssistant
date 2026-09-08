# v0.8.3

- Add a 15-template, local-only public cover-site library under `templates/cover-sites/`.
- Support `random`, stable per-domain `auto`, and exact template IDs `1` through `15`.
- Random selection avoids the currently active managed template when possible.
- Store the active template ID, slug, title, and selection mode in `/var/www/cover/.proxy-runbook-cover`.
- Add the original `Signal Runner` offline pixel mini-game as template 15; it uses no Google artwork, branding, or external code.
- Preserve custom sites by default and back up the current site before every approved managed-template switch.
- Keep all templates independent of CDNs, external fonts, trackers, remote images, and third-party JavaScript.
