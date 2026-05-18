---
name: image-gen
description: Generate images via Pollinations.ai (primary, API key in Keychain) or Gemini (fallback, requires billing). Use when asked to create, generate, or produce an image, mockup, or visual. Runs on Haiku — fast and free.
model: haiku
disable-model-invocation: true
---

# Image Generation

## Backend 1 — Pollinations.ai (primary)

API key stored in Keychain under service `pollinations-api`.

```bash
POLL_KEY=$(security find-generic-password -s "pollinations-api" -w)
curl -L -s -o image.png "https://gen.pollinations.ai/image/URL_ENCODED_PROMPT_HERE?width=1024&height=1024&model=flux&nologo=true&key=${POLL_KEY}"
```

For 1920x1080:
```bash
POLL_KEY=$(security find-generic-password -s "pollinations-api" -w)
curl -L -s -o image.png "https://gen.pollinations.ai/image/URL_ENCODED_PROMPT_HERE?width=1920&height=1080&model=flux&nologo=true&key=${POLL_KEY}"
```

## Backend 2 — Gemini (fallback, requires billing enabled)

```bash
GOOGLE_AI_API_KEY=$(security find-generic-password -s "gemini-api" -w)
curl -s -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent" \
  -H "x-goog-api-key: $GOOGLE_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"parts":[{"text":"PROMPT_HERE"}]}],"generationConfig":{"responseModalities":["TEXT","IMAGE"]}}' \
  | python3 -c "
import sys,json,base64
data=json.load(sys.stdin)
parts=data['candidates'][0]['content']['parts']
for i,p in enumerate(parts):
    if 'inlineData' in p:
        open(f'image_{i}.png','wb').write(base64.b64decode(p['inlineData']['data']))
        print(f'Saved: image_{i}.png')
"
```

## Steps

1. Ask what they need (subject, style, dimensions) if not provided
2. URL-encode the prompt (spaces → `%20`, special chars encoded)
3. Try Pollinations first (key from Keychain)
4. If Pollinations fails, fall back to Gemini
5. Open the file: `open image.png`
