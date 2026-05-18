---
name: ui-ux-pro-max
description: "UI/UX design intelligence for web and mobile — styles, color palettes, typography, layout, accessibility, and component design across React, Vue, Svelte, SwiftUI, Flutter, and Tailwind."
---

# UI/UX Pro Max — Design Intelligence

200+ design rules across 10 priority categories. Apply rules top-down (CRITICAL → HIGH → MEDIUM → LOW).

> When the task requires strong visual identity, distinctive aesthetics, or scroll-driven design — read `references/aesthetic-direction.md` before starting.

## When to Apply

**Use when** the task changes how something **looks, feels, moves, or is interacted with**: new pages, UI components, color/typography/layout choices, UI review, navigation, animations, responsive behavior, design decisions.

**Skip when** the task is pure backend, API/DB design, non-visual scripts, infrastructure, or DevOps.

## Priority Table

| # | Category | Impact | Must Have | Avoid |
|---|----------|--------|-----------|-------|
| 1 | Accessibility | CRITICAL | 4.5:1 contrast, alt text, keyboard nav, aria-labels | Removing focus rings, icon-only buttons without labels |
| 2 | Touch & Interaction | CRITICAL | 44×44px min, 8px+ spacing, loading feedback | Hover-only, 0ms state changes |
| 3 | Performance | HIGH | WebP/AVIF, lazy load, CLS < 0.1 | Layout thrashing, CLS |
| 4 | Style Selection | HIGH | Match product type, consistency, SVG icons | Mixed styles, emoji as icons |
| 5 | Layout & Responsive | HIGH | Mobile-first, viewport meta, no h-scroll | Fixed px widths, disabled zoom |
| 6 | Typography & Color | MEDIUM | 16px base, 1.5 line-height, semantic tokens | <12px body, gray-on-gray, raw hex |
| 7 | Animation | MEDIUM | 150–300ms, meaningful motion, spatial continuity | Decorative-only, animating width/height |
| 8 | Forms & Feedback | MEDIUM | Visible labels, error near field, progressive disclosure | Placeholder-only, errors at top only |
| 9 | Navigation | HIGH | Predictable back, bottom nav ≤5, deep links | Overloaded nav, broken back |
| 10 | Charts & Data | LOW | Legends, tooltips, accessible colors | Color-only meaning |

## Rules Reference

### 1. Accessibility (CRITICAL)
- `color-contrast` 4.5:1 normal, 3:1 large text
- `focus-states` 2–4px visible focus rings on interactive elements
- `alt-text` descriptive alt for meaningful images
- `aria-labels` aria-label for icon-only buttons
- `keyboard-nav` tab order = visual order, full keyboard support
- `form-labels` label with for attribute
- `skip-links` skip to main content link
- `heading-hierarchy` sequential h1→h6, no level skip
- `color-not-only` add icon/text alongside color indicators
- `dynamic-type` support system text scaling, avoid truncation
- `reduced-motion` respect prefers-reduced-motion
- `voiceover-sr` meaningful accessibilityLabel, logical reading order
- `escape-routes` cancel/back in modals and multi-step flows
- `keyboard-shortcuts` preserve system and a11y shortcuts

### 2. Touch & Interaction (CRITICAL)
- `touch-target-size` 44×44pt (Apple) / 48×48dp (Material) minimum
- `touch-spacing` 8px+ gap between touch targets
- `hover-vs-tap` click/tap for primary actions; never hover-only
- `loading-buttons` disable + spinner during async operations
- `error-feedback` clear error messages near the problem
- `cursor-pointer` on clickable elements (web)
- `gesture-conflicts` avoid horizontal swipe on main content
- `tap-delay` touch-action: manipulation to kill 300ms delay
- `standard-gestures` use platform-standard gestures, don't redefine
- `system-gestures` don't block system gestures (back swipe, Control Center)
- `press-feedback` visual feedback on press (ripple/highlight)
- `haptic-feedback` haptics for confirmations, avoid overuse
- `gesture-alternative` always provide visible controls alongside gestures
- `safe-area-awareness` avoid notch, Dynamic Island, gesture bar areas
- `no-precision-required` no pixel-perfect taps on small targets
- `swipe-clarity` swipe actions need clear affordance (chevron, label)
- `drag-threshold` movement threshold before starting drag

### 3. Performance (HIGH)
- `image-optimization` WebP/AVIF, srcset/sizes, lazy load non-critical
- `image-dimension` declare width/height or aspect-ratio to prevent CLS
- `font-loading` font-display: swap/optional to avoid FOIT
- `font-preload` preload only critical fonts
- `critical-css` inline above-the-fold CSS
- `lazy-loading` dynamic import / route-level code splitting
- `bundle-splitting` split by route/feature to reduce TTI
- `third-party-scripts` async/defer, audit and remove unnecessary
- `reduce-reflows` batch DOM reads then writes
- `content-jumping` reserve space for async content
- `lazy-load-below-fold` loading="lazy" for below-fold images
- `virtualize-lists` virtualize 50+ item lists
- `main-thread-budget` <16ms per frame for 60fps
- `progressive-loading` skeleton/shimmer for >1s operations
- `input-latency` <100ms for taps/scrolls
- `tap-feedback-speed` visual feedback within 100ms of tap
- `debounce-throttle` debounce/throttle scroll, resize, input events
- `offline-support` offline state messaging and fallback
- `network-fallback` degraded mode for slow networks

### 4. Style Selection (HIGH)
- `style-match` match style to product type and industry
- `consistency` same style across all pages
- `no-emoji-icons` SVG icons (Heroicons, Lucide), never emojis
- `color-palette-from-product` palette from product/industry context
- `effects-match-style` shadows/blur/radius aligned with style
- `platform-adaptive` respect iOS HIG vs Material idioms
- `state-clarity` hover/pressed/disabled visually distinct
- `elevation-consistent` consistent shadow/elevation scale
- `dark-mode-pairing` design light/dark variants together
- `icon-style-consistent` one icon set across the product
- `system-controls` prefer native controls, customize only for branding
- `blur-purpose` blur for dismissal context, not decoration
- `primary-action` one primary CTA per screen

### 5. Layout & Responsive (HIGH)
- `viewport-meta` width=device-width initial-scale=1, never disable zoom
- `mobile-first` design mobile-first, scale up
- `breakpoint-consistency` systematic breakpoints: 375 / 768 / 1024 / 1440
- `readable-font-size` 16px min body text on mobile (prevents iOS auto-zoom)
- `line-length-control` 35–60 chars mobile, 60–75 chars desktop
- `horizontal-scroll` no horizontal scroll on mobile
- `spacing-scale` 4pt/8dp incremental system
- `touch-density` comfortable spacing, no cramped tap targets
- `container-width` consistent max-width desktop (max-w-6xl/7xl)
- `z-index-management` layered scale: 0/10/20/40/100/1000
- `fixed-element-offset` fixed bars reserve padding for content
- `scroll-behavior` no conflicting nested scroll regions
- `viewport-units` min-h-dvh over 100vh on mobile
- `orientation-support` readable and operable in landscape
- `content-priority` core content first on mobile, fold secondary
- `visual-hierarchy` hierarchy via size/spacing/contrast, not color alone

### 6. Typography & Color (MEDIUM)
- `line-height` 1.5–1.75 for body text
- `line-length` 65–75 chars max per line
- `font-pairing` match heading/body font personalities
- `font-scale` consistent scale: 12/14/16/18/24/32
- `contrast-readability` dark text on light bg (slate-900 on white)
- `text-styles-system` use platform type system (Dynamic Type / Material type roles)
- `weight-hierarchy` bold headings 600–700, regular body 400, medium labels 500
- `color-semantic` semantic tokens (primary, secondary, error, surface) not raw hex
- `color-dark-mode` desaturated/lighter tonal variants, not inverted
- `color-accessible-pairs` 4.5:1 AA or 7:1 AAA foreground/background
- `color-not-decorative-only` functional color must include icon/text
- `truncation-strategy` prefer wrapping; ellipsis + tooltip when truncating
- `letter-spacing` respect platform defaults, no tight tracking on body
- `number-tabular` tabular/monospace figures for data, prices, timers
- `whitespace-balance` intentional whitespace to group and separate

### 7. Animation (MEDIUM)
- `duration-timing` 150–300ms micro-interactions, ≤400ms complex, never >500ms
- `transform-performance` transform/opacity only, never width/height/top/left
- `loading-states` skeleton/progress when loading >300ms
- `excessive-motion` max 1–2 animated elements per view
- `easing` ease-out entering, ease-in exiting, never linear for UI
- `motion-meaning` every animation = cause-effect, not decorative
- `state-transition` state changes animate smoothly, never snap
- `continuity` spatial continuity across page/screen transitions
- `parallax-subtle` sparingly, respect reduced-motion
- `spring-physics` spring/physics curves over cubic-bezier for natural feel
- `exit-faster-than-enter` exit ~60–70% of enter duration
- `stagger-sequence` 30–50ms stagger per list/grid item entrance
- `shared-element-transition` hero transitions for cross-screen continuity
- `interruptible` user tap/gesture cancels in-progress animation immediately
- `no-blocking-animation` UI stays interactive during animations
- `fade-crossfade` crossfade for content replacement in same container
- `scale-feedback` subtle 0.95–1.05 scale on press for cards/buttons
- `gesture-feedback` drag/swipe/pinch tracks finger in real-time
- `hierarchy-motion` translate direction expresses depth (up=back, down=deeper)
- `motion-consistency` unified duration/easing tokens globally
- `opacity-threshold` don't linger below 0.2; fully fade or stay visible
- `modal-motion` modals animate from trigger source for spatial context
- `navigation-direction` forward=left/up, backward=right/down
- `layout-shift-avoid` animations must not cause reflow/CLS

### 8. Forms & Feedback (MEDIUM)
- `input-labels` visible label per input, never placeholder-only
- `error-placement` error below the related field
- `submit-feedback` loading → success/error state on submit
- `required-indicators` mark required fields (asterisk)
- `empty-states` helpful message + action when no content
- `toast-dismiss` auto-dismiss 3–5s
- `confirmation-dialogs` confirm before destructive actions
- `input-helper-text` persistent helper text below complex inputs
- `disabled-states` opacity 0.38–0.5, cursor change, semantic attribute
- `progressive-disclosure` reveal complex options progressively
- `inline-validation` validate on blur, not keystroke
- `input-type-keyboard` semantic types (email, tel, number) for mobile keyboard
- `password-toggle` show/hide toggle for passwords
- `autofill-support` autocomplete/textContentType for system autofill
- `undo-support` undo toast for destructive/bulk actions
- `success-feedback` brief visual confirmation (checkmark, toast, flash)
- `error-recovery` error messages include recovery path (retry, edit, help)
- `multi-step-progress` step indicator + back navigation
- `form-autosave` auto-save drafts on long forms
- `sheet-dismiss-confirm` confirm before dismissing with unsaved changes
- `error-clarity` state cause + how to fix, not "Invalid input"
- `field-grouping` group related fields (fieldset/legend or visual)
- `read-only-distinction` visually/semantically different from disabled
- `focus-management` auto-focus first invalid field after submit error
- `error-summary` summary at top with anchor links for multiple errors
- `touch-friendly-input` ≥44px input height on mobile
- `destructive-emphasis` danger color (red), separated from primary actions
- `toast-accessibility` aria-live="polite", don't steal focus
- `aria-live-errors` aria-live or role="alert" for form errors
- `contrast-feedback` error/success colors meet 4.5:1
- `timeout-feedback` timeout → clear feedback + retry option

### 9. Navigation (HIGH)
- `bottom-nav-limit` max 5 items with labels + icons
- `drawer-usage` drawer for secondary nav, not primary actions
- `back-behavior` predictable, consistent, preserves scroll/state
- `deep-linking` all key screens reachable via URL/deep link
- `tab-bar-ios` iOS: bottom Tab Bar for top-level
- `top-app-bar-android` Android: Top App Bar with nav icon
- `nav-label-icon` both icon and text label, never icon-only
- `nav-state-active` current location visually highlighted
- `nav-hierarchy` separate primary nav from secondary nav
- `modal-escape` clear close/dismiss + swipe-down on mobile
- `search-accessible` easily reachable, recent/suggested queries
- `breadcrumb-web` breadcrumbs for 3+ level hierarchies
- `state-preservation` back restores scroll, filters, input
- `gesture-nav-support` support system gestures without conflict
- `tab-badge` sparingly for unread/pending, clear after visit
- `overflow-menu` overflow menu when actions exceed space
- `bottom-nav-top-level` bottom nav for top-level only
- `adaptive-navigation` ≥1024px sidebar, small screens bottom/top nav
- `back-stack-integrity` never silently reset nav stack
- `navigation-consistency` same nav placement across all pages
- `avoid-mixed-patterns` don't mix Tab + Sidebar + Bottom Nav at same level
- `modal-vs-navigation` modals not for primary navigation flows
- `focus-on-route-change` move focus to main content on page transition
- `persistent-nav` core nav reachable from deep pages
- `destructive-nav-separation` dangerous actions separated from normal nav
- `empty-nav-state` unavailable destinations explain why

### 10. Charts & Data (LOW)
- `chart-type` trend→line, comparison→bar, proportion→pie/donut
- `color-guidance` accessible palettes, avoid red/green only
- `data-table` table alternative for screen readers
- `pattern-texture` patterns/shapes alongside color
- `legend-visible` always show, near chart not below fold
- `tooltip-on-interact` hover/tap shows exact values
- `axis-labels` units, readable scale, no truncated/rotated labels
- `responsive-chart` reflow/simplify on small screens
- `empty-data-state` "No data yet" + guidance, not blank chart
- `loading-chart` skeleton/shimmer while loading
- `animation-optional` respect reduced-motion, data readable immediately
- `large-dataset` 1000+ points: aggregate, drill-down for detail
- `number-formatting` locale-aware numbers, dates, currencies
- `touch-target-chart` ≥44pt tap area for interactive elements
- `no-pie-overuse` >5 categories → bar chart
- `contrast-data` lines/bars vs bg ≥3:1, text labels ≥4.5:1
- `legend-interactive` click to toggle series
- `direct-labeling` small datasets: label directly on chart
- `tooltip-keyboard` keyboard-reachable tooltips
- `sortable-table` sorting with aria-sort state
- `axis-readability` readable spacing, auto-skip on small screens
- `data-density` limit per-chart density, split if needed
- `trend-emphasis` trends over decoration
- `gridline-subtle` low-contrast gridlines (gray-200)
- `focusable-elements` keyboard-navigable chart elements
- `screen-reader-summary` aria-label describing chart's key insight
- `error-state-chart` data fail → error + retry, not broken chart
- `export-option` CSV/image export for data-heavy products
- `drill-down-consistency` clear back-path and breadcrumb
- `time-scale-clarity` label time granularity, allow switching

## Workflow

1. **Analyze** — product type, audience, style keywords, stack
2. **Design system** — color palette (match industry), typography pairing, style, 4/8pt spacing scale, elevation scale
3. **Apply rules** — work categories 1→10, CRITICAL first
4. **Pre-delivery check** — run checklist below

## Pre-Delivery Checklist

### Visual
- [ ] SVG icons only, consistent family/style, no emojis
- [ ] Semantic theme tokens, no hardcoded hex
- [ ] Press states don't shift layout

### Interaction
- [ ] Pressed feedback on all tappable elements
- [ ] Touch targets ≥44×44pt
- [ ] 150–300ms micro-interaction timing
- [ ] Disabled states clear and non-interactive

### Light/Dark Mode
- [ ] Primary text ≥4.5:1 both themes
- [ ] Secondary text ≥3:1 both themes
- [ ] Borders/dividers visible in both
- [ ] Both themes tested, not assumed

### Layout
- [ ] Safe areas respected
- [ ] No content hidden behind sticky bars
- [ ] Verified 375px and large viewports
- [ ] 4/8pt spacing rhythm maintained

### Accessibility
- [ ] All images/icons have labels
- [ ] Form fields: labels, hints, error messages
- [ ] Color not sole indicator
- [ ] Reduced motion supported
