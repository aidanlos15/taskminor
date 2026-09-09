# Availeth Discovery — landing page

Single-file funnel page for the free macOS app (`landing/index.html`). No build step, no dependencies beyond Google Fonts; every logo and icon is inlined SVG.

## Before going live
- **Download URL** — every "Download for macOS" pill points at the placeholder `https://availeth.io/download`. Search-and-replace it with the real release link.
- **VSL video** — set `data-src` on `#vsl` to the video URL (mp4/webm). The play button loads and plays it; until then it's an inert placeholder.
- **Platform** — copy states macOS 14+ on Apple silicon only. Re-add Intel only once a universal build has been tested on an Intel Mac.

## Notes
- Numbers on the page are the visitor's own calculator inputs, clearly labelled examples, or the real availeth.io case study. No invented stats or testimonials.
- Storyline (screen capture) is described as optional: off by default, needs Screen Recording + a local Ollama model, frames kept 24h then deleted.
- Brand logos are trademarks of their owners; used to indicate compatibility. Apple's own app icons are deliberately replaced with neutral glyphs.
