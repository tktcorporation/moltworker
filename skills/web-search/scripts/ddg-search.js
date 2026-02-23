#!/usr/bin/env node
/**
 * DuckDuckGo Web Search - Lightweight, API-key-free web search
 *
 * Searches DuckDuckGo's HTML endpoint using Node.js built-in fetch (no dependencies).
 * Falls back suggestion to browser-search.js when CAPTCHA is detected.
 *
 * Usage:
 *   node ddg-search.js "search query"           # Search DuckDuckGo
 *   node ddg-search.js --max 5 "search query"   # Limit to 5 results
 *   node ddg-search.js --fetch URL               # Fetch and extract page text
 *   node ddg-search.js --fetch URL --max 5000    # Fetch with char limit
 */

const SEARCH_URL = 'https://html.duckduckgo.com/html/';
const DEFAULT_MAX_RESULTS = 10;
const DEFAULT_MAX_CHARS = 20000;
const FETCH_TIMEOUT_MS = 15000;

// DuckDuckGo returns 403 or CAPTCHA pages when it suspects bot traffic.
// Matching on known CAPTCHA indicators lets us suggest the browser fallback early.
const CAPTCHA_INDICATORS = [
  'please click to continue',
  'robot',
  'captcha',
  'unusual traffic',
  '/challenge',
];

// --- Argument parsing ---

function parseArgs(argv) {
  const args = argv.slice(2);
  let mode = 'search';
  let query = '';
  let max = null;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--fetch') {
      mode = 'fetch';
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        query = args[++i];
      }
    } else if (args[i] === '--max') {
      if (i + 1 < args.length) {
        max = parseInt(args[++i], 10);
      }
    } else if (!args[i].startsWith('--')) {
      query = args[i];
    }
  }

  if (!query) {
    const modeHelp = mode === 'fetch'
      ? 'node ddg-search.js --fetch <url> [--max chars]'
      : 'node ddg-search.js [--max N] "search query"';
    console.error(`Usage: ${modeHelp}`);
    process.exit(1);
  }

  return { mode, query, max };
}

// --- HTML parsing utilities ---
// Minimal HTML-to-text conversion without external dependencies.
// We strip tags we don't need and preserve structural elements
// (headings, lists, links) for agent-readable output.

/**
 * Strip HTML tags matching given names (case-insensitive), including content.
 * Used to remove <script>, <style>, <nav>, <header>, <footer> etc.
 */
function stripTags(html, tagNames) {
  let result = html;
  for (const tag of tagNames) {
    const re = new RegExp(`<${tag}[^>]*>[\\s\\S]*?</${tag}>`, 'gi');
    result = result.replace(re, '');
  }
  return result;
}

/**
 * Convert HTML to readable text preserving structure.
 * - Headings become "## Heading"
 * - Links become "[text](href)"
 * - List items become "- item"
 * - Block elements get newlines
 * - All remaining tags are stripped
 */
function htmlToText(html) {
  let text = html;

  // Remove elements that add noise (navigation, scripts, styles, footers)
  text = stripTags(text, ['script', 'style', 'nav', 'header', 'footer', 'noscript', 'svg', 'iframe']);

  // Headings -> markdown-style
  text = text.replace(/<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>/gi, (_, content) => {
    return `\n## ${content.replace(/<[^>]+>/g, '').trim()}\n`;
  });

  // Links -> [text](href)
  text = text.replace(/<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, (_, href, content) => {
    const linkText = content.replace(/<[^>]+>/g, '').trim();
    if (!linkText) return '';
    // Skip anchors and javascript links
    if (href.startsWith('#') || href.startsWith('javascript:')) return linkText;
    return `[${linkText}](${href})`;
  });

  // List items -> "- item"
  text = text.replace(/<li[^>]*>([\s\S]*?)<\/li>/gi, (_, content) => {
    return `\n- ${content.replace(/<[^>]+>/g, '').trim()}`;
  });

  // Block elements -> newlines
  text = text.replace(/<\/?(?:div|p|br|tr|td|th|blockquote|pre|section|article|main)[^>]*>/gi, '\n');

  // Strip all remaining tags
  text = text.replace(/<[^>]+>/g, '');

  // Decode common HTML entities
  text = text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&#x27;/g, "'")
    .replace(/&#x2F;/g, '/')
    .replace(/&hellip;/g, '...')
    .replace(/&mdash;/g, '—')
    .replace(/&ndash;/g, '–')
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(parseInt(code, 10)));

  // Collapse whitespace while preserving intentional newlines
  text = text
    .split('\n')
    .map(line => line.replace(/[ \t]+/g, ' ').trim())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  return text;
}

// --- CAPTCHA detection ---

function detectCaptcha(html) {
  const lower = html.toLowerCase();
  return CAPTCHA_INDICATORS.some(indicator => lower.includes(indicator));
}

// --- Search mode ---

/**
 * Parse DuckDuckGo HTML search results page.
 * DDG's HTML endpoint returns a simple page with .result class divs,
 * each containing an <a> with the URL/title and a .result__snippet with text.
 */
function parseSearchResults(html, maxResults) {
  const results = [];

  // DuckDuckGo HTML results are in <div class="result ..."> blocks
  // Each has: <a class="result__a" href="...">Title</a>
  //           <a class="result__snippet">Snippet</a> or <td class="result__snippet">
  const resultPattern = /<div[^>]*class="[^"]*result[^"]*"[^>]*>([\s\S]*?)<\/div>\s*(?=<div[^>]*class="[^"]*result|$)/gi;
  const titleLinkPattern = /<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/i;
  const snippetPattern = /<(?:a|td|span)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/(?:a|td|span)>/i;

  let match;
  while ((match = resultPattern.exec(html)) !== null && results.length < maxResults) {
    const block = match[1];
    const titleMatch = titleLinkPattern.exec(block);
    if (!titleMatch) continue;

    let url = titleMatch[1];
    const title = titleMatch[2].replace(/<[^>]+>/g, '').trim();

    // DDG wraps URLs in a redirect; extract the actual destination
    // Format: //duckduckgo.com/l/?uddg=ENCODED_URL&rut=...
    if (url.includes('uddg=')) {
      const uddgMatch = url.match(/uddg=([^&]+)/);
      if (uddgMatch) {
        url = decodeURIComponent(uddgMatch[1]);
      }
    }

    const snippetMatch = snippetPattern.exec(block);
    const snippet = snippetMatch
      ? snippetMatch[1].replace(/<[^>]+>/g, '').trim()
      : '';

    if (title && url) {
      results.push({ title, url, snippet });
    }
  }

  return results;
}

async function searchDDG(query, maxResults) {
  const params = new URLSearchParams({ q: query });
  const response = await fetch(SEARCH_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      // Mimic a simple browser to reduce CAPTCHA risk
      'User-Agent': 'Mozilla/5.0 (compatible; search-skill/1.0)',
    },
    body: params.toString(),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });

  if (!response.ok) {
    throw new Error(`DuckDuckGo returned HTTP ${response.status}`);
  }

  const html = await response.text();

  if (detectCaptcha(html)) {
    console.error('Warning: DuckDuckGo returned a CAPTCHA page.');
    console.error('Fallback: use browser-search.js instead:');
    console.error(`  node skills/web-search/scripts/browser-search.js "${query}"`);
    process.exit(2);
  }

  const results = parseSearchResults(html, maxResults);

  if (results.length === 0) {
    console.log(`## Search results for "${query}"\n\nNo results found.`);
    return;
  }

  const lines = [`## Search results for "${query}"\n`];
  results.forEach((r, i) => {
    lines.push(`${i + 1}. **${r.title}**`);
    lines.push(`   ${r.url}`);
    if (r.snippet) {
      lines.push(`   ${r.snippet}`);
    }
    lines.push('');
  });

  console.log(lines.join('\n'));
}

// --- Fetch mode ---

async function fetchPage(url, maxChars) {
  const response = await fetch(url, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (compatible; search-skill/1.0)',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    redirect: 'follow',
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${url}`);
  }

  const contentType = response.headers.get('content-type') || '';

  // For non-HTML content, return raw text
  if (!contentType.includes('html')) {
    const text = await response.text();
    const trimmed = text.slice(0, maxChars);
    if (text.length > maxChars) {
      console.log(trimmed + `\n\n[Truncated at ${maxChars} characters]`);
    } else {
      console.log(trimmed);
    }
    return;
  }

  const html = await response.text();
  let text = htmlToText(html);

  if (text.length > maxChars) {
    text = text.slice(0, maxChars) + `\n\n[Truncated at ${maxChars} characters]`;
  }

  console.log(text);
}

// --- Main ---

async function main() {
  const { mode, query, max } = parseArgs(process.argv);

  try {
    if (mode === 'fetch') {
      await fetchPage(query, max || DEFAULT_MAX_CHARS);
    } else {
      await searchDDG(query, max || DEFAULT_MAX_RESULTS);
    }
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }
}

main();
