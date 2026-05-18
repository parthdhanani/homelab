---
name: lms-help
description: Moodle LMS administration and SCORM course management. Use when configuring Moodle, setting up SCORM packages, troubleshooting course completion, gradebook issues, user enrollment, plugin configuration, or LMS server setup.
date: 2026-03-22
---
---
description: SCORM 1.2 API quick reference
context: fork
allowed-tools: Read
---

# /lms-help — SCORM 1.2 API Reference

## Find API

Synchronous (works when API is already loaded):
```javascript
function findAPI(win) {
  let depth = 0;
  while (!win.API && win.parent && win.parent !== win && depth++ < 7) {
    win = win.parent;
  }
  return win.API || null;
}
```

**Moodle 4.x**: API is injected asynchronously — use polling instead:
```javascript
function initWithRetry(attempts) {
  const api = findAPI(window);
  if (api) { window.scormAPI = api; api.LMSInitialize(''); return; }
  if (attempts < 50) setTimeout(() => initWithRetry(attempts + 1), 100);
}
window.addEventListener('load', () => initWithRetry(0));
window.addEventListener('beforeunload', () => { // Moodle requires explicit finish
  if (window.scormAPI) window.scormAPI.LMSFinish('');
});
```

## Lifecycle

```javascript
const API = findAPI(window);
API.LMSInitialize('');

// Set values (all strings in SCORM 1.2)
API.LMSSetValue('cmi.core.lesson_status', 'completed');
API.LMSSetValue('cmi.core.score.raw', '95');
API.LMSSetValue('cmi.suspend_data', JSON.stringify(data)); // max 4096 chars
API.LMSCommit('');

// Get values
const status = API.LMSGetValue('cmi.core.lesson_status');
const score = API.LMSGetValue('cmi.core.score.raw');

// Error check
const err = API.LMSGetLastError();
if (err !== '0') {
  console.error(err, API.LMSGetErrorString(err), API.LMSGetDiagnostic(err));
}

// Finish (on page unload)
API.LMSCommit('');
API.LMSFinish('');
```

## Common cmi Elements

| Element | Values | Notes |
|---|---|---|
| `cmi.core.lesson_status` | `passed`, `completed`, `failed`, `incomplete`, `browsed`, `not attempted` | |
| `cmi.core.score.raw` | `0`-`100` (string) | |
| `cmi.core.score.min` | string | |
| `cmi.core.score.max` | string | |
| `cmi.suspend_data` | string | 4096 char limit |
| `cmi.core.lesson_location` | string | 255 char limit |
| `cmi.core.student_id` | read-only | |
| `cmi.core.student_name` | read-only | |

## Troubleshooting

**"API not found"** → Check frame hierarchy: `window.API`, `window.parent.API`, `window.parent.parent.API`

**"LMSCommit failed"** → All values must be strings. Check `String(95)` not `95`.

**"Suspend data too large"** → Compress: strip whitespace, shorten keys, use abbreviations. Limit: 4096 chars.

**Save findings:** `/save` to log decisions or dead ends to memory
