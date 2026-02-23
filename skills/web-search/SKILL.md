---
name: web-search
description: Search the web and fetch page content without API keys. Uses DuckDuckGo HTML endpoint (fast, lightweight) with automatic fallback to CDP browser search (handles CAPTCHAs and JS-heavy pages). No external dependencies required.
---

# Web Search

Search the web and fetch page content using two approaches, selected automatically based on availability and need.

## Why this skill exists

OpenClaw requires a Brave Search API key for its built-in web search. This skill provides API-key-free alternatives using DuckDuckGo's HTML endpoint and the existing Cloudflare Browser Rendering infrastructure.

## Two Approaches

| | ddg-search.js | browser-search.js |
|---|---|---|
| **Speed** | Fast (~1-2s) | Slower (~10-15s) |
| **Dependencies** | None (Node.js built-in fetch) | CDP_SECRET + WORKER_URL |
| **JS rendering** | No | Yes |
| **CAPTCHA handling** | Detects, suggests fallback | Bypasses (real browser) |
| **Best for** | Quick lookups, most searches | CAPTCHA blocks, JS-heavy sites |

**Start with `ddg-search.js`**. Fall back to `browser-search.js` only when CAPTCHA is detected or JS rendering is required.

## Quick Start

### Search

```bash
# Fast search (recommended first attempt)
node skills/web-search/scripts/ddg-search.js "検索クエリ"

# Browser-based search (when ddg-search hits CAPTCHA or JS needed)
node skills/web-search/scripts/browser-search.js "検索クエリ"
```

### Fetch Page Content

```bash
# Lightweight fetch (static pages)
node skills/web-search/scripts/ddg-search.js --fetch https://example.com

# Browser fetch (JS-rendered pages, SPAs)
node skills/web-search/scripts/browser-search.js --fetch https://example.com
```

### Options

```bash
# Limit search results (default: 10)
node skills/web-search/scripts/ddg-search.js --max 5 "query"

# Limit fetched content length in characters (default: 20000)
node skills/web-search/scripts/ddg-search.js --fetch https://example.com --max 5000
```

## Output Format

### Search Results

```
## Search results for "query"

1. **Title**
   https://example.com/page
   Description snippet from search results...

2. **Title**
   https://example.com/other
   Another snippet...
```

### Fetched Page Content

Cleaned text with structure preserved (headings, lists, links). Scripts, styles, and navigation are stripped.

## Prerequisites

- **ddg-search.js**: Node.js 22+ (uses built-in `fetch`)
- **browser-search.js**: `CDP_SECRET` and `WORKER_URL` environment variables (already configured in container)

## Troubleshooting

- **CAPTCHA from DuckDuckGo**: DDG may throttle after many requests. Switch to `browser-search.js`
- **Empty results**: Try rephrasing the query or using English keywords
- **browser-search.js timeout**: CDP session may have expired. The script will retry connection once
