# v0.9.5

- Revision 9 fixes the complete-login verification path exposed by 3x-ui 3.6.0. The main installer now loads the login helper before first use, and password verification mirrors the browser's CSRF/session-cookie handshake instead of issuing a bare POST that 3x-ui rejects with HTTP 403. A failed probe never rotates credentials by itself.
- Revision 8 refuses partial credential handoffs. A protected current-login store retains runbook-managed VPS and panel credentials across runs; operation 1 requires explicit rotation when either password is unavailable, verifies the panel password with a real localhost login, and Windows/Android render a prominent four-field VPS/panel login form only when all fields are real.
- Revision 7 fixes the false DNS retry loop on Windows and the VPS. The Windows client accepts its system resolver immediately, or requires matching Cloudflare and Google DNS-over-HTTPS answers when the local resolver times out; the remote runbook applies the same quorum rule. Prompts expose only MATCH/MISS state.
- Revision 6 accepts both `status` and `--status` for the public-IP rebind status protocol, and the node status collector uses the canonical spelling. This prevents a read-only health check from failing with `USAGE`.

- Preserve `direct-reality` as the default production topology while adding explicit `cdn-xhttp-tls` and `dual-hot-switch` state identifiers.
- Pin 3x-ui v3.6.0, its installer commit, script checksums, and per-architecture release assets; reject moving third-party install URLs.
- Add a loopback-only VLESS/XHTTP `packet-up` prototype managed through the local 3x-ui API and verified by strict readback/listener checks.
- Add an Nginx TLS shadow on `127.0.0.2:8443`, then optionally promote origin `8443` behind atomic UFW rules restricted to freshly validated official Cloudflare CIDRs. The transaction never changes SSH or the Reality listener on origin 443.
- Keep Cloudflare mutations manual and token-free. Validate proxied DNS, `Cf-Ray`, the managed 443-to-8443 Origin Rule response, external direct-origin denial, and a real client browse before committing `DUAL_INSTALLED_ACTIVE_CDN`.
- Add independent rollback of public 8443/UFW to the loopback shadow, plus full managed CDN/XHTTP removal back to `ACTIVE_DIRECT`.
- Add strict Windows and Android CDN/XHTTP link builders/parsers. Generated links are derived from verified inbound state rather than panel share output.
- Add operation 21 with pinned copyparty v1.20.21, non-root systemd execution, loopback-only `127.0.0.1:3923`, bounded 2/3GiB storage, SSH-tunnel access, password-hash-only remote state, stdin secret transport, and credential CRUD verification.
- Extend disaster backup, diagnosis, safe repair, toolkit completeness, and dismantle handling for the new staged and private-drive components.
- Preserve the validated v0.9.0 handoff byte-for-byte as the prefix of the v0.9.5 complete handoff.
- Add Windows and Android graphical operation 22 for redacted state, loopback staging, protected staged-link handoff, read-only Cloudflare planning, and safe local-prototype removal.
- Add operation 19 with bounded security-event aggregation and a managed, read-back-verified Fail2ban SSH jail.
- Add operation 20 with locally generated Ed25519 device identities, signed one-time enrollment, per-device VLESS clients, pause/resume/revoke transactions, replay rejection, and last-controller protection. mTLS and WireGuard device-lock claims remain blocked.
- Add operation 23 for public-IP rebinding. It reuses the same SSH key, pins the old server Host Key, compares machine-id and stable NODE_ID/SERVER_ID, separates missing-key/public-key-rejected/host-key-mismatch failures, snapshots before DNS, and never rolls back DNS to a provider-reclaimed address.
- Render the same append-only complete handoff on Windows and Android for operations 1, 5, 6, 7, and 23; the validated legacy handoff remains the byte-for-byte prefix.
- Make device mutations exit-safe: any uncommitted transaction restores the original 3x-ui inbound objects and registry; an unsuccessful revocation rollback is reported as `REVOCATION_PARTIAL`.

Experimental boundary: public orange-cloud XHTTP, origin concealment, Cloudflare Origin Rules, Cloudflare-only firewall activation, production 443 ownership switching, and public private-drive access remain blocked pending the real-device/edge matrix.
