---
name: pkm-enrich
description: Enrich PKM movie or book notes with API data. Use when asked to "enrich movie", "add movie <title>", "enrich book", "add book <title>", "batch enrich inbox", or "populate movie notes". Calls TMDB + OMDb for movies and Google Books for books, writes fully-populated notes using vault templates.
argument-hint: "[movie|book] <title> OR inbox"
---

# PKM Enrich

Enriches Obsidian PKM vault notes with API data. Handles three modes:
- **Single movie**: `pkm-enrich movie <title>`
- **Single book**: `pkm-enrich book <title>`
- **Batch inbox**: `pkm-enrich inbox` (processes all files in `00 Capture/`)

## Setup

API keys are in `~/.env`. Always source before making curl calls:
```bash
source ~/.env
# Keys available: $TMDB_API_KEY, $OMDB_API_KEY
```

Vault root: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM/`

---

## Mode 1: Enrich a Movie

### Step 1: Check if note already exists
```bash
# Glob: 50 Collections/Movies/<Title>.md
```
If file exists → report "Already exists, skipping." Stop.

### Step 2: Fetch TMDB data
```bash
source ~/.env
curl -s "https://api.themoviedb.org/3/search/movie?query=<TITLE_URL_ENCODED>&api_key=$TMDB_API_KEY"
```
Extract from first result:
- `id` → tmdb_id
- `title` → title
- `release_date` (YYYY-MM-DD, take year) → year
- `overview` → overview
- `poster_path` → poster_url = `https://image.tmdb.org/t/p/w500<poster_path>`

If no results → tell user, stop.

### Step 3: Fetch OMDb data
```bash
source ~/.env
curl -s "http://www.omdbapi.com/?t=<TITLE_URL_ENCODED>&apikey=$OMDB_API_KEY"
```
Extract:
- `Director` → director
- `Writer` → writer
- `Actors` → cast (comma-separated → convert to YAML array)
- `Genre` → genres (comma-separated → convert to YAML array)
- `Language` → language
- `Country` → country
- `imdbRating` → rating_imdb
- `Ratings[source=Rotten Tomatoes].Value` → rating_rt
- `Runtime` → runtime_min (strip " min", keep number)
- `Awards` → awards
- `imdbID` → imdb_id

### Step 4: Build trailer link
YouTube search URL (no API needed):
```
https://www.youtube.com/results?search_query=<TITLE+YEAR>+official+trailer
```

### Step 5: Write the note
Path: `50 Collections/Movies/<Title>.md`
Use title exactly as returned by TMDB. Replace `/` or `:` with `-` for filename.

```markdown
---
title: <title>
year: <year>
director: <director>
writer: <writer>
genres: [<genre1>, <genre2>]
cast: [<actor1>, <actor2>, <actor3>]
language: <language>
country: <country>
rating_imdb: <rating_imdb>
rating_rt: <rating_rt>
rating_personal:
status: to-watch
poster_url: <poster_url>
tmdb_id: <tmdb_id>
imdb_id: <imdb_id>
trailer_link: <trailer_url>
overview: "<overview>"
runtime_min: <runtime_min>
awards: <awards>
date_added: <TODAY_YYYY-MM-DD>
date_watched:
tags: [movie]
---

![poster](<poster_url>)

# <title> (<year>)

> <overview>

| Field | Value |
|---|---|
| Director | <director> |
| Cast | <cast_comma_list> |
| Genres | <genres_comma_list> |
| Runtime | <runtime_min> min |
| IMDB | ⭐ <rating_imdb> |
| Rotten Tomatoes | 🍅 <rating_rt> |
| Trailer | [Watch Trailer](<trailer_link>) |
| Awards | <awards> |
| Language | <language> |

## My Notes


## Themes & Connections

```

### Step 6: Confirm
Report: "✓ Created `50 Collections/Movies/<Title>.md` — poster, IMDB <rating>, RT <rating_rt>"

---

## Mode 2: Enrich a Book

### Step 1: Check if note exists
Glob `50 Collections/Books/<Title>.md` → exists? skip.

### Step 2: Fetch Google Books
```bash
curl -s "https://www.googleapis.com/books/v1/volumes?q=intitle:<TITLE_URL_ENCODED>"
```
From `items[0].volumeInfo`:
- `title` → title
- `authors[0]` → author
- `publishedDate` (take year) → year
- `description` → overview
- `categories` → genres (array)
- `pageCount` → pages
- `imageLinks.thumbnail` → cover_url (replace `http://` with `https://`, add `&fife=w400` for better res)
- `industryIdentifiers[type=ISBN_13].identifier` → isbn

### Step 3: Write the note
Path: `50 Collections/Books/<Title>.md`

```markdown
---
title: <title>
author: <author>
year: <year>
genres: [<genre1>]
pages: <pages>
isbn: <isbn>
cover_url: <cover_url>
overview: "<overview>"
status: to-read
rating_personal:
date_added: <TODAY_YYYY-MM-DD>
date_started:
date_finished:
tags: [book]
related: []
---

![cover](<cover_url>)

# <title>
### <author> (<year>)

> <overview>

## Notes


## Key Ideas


```

### Step 4: Confirm
Report: "✓ Created `50 Collections/Books/<Title>.md`"

---

## Mode 3: Batch Inbox

### Step 1: List inbox files
```bash
ls ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/PKM/00 Capture/
```

### Step 2: For each file
- Read frontmatter to detect type (`tags: [movie]` or `tags: [book]`) or infer from filename
- Run Mode 1 or Mode 2 using the title from frontmatter or filename
- On success: delete the inbox file (`rm`)
- On failure (API miss): leave file, flag to user

### Step 3: Summary
Report count: X movies enriched, Y books enriched, Z skipped (already exist), W failed (list titles).

---

## Notes

- **Date format**: always `YYYY-MM-DD`
- **Filename sanitization**: strip `:`, `/`, `?` from titles for filenames; keep display title intact in frontmatter
- **OMDb miss**: if OMDb returns `"Response":"False"`, write note with TMDB data only — leave `rating_imdb`, `rating_rt`, `awards` blank rather than failing
- **Google Books miss**: if no results, write a stub note with just the title and `status: to-read` — user can fill later
- **Never read `_Private/`** — excluded from all operations
- **poster_url is critical**: Dataview gallery breaks without it — always verify it's set before reporting success
- **Genres/cast as YAML arrays**: `[Drama, Thriller]` not `"Drama, Thriller"` — Dataview filters depend on array type
