#!/usr/bin/env node
/**
 * Browser-Based Web Search - CDP-powered search via Cloudflare Browser Rendering
 *
 * Uses headless Chrome to perform DuckDuckGo searches, bypassing CAPTCHAs that
 * block the lightweight ddg-search.js approach. Also handles JS-rendered pages.
 *
 * Requires CDP_SECRET and WORKER_URL environment variables (already available
 * in the OpenClaw container via env.ts).
 *
 * Usage:
 *   node browser-search.js "search query"           # Search DuckDuckGo
 *   node browser-search.js --max 5 "search query"   # Limit to 5 results
 *   node browser-search.js --fetch URL               # Fetch JS-rendered page
 *   node browser-search.js --fetch URL --max 5000    # Fetch with char limit
 */

const path = require('path');
const { createClient } = require('../../cloudflare-browser/scripts/cdp-client');

const DEFAULT_MAX_RESULTS = 10;
const DEFAULT_MAX_CHARS = 20000;
const SEARCH_URL = 'https://html.duckduckgo.com/html/';
const NAV_WAIT_MS = 5000;

// --- Argument parsing (same interface as ddg-search.js) ---

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
      ? 'node browser-search.js --fetch <url> [--max chars]'
      : 'node browser-search.js [--max N] "search query"';
    console.error(`Usage: ${modeHelp}`);
    process.exit(1);
  }

  return { mode, query, max };
}

// --- DOM extraction expressions ---
// These JavaScript expressions run inside the browser page via Runtime.evaluate.
// They extract structured data from DuckDuckGo's HTML result page and
// arbitrary web pages into agent-readable formats.

/**
 * Extract search results from DuckDuckGo's HTML page.
 * Returns JSON array of {title, url, snippet} objects.
 * DDG's HTML endpoint uses .result containers with .result__a and .result__snippet elements.
 */
const EXTRACT_SEARCH_RESULTS = `
(() => {
  const results = [];
  document.querySelectorAll('.result').forEach(el => {
    const linkEl = el.querySelector('.result__a');
    const snippetEl = el.querySelector('.result__snippet');
    if (!linkEl) return;
    let url = linkEl.href || '';
    // DDG redirect URLs contain the real URL in the uddg parameter
    if (url.includes('uddg=')) {
      try { url = decodeURIComponent(url.match(/uddg=([^&]+)/)[1]); } catch {}
    }
    results.push({
      title: linkEl.textContent.trim(),
      url: url,
      snippet: snippetEl ? snippetEl.textContent.trim() : ''
    });
  });
  return JSON.stringify(results);
})()
`;

/**
 * Extract readable text from any page, preserving structure.
 * Removes noise elements (script, style, nav, footer, header) and returns
 * cleaned text. Headings are prefixed with "## " for markdown-like readability.
 */
const EXTRACT_PAGE_TEXT = `
(() => {
  // Remove noise elements
  const remove = ['script', 'style', 'nav', 'footer', 'header', 'noscript', 'svg', 'iframe'];
  remove.forEach(tag => {
    document.querySelectorAll(tag).forEach(el => el.remove());
  });

  // Convert headings to markdown-style
  document.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(el => {
    el.textContent = '\\n## ' + el.textContent.trim() + '\\n';
  });

  // Convert links to markdown-style
  document.querySelectorAll('a[href]').forEach(el => {
    const href = el.href;
    const text = el.textContent.trim();
    if (text && href && !href.startsWith('javascript:') && !href.startsWith('#')) {
      el.textContent = '[' + text + '](' + href + ')';
    }
  });

  // Convert list items
  document.querySelectorAll('li').forEach(el => {
    el.textContent = '- ' + el.textContent.trim();
  });

  // Get text and clean up whitespace
  let text = document.body.innerText || '';
  text = text.split('\\n')
    .map(line => line.trim())
    .filter((line, i, arr) => !(line === '' && arr[i - 1] === ''))
    .join('\\n')
    .trim();

  return text;
})()
`;

// --- Search mode ---

async function searchWithBrowser(query, maxResults) {
  console.error(`Searching DuckDuckGo via browser for: ${query}`);

  const client = await createClient();

  try {
    // Navigate to DuckDuckGo HTML search with POST via form submission.
    // We navigate to the HTML endpoint then use Runtime.evaluate to submit
    // a search form, since CDP Page.navigate only does GET requests.
    // Alternative: navigate directly with query params (DDG HTML supports GET too).
    const searchUrl = `${SEARCH_URL}?q=${encodeURIComponent(query)}`;
    await client.navigate(searchUrl, NAV_WAIT_MS);

    // Extract results from the rendered page
    const result = await client.evaluate(EXTRACT_SEARCH_RESULTS);
    const value = result.result?.value;

    if (!value) {
      console.log(`## Search results for "${query}"\n\nNo results found (page may require interaction).`);
      return;
    }

    let results;
    try {
      results = JSON.parse(value);
    } catch {
      console.log(`## Search results for "${query}"\n\nFailed to parse results.`);
      return;
    }

    results = results.slice(0, maxResults);

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

  } finally {
    client.close();
  }
}

// --- Fetch mode ---

async function fetchWithBrowser(url, maxChars) {
  console.error(`Fetching via browser: ${url}`);

  const client = await createClient();

  try {
    await client.navigate(url, NAV_WAIT_MS);

    const result = await client.evaluate(EXTRACT_PAGE_TEXT);
    let text = result.result?.value || '';

    if (!text) {
      console.log('[Page returned no readable text content]');
      return;
    }

    if (text.length > maxChars) {
      text = text.slice(0, maxChars) + `\n\n[Truncated at ${maxChars} characters]`;
    }

    console.log(text);

  } finally {
    client.close();
  }
}

// --- Main ---

async function main() {
  // Validate environment early
  if (!process.env.CDP_SECRET) {
    console.error('Error: CDP_SECRET environment variable not set');
    console.error('This script requires Cloudflare Browser Rendering access.');
    console.error('For searches without CDP, use ddg-search.js instead.');
    process.exit(1);
  }
  if (!process.env.WORKER_URL) {
    console.error('Error: WORKER_URL environment variable not set');
    process.exit(1);
  }

  const { mode, query, max } = parseArgs(process.argv);

  try {
    if (mode === 'fetch') {
      await fetchWithBrowser(query, max || DEFAULT_MAX_CHARS);
    } else {
      await searchWithBrowser(query, max || DEFAULT_MAX_RESULTS);
    }
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }
}

main();
