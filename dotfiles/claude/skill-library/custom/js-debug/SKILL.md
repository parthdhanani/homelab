---
name: js-debug
description: SCORM 1.2 JavaScript debugging patterns. Use when SCORM API calls fail, LMSFinish not committing, LMSInitialize errors, xAPI statement issues, Moodle LMS data not saving, completion not tracking, suspend_data memory corruption, cmi.core memory issues, or any JavaScript/SCORM runtime errors.
date: 2026-03-22
---
---
description: SCORM-specific debug patterns and root cause methodology
context: fork
allowed-tools: Read, Bash(grep *), Bash(cat *)
---

# /js-debug — SCORM Debug & Root Cause Tracing

## Iron Law: Root Cause First

No fixes without root cause investigation. Trace backward from the error to where bad data originated. Fix at the source, not where the error appears.

**3-Strike Rule:** After 3 failed fix attempts, stop. Question the architecture. Are you fixing symptoms instead of the disease?

## SCORM Red Flags

- Fix reveals a *new* error elsewhere → chasing symptoms
- Same error returns after "fixing" → root cause is upstream
- API calls succeed locally but fail in LMS → timing/initialization, not logic
- `LMSGetValue` returns empty → check if `LMSInitialize` completed first (returned `"true"`)

## SCORM Debug Wrapper (paste into browser console)

```javascript
function wrapAPI(API) {
  const methods = ['LMSInitialize','LMSGetValue','LMSSetValue','LMSCommit','LMSFinish'];
  methods.forEach(method => {
    const original = API[method];
    API[method] = function() {
      const args = Array.from(arguments);
      const result = original.apply(API, args);
      console.log(`[SCORM] ${method}(${args.join(',')}) → ${result}`);
      if (result === 'false') {
        const err = API.LMSGetLastError();
        console.error(`  ERROR ${err}: ${API.LMSGetErrorString(err)}`);
      }
      return result;
    };
  });
  console.log('[SCORM] API wrapped — all calls will be logged');
}
// Usage: wrapAPI(window.API || window.parent.API)
```

## "Works locally, fails in LMS" Checklist

- [ ] API loaded before your code runs? (frame loading order)
- [ ] Inside iframe? (SCORM requires iframe context)
- [ ] All values are strings? (SCORM 1.2 = strings only)
- [ ] LMSInitialize called before GetValue/SetValue?
- [ ] LMSCommit called before page unload?
- [ ] LMSFinish('') fires on beforeunload? (Moodle does NOT auto-commit — missing this = data loss)
- [ ] Suspend data under 4096 chars? (SCORM 1.2 limit)

## Predict Failures Before Deploy

- What if LMSInitialize() is slow? (race condition with GetValue)
- What if the LMS doesn't support this cmi element? (returns "")
- What if the user closes browser mid-commit? (data loss)
- What if LMSCommit('') silently fails? (check error code after)
