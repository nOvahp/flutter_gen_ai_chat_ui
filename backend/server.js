require('dotenv').config();
const express = require('express');
const fetch = require('node-fetch');

const app = express();
const PORT = process.env.PORT || 3000;

// ─────────────────────────────────────────────────────────
// Middleware
// ─────────────────────────────────────────────────────────

// Allow all cross-origin requests (Flutter Web needs this)
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, Accept, Cache-Control');
  if (req.method === 'OPTIONS') return res.status(204).end();
  next();
});
app.use(express.json());

// ─────────────────────────────────────────────────────────
// Config check on startup
// ─────────────────────────────────────────────────────────

if (!process.env.OPENROUTER_API_KEY || 
    process.env.OPENROUTER_API_KEY === 'sk-or-v1-your-key-here') {
  console.error('\n❌  ERROR: OPENROUTER_API_KEY is not set in .env file');
  console.error('   Get your key at: https://openrouter.ai/keys\n');
  process.exit(1);
}

console.log(`✅  Model: ${process.env.MODEL}`);
console.log(`✅  Model: ${process.env.MODEL}`);
console.log(`✅  Base URL: ${process.env.OPENROUTER_BASE_URL || 'https://openrouter.ai/api/v1'}`);
console.log(`✅  OpenRouter key loaded (${process.env.OPENROUTER_API_KEY.slice(0, 12)}...)\n`);

// ─────────────────────────────────────────────────────────
// Health check
// ─────────────────────────────────────────────────────────

app.get('/health', (req, res) => {
  res.json({ status: 'ok', model: process.env.MODEL });
});

// ─────────────────────────────────────────────────────────
// POST /api/chat/stream
//
// Body:
// {
//   "message": "Summarize the meeting",
//   "history": [                          ← optional
//     { "role": "user",      "content": "..." },
//     { "role": "assistant", "content": "..." }
//   ],
//   "system_prompt": "You are a..."       ← optional
// }
//
// Response: SSE stream
// data: {"delta": "Hello"}
// data: {"delta": " there"}
// data: [DONE]
// ─────────────────────────────────────────────────────────

app.post('/api/chat/stream', async (req, res) => {
  const { message, history = [], system_prompt } = req.body;

  // ── Validate ────────────────────────────────────────────
  if (!message || typeof message !== 'string' || message.trim() === '') {
    return res.status(400).json({ error: 'message is required' });
  }

  // ── Set SSE headers ─────────────────────────────────────
  // These headers tell the client this is a streaming response
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders(); // send headers immediately

  // ── Build messages array for OpenRouter ─────────────────
  const messages = [];

  // Add system prompt if provided, else use a default
  messages.push({
    role: 'system',
    content: system_prompt || 
      'You are a helpful assistant for meeting notes and documents. ' +
      'Be concise and clear in your responses. ' +
      'Use markdown formatting when it helps readability.'
  });

  // Add conversation history
  for (const item of history) {
    if (item.role && item.content) {
      messages.push({ role: item.role, content: item.content });
    }
  }

  // Add the new user message
  messages.push({ role: 'user', content: message.trim() });

  // ── Call OpenRouter with streaming ──────────────────────
  let openRouterResponse;

  try {
    const baseUrl = process.env.OPENROUTER_BASE_URL || 'https://openrouter.ai/api/v1';
    openRouterResponse = await fetch(`${baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.OPENROUTER_API_KEY}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': process.env.APP_URL || 'http://localhost:3000',
        'X-Title': process.env.APP_NAME || 'MeetingChatApp',
      },
      body: JSON.stringify({
        model: process.env.MODEL,
        messages: messages,
        stream: true,       // ← enable SSE streaming
        max_tokens: 2048,
        temperature: 0.7,
      }),
    });
  } catch (networkError) {
    // Could not reach OpenRouter at all
    console.error('Network error reaching OpenRouter:', networkError.message);
    res.write(`data: ${JSON.stringify({ error: 'Could not reach AI service' })}\n\n`);
    return res.end();
  }

  // ── Handle non-200 from OpenRouter ──────────────────────
  if (!openRouterResponse.ok) {
    let errorBody = '';
    try {
      errorBody = await openRouterResponse.text();
    } catch (_) {}

    console.error(`OpenRouter error ${openRouterResponse.status}:`, errorBody);

    let userMessage = 'AI service error.';
    if (openRouterResponse.status === 401) userMessage = 'Invalid API key.';
    if (openRouterResponse.status === 402) userMessage = 'Insufficient credits on OpenRouter.';
    if (openRouterResponse.status === 429) userMessage = 'Rate limit reached. Try again later.';

    res.write(`data: ${JSON.stringify({ error: userMessage })}\n\n`);
    return res.end();
  }

  // ── Stream OpenRouter's SSE response to Flutter ─────────
  //
  // OpenRouter sends chunks like:
  //   data: {"id":"...","choices":[{"delta":{"content":"Hello"}}]}
  //   data: {"id":"...","choices":[{"delta":{"content":" there"}}]}
  //   data: [DONE]
  //
  // We parse each chunk and re-emit in our simpler format:
  //   data: {"delta": "Hello"}
  //   data: [DONE]
  //
  let buffer = '';

  openRouterResponse.body.on('data', (chunk) => {
    buffer += chunk.toString('utf8');

    // Process all complete lines in the buffer
    const lines = buffer.split('\n');

    // Keep the last (possibly incomplete) line in the buffer
    buffer = lines.pop() || '';

    for (const line of lines) {
      const trimmed = line.trim();

      // Skip empty lines and OpenRouter keep-alive comments
      if (!trimmed || trimmed.startsWith(':')) continue;

      // SSE lines start with "data: "
      if (!trimmed.startsWith('data:')) continue;

      const data = trimmed.slice(5).trim(); // remove "data:" prefix

      // End of stream
      if (data === '[DONE]') {
        res.write('data: [DONE]\n\n');
        return res.end();
      }

      // Parse the JSON chunk from OpenRouter
      try {
        const parsed = JSON.parse(data);

        // Check for mid-stream error from OpenRouter
        if (parsed.error) {
          console.error('Mid-stream OpenRouter error:', parsed.error);
          res.write(`data: ${JSON.stringify({ error: parsed.error.message || 'Stream error' })}\n\n`);
          return res.end();
        }

        // Extract the text delta
        // OpenRouter format: choices[0].delta.content
        const delta = parsed?.choices?.[0]?.delta?.content;

        // Only forward if there's actual text content
        if (delta) {
          // Re-emit in our simpler format for Flutter to parse
          res.write(`data: ${JSON.stringify({ delta })}\n\n`);
        }

      } catch (parseError) {
        // Malformed JSON line — skip silently
        // (OpenRouter occasionally sends non-JSON comment lines)
      }
    }
  });

  // ── Stream finished cleanly ──────────────────────────────
  openRouterResponse.body.on('end', () => {
    res.write('data: [DONE]\n\n');
    res.end();
  });

  // ── Stream error ─────────────────────────────────────────
  openRouterResponse.body.on('error', (streamError) => {
    console.error('Stream error:', streamError.message);
    try {
      res.write(`data: ${JSON.stringify({ error: 'Stream interrupted' })}\n\n`);
      res.end();
    } catch (_) {
      // Response already ended
    }
  });

  // ── Client disconnected mid-stream ───────────────────────
  req.on('close', () => {
    // Flutter app disconnected — clean up
    openRouterResponse.body.destroy();
  });
});

// ─────────────────────────────────────────────────────────
// Start server
// ─────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`🚀  Backend running at http://localhost:${PORT}`);
  console.log(`    Health check: http://localhost:${PORT}/health`);
  console.log(`    Chat endpoint: POST http://localhost:${PORT}/api/chat/stream\n`);
});
