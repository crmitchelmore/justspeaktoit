/**
 * Simple Bun development server for the landing page
 * Run with: bun run serve.ts
 */

const server = Bun.serve({
  port: 3000,
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname;
    
    // Default to index.html
    if (path === "/" || path === "") {
      path = "/index.html";
    }
    
    // Try to serve the file
    const filePath = `.${path}`;
    const file = Bun.file(filePath);
    
    if (await file.exists()) {
      // Determine content type
      const ext = path.split('.').pop()?.toLowerCase();
      const contentTypes: Record<string, string> = {
        html: "text/html; charset=utf-8",
        css: "text/css; charset=utf-8",
        js: "application/javascript; charset=utf-8",
        json: "application/json; charset=utf-8",
        png: "image/png",
        jpg: "image/jpeg",
        jpeg: "image/jpeg",
        gif: "image/gif",
        svg: "image/svg+xml",
        ico: "image/x-icon",
        woff: "font/woff",
        woff2: "font/woff2",
      };
      
      return new Response(file, {
        headers: {
          "Content-Type": contentTypes[ext || ""] || "application/octet-stream",
          "Cache-Control": "no-cache",
        },
      });
    }
    
    // 404 fallback
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`
🎙️  JustSpeakToIt Landing Page
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🌐 Server running at: http://localhost:${server.port}

Press Ctrl+C to stop
`);
