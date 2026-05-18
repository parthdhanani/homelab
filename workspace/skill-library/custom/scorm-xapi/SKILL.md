---
name: scorm-xapi
description: SCORM 1.2/2004 and xAPI development — API patterns, Moodle integration, suspend_data, adaptive video ABR, Storyline 360 workflows
category: scorm
keywords: scorm, xapi, moodle, lms, tincan, storyline, suspend_data, lmsinitialize, lmssetvalue, lmsfinish, adaptive, video, abr
paths:
  - "**/*.js"
  - "**/scorm/**"
  - "**/story_content/**"
  - "**/*.html"
---

# SCORM / xAPI Skill

## Core Rules

1. **LMSInitialize before everything.** Check return value — "false" = API not ready. Use retry logic (50x, 100ms) in Moodle.
2. **LMSFinish on unload.** Bind to both `beforeunload` and `unload`. Moodle does NOT auto-commit. SCORM Cloud does.
3. **suspend_data ≤ 4096 chars.** Always check length before LMSSetValue. Exceed = silent failure in Moodle.
4. **Test in Moodle, not just SCORM Cloud.** Cloud is async-lenient. Moodle is iframe-strict. Works in Cloud ≠ works in Moodle.

## API Initialization (Moodle-safe)

```javascript
function findAPI(win, depth) {
  if (depth > 7) return null;
  if (win.API) return win.API;
  if (win.parent && win.parent !== win) return findAPI(win.parent, depth + 1);
  return null;
}

function initWithRetry(attempts, callback) {
  var api = findAPI(window, 0);
  if (api && api.LMSInitialize('') === 'true') {
    callback(api);
    return;
  }
  if (attempts < 50) setTimeout(() => initWithRetry(attempts + 1, callback), 100);
}
```

## Completion Pattern

```javascript
// Bind on load — never rely on manual calls
window.addEventListener('beforeunload', function() {
  if (window.scormAPI) {
    window.scormAPI.LMSSetValue('cmi.core.lesson_status', 'completed');
    window.scormAPI.LMSCommit('');
    window.scormAPI.LMSFinish('');
  }
});
```

## suspend_data Safety

```javascript
function saveSuspendData(api, data) {
  var str = JSON.stringify(data);
  if (str.length > 4096) {
    console.error('suspend_data too large:', str.length, '— prune before saving');
    return false;
  }
  return api.LMSSetValue('cmi.core.suspend_data', str) === 'true';
}
```

## Adaptive Video ABR (v4.0 — Parth's system)

**Probe:** 200KB `probe.bin` binary file in `story_content/`. Fetch with `{cache: 'no-store'}`.
**Timing:** Per-video (reset `__abrDone` flag on each `.src` assignment). No mid-video switching.
**Thresholds:** ≥2.5 Mbps → 1080p | ≥0.8 Mbps → 720p | below → 480p
**Probe math:** `kbps = buf.byteLength * 8 / elapsed_ms` (performance.now() is in ms)

**Never use:**
- `navigator.connection.downlink` — reads OS signal, ignores Chrome DevTools throttle
- Image() or MP3 probes — served from cache, measure 0ms
- HEAD requests — measure latency not throughput

**Idempotent rewrite (`applyRes`):**
```javascript
function applyRes(src, targetRes) {
  // 1. Find current tier in src
  var current = TIERS.find(t => src.includes(t.res));
  if (!current) return src;
  // 2. Normalize to canonical
  var canonical = src.replace(current.res, '1920x1080').replace(/_[a-z]{2}\.mp4$/, '.mp4');
  // 3. Apply target
  return canonical.replace('1920x1080', targetRes);
}
```

## Video Naming Convention (Storyline 360)

`story_content/video_<ID>_<n>_<n>_<WxH>.mp4`
- Source: `video_5vjCLxqbTlh_22_56_1920x1080.mp4`
- 720p: `video_5vjCLxqbTlh_22_56_1280x720.mp4`
- 480p: `video_5vjCLxqbTlh_22_56_854x480.mp4`

## FFmpeg Encode Settings

```bash
# 720p
ffmpeg -i input.mp4 -vf scale=1280:720 -c:v libx264 -profile:v high \
  -pix_fmt yuv420p -r 25 -b:v 900k -maxrate 900k -bufsize 1800k \
  -movflags +faststart -c:a aac -b:a 96k output_1280x720.mp4

# 480p
ffmpeg -i input.mp4 -vf scale=854:480 -c:v libx264 -profile:v high \
  -pix_fmt yuv420p -r 25 -b:v 350k -maxrate 350k -bufsize 700k \
  -movflags +faststart -c:a aac -b:a 96k output_854x480.mp4
```

## SCORM Package Modifier Tool

**Location:** `/Users/parthdhanani/Downloads/Work/Tool/staging/SCORM Package Modifier/scorm-modifier.py`
**What it does:** Transcodes 1080p → 720p + 480p via ffmpeg, writes 200KB probe.bin, patches index_lms.html with ABR v4.0 JS.
**Idempotent:** Second run skips already-encoded videos and already-patched HTML.

## Moodle-Specific Gotchas

- SCORM iframes: API lives on `window.parent` or higher — always traverse up
- Moodle 4.x: `cmi.core.lesson_status` still works for SCORM 1.2; use `cmi.completion_status` for 2004
- Suspend_data encoding: use `encodeURIComponent` if storing special characters
- Moodle AJAX: `require(['core/ajax'])` for REST calls, not raw XHR
- Plugin path pattern: `M.cfg.wwwroot + '/local/pluginname/...'`

## Storyline 360 Translation Workflow

**Export:** Word doc (translation table format) — source text + Translation column
**Matching:** Normalize both sides — strip HTML, handle curly quotes (`\u2018/\u2019` → `'`)
**Import:** Python script with python-docx + openpyxl in a venv
**Gotcha:** NFKC normalization does NOT convert curly quotes — must replace explicitly after normalize

## xAPI Statement Pattern

```javascript
var statement = {
  actor: { mbox: 'mailto:learner@example.com', objectType: 'Agent' },
  verb: { id: 'http://adlnet.gov/expapi/verbs/completed', display: { 'en-US': 'completed' } },
  object: { id: window.location.href, objectType: 'Activity' }
};
// Send via TinCanJS or fetch to LRS endpoint
```

## Debug Checklist

1. Is LMSInitialize returning "true"? (not just truthy — must be string "true")
2. Is LMSFinish being called on page unload?
3. Is suspend_data under 4096 chars?
4. Is the API found on the right window ancestor?
5. Test in SCORM Cloud first — if broken there, it's your code. If works in Cloud but not Moodle, it's timing/Moodle quirk.
