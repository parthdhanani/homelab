# Aesthetic Direction Guide
*Preserved from frontend-design — load this when building anything requiring strong visual identity.*

## Design Thinking (before writing any code)

Commit to a direction on four axes:
- **Purpose**: What problem does this solve? Who uses it?
- **Tone**: Pick an extreme and commit — brutally minimal, maximalist chaos, retro-futuristic, organic/natural, luxury/refined, playful/toy-like, editorial/magazine, brutalist/raw, art deco/geometric, soft/pastel, industrial/utilitarian
- **Constraints**: Framework, performance, accessibility requirements
- **Differentiation**: What makes this unforgettable? What's the one thing someone remembers?

Bold maximalism and refined minimalism both work. The key is intentionality, not intensity.

---

## Aesthetic Execution

**Typography**
- Avoid generic: Arial, Inter, Roboto, system-ui, Space Grotesk
- Pair a distinctive display font with a refined body font
- Characters should feel designed for this specific context, not default-selected

**Color**
- Dominant colors with sharp accents outperform evenly-distributed palettes
- Commit to a cohesive theme via CSS variables
- Never use purple gradients on white — the most common AI-slop tell

**Motion**
- One well-orchestrated page load with staggered reveals > scattered micro-interactions
- Use `animation-delay` for stagger, scroll-triggered states, hover surprises
- CSS-only for HTML. Motion library for React.

**Spatial Composition**
- Asymmetry, overlap, diagonal flow, grid-breaking elements
- Generous negative space OR controlled density — never in-between

**Backgrounds**
- Gradient meshes, noise textures, geometric patterns, layered transparencies, dramatic shadows
- Create atmosphere — don't default to solid colors

---

## Scroll-Driven Site Rules (load this section for scroll-animated sites)

**Typography scale**
- Hero: 6rem min, tight line-height (0.9–1.0), weight 700–800
- Sections: 3rem min, weight 600–700
- Marquee: 10–15vw, uppercase, letterspaced
- Labels: 0.7rem, uppercase, letterspaced (0.15em+), muted — e.g. "001 / Features"

**No cards on scroll sites**
- Text sits directly on background — editorial, not boxed
- No glassmorphism, no frosted containers around scroll-driven text
- Readability via font-weight (600+) and text-shadow if needed

**Color zones**
- Background shifts between sections (light → dark → accent → light)
- CSS variables: `--bg-light`, `--bg-dark`, `--bg-accent`, `--text-on-light`, `--text-on-dark`
- Transitions via GSAP, not CSS transitions

**Layout variety** (minimum 3 patterns per page)
Centered (hero/CTA) → Left-aligned (feature + product right) → Right-aligned (alternate) → Full-width (marquee/stats) → Split (text + visual)
Never use the same layout for consecutive sections.

**Animation choreography**
- Every section: different entrance (fade-up, slide-left, slide-right, scale-up, clip-path reveal)
- Stagger within section: 0.08–0.12s between items
- Sequence: label → heading → body → CTA
- At least one section pins while contents animate internally
- At least one oversized text element moves horizontally on scroll

**Stats**
- 4rem+ font size
- Count-up via GSAP (never appear statically)
- Suffix at smaller size (x, M, %)
