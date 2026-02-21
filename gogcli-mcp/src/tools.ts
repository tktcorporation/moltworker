import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { execGog } from './exec.js';

export function registerTools(server: McpServer): void {
  server.tool(
    'gmail_search',
    'Search Gmail messages. Uses Gmail search syntax.',
    { query: z.string().describe('Gmail search query'), maxResults: z.number().optional().describe('Max results') },
    async ({ query, maxResults }) => {
      const args = ['gmail', 'search', query];
      if (maxResults) args.push('--max-results', String(maxResults));
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'gmail_read',
    'Read a specific Gmail message by ID.',
    { messageId: z.string().describe('Gmail message ID') },
    async ({ messageId }) => {
      const result = await execGog(['gmail', 'read', messageId]);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'gmail_send',
    'Send an email via Gmail.',
    {
      to: z.string().describe('Recipient email address'),
      subject: z.string().describe('Email subject'),
      body: z.string().describe('Email body text'),
    },
    async ({ to, subject, body }) => {
      const result = await execGog(['gmail', 'send', '--to', to, '--subject', subject, '--body', body]);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'calendar_events',
    'List upcoming Google Calendar events.',
    { maxResults: z.number().optional().describe('Max results'), calendarId: z.string().optional().describe('Calendar ID') },
    async ({ maxResults, calendarId }) => {
      const args = ['calendar', 'events'];
      if (maxResults) args.push('--max-results', String(maxResults));
      if (calendarId) args.push('--calendar-id', calendarId);
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'calendar_create',
    'Create a new Google Calendar event.',
    {
      title: z.string().describe('Event title'),
      start: z.string().describe('Start time (ISO 8601)'),
      end: z.string().describe('End time (ISO 8601)'),
      description: z.string().optional().describe('Event description'),
    },
    async ({ title, start, end, description }) => {
      const args = ['calendar', 'create', '--title', title, '--start', start, '--end', end];
      if (description) args.push('--description', description);
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'drive_search',
    'Search Google Drive files.',
    { query: z.string().describe('Drive search query'), maxResults: z.number().optional().describe('Max results') },
    async ({ query, maxResults }) => {
      const args = ['drive', 'search', query];
      if (maxResults) args.push('--max-results', String(maxResults));
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'drive_list',
    'List files in a Google Drive folder.',
    { folderId: z.string().optional().describe('Folder ID (root if omitted)'), maxResults: z.number().optional().describe('Max results') },
    async ({ folderId, maxResults }) => {
      const args = ['drive', 'list'];
      if (folderId) args.push('--folder-id', folderId);
      if (maxResults) args.push('--max-results', String(maxResults));
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'contacts_search',
    'Search Google Contacts.',
    { query: z.string().describe('Contact search query'), maxResults: z.number().optional().describe('Max results') },
    async ({ query, maxResults }) => {
      const args = ['contacts', 'search', query];
      if (maxResults) args.push('--max-results', String(maxResults));
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'tasks_list',
    'List Google Tasks task lists.',
    { maxResults: z.number().optional().describe('Max results') },
    async ({ maxResults }) => {
      const args = ['tasks', 'list'];
      if (maxResults) args.push('--max-results', String(maxResults));
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );

  server.tool(
    'tasks_get',
    'Get tasks from a specific Google Tasks list.',
    { taskListId: z.string().describe('Task list ID'), maxResults: z.number().optional().describe('Max results') },
    async ({ taskListId, maxResults }) => {
      const args = ['tasks', 'get', taskListId];
      if (maxResults) args.push('--max-results', String(maxResults));
      const result = await execGog(args);
      return { content: [{ type: 'text' as const, text: result.stdout || result.stderr }] };
    },
  );
}
