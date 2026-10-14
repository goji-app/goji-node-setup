# Decoy site templates

`install.sh` deploys one of these to `/var/www/decoy` (menu on a terminal,
`--template <name>` to choose, random without a terminal; re-runs keep the one already deployed;
`goji-node decoy` switches it later).
After editing anything here run `python build.py` to re-embed them into `install.sh`.

| Name | Site (fictional) | Source |
|---|---|---|
| analytics | Quillmetric — cookie-free web analytics, SVG dashboard, pricing | written for this repo; portraits: see THIRD-PARTY-NOTICES.md |
| blog | Lantern & Road — travel blog, 6 articles + about | written for this repo; photos: see THIRD-PARTY-NOTICES.md |
| docs | Postline API Reference — sidebar, filter, code samples (no external scripts) | written for this repo |
| saas | Stackpulse — uptime monitoring landing page, pricing | written for this repo; portraits/office photo: see THIRD-PARTY-NOTICES.md |
| freelancer | Maren Holt — travel photographer portfolio, 12 photos, lightbox | written for this repo; photos: see THIRD-PARTY-NOTICES.md |
| resume | Daniel Okafor — backend engineer CV | written for this repo; portrait: see THIRD-PARTY-NOTICES.md |
| creative | Oak & Ledger — handmade goods shop with basket | written for this repo; photos from startbootstrap-creative (MIT) |
| grayscale | Fjellro — mountain cabins in Norway, booking request form | written for this repo; photos: see THIRD-PARTY-NOTICES.md |
| new-age | Habitual — habit tracker app landing, CSS phone mock-up | written for this repo; photos: see THIRD-PARTY-NOTICES.md |
| agency | Fieldstone Studio — brand and web design studio, team, work | written for this repo; photos: see THIRD-PARTY-NOTICES.md |
| livecams | Open Window — 24 YouTube live streams (cities, ISS/NASA, zoos, aquariums, wildlife, news); ids in `S` in index.html, each checked as embeddable via YouTube oEmbed; YouTube IFrame API with auto-skip of unavailable streams; thumbnails from i.ytimg.com | written for this repo |

All templates are self-contained (no CDN scripts, fonts or frameworks; forms are client-side only and send nothing).
Photo licenses and credits: `THIRD-PARTY-NOTICES.md`.
