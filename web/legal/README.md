# Legal documents

Privacy Policy, Terms of Service, and Cookie Policy, linked from the login
screen (see `_LegalNotice` in
`lib/features/auth/screens/login_screen.dart`).

Bundled here as static PDFs rather than served from Supabase Storage —
these change rarely, so shipping them with the app build (versioned in git,
deployed by the same Netlify build as everything else, no separate bucket
or public-read policy to manage) is simpler. Flutter's web build copies
everything under `web/` into `build/web/` unchanged, so a file at
`web/legal/privacy-policy.pdf` is served at `/legal/privacy-policy.pdf` in
production — `web/_redirects`' SPA catch-all (`/*  /index.html  200`) does
NOT intercept this: Netlify only applies a redirect/rewrite rule when no
real file exists at the requested path, so an actual file here always wins.

To update a policy: replace the PDF with the same filename and push — no
other change needed. Filenames MUST stay exactly as below, since
`login_screen.dart` links to these exact paths:

- `privacy-policy.pdf`
- `terms-of-service.pdf`
- `cookie-policy.pdf`
