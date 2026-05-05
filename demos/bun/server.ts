// Bun TechEmpower benchmark
// Mesmas rotas do Spider para comparação direta

const sql = new Bun.SQL({
  host: "localhost",
  port: 5432,
  database: "hello_world",
  user: "benchmark",
  password: "benchmark",
  pool_size: 16,
});

interface World {
  id: number;
  randomnumber: number;
}

interface Fortune {
  id: number;
  message: string;
}

function randomId(): number {
  return Math.floor(Math.random() * 10000) + 1;
}

const server = Bun.serve({
  port: 3001,

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    // 1. Plaintext
    if (path === "/plaintext") {
      return new Response("Hello, World!", {
        headers: { "Content-Type": "text/plain" },
      });
    }

    // 2. JSON
    if (path === "/json") {
      return Response.json({ message: "Hello, World!" });
    }

    // 3. DB — single query
    if (path === "/db") {
      const id = randomId();
      const rows = await sql`
        SELECT id, randomnumber FROM world WHERE id = ${id}
      `;
      const row = (rows[0] as World) ?? { id, randomnumber: 0 };
      return Response.json(row);
    }

    // 4. Queries — optimized with ANY (benchmark style)
    if (path === "/queries") {
      const n = Math.min(
        Math.max(parseInt(url.searchParams.get("queries") ?? "1") || 1, 1),
        20
      );
      const ids = Array.from({ length: n }, () => randomId());
      const rows = await sql`
        SELECT id, randomnumber FROM world WHERE id = ANY(${sql.array(ids, "INT")})
      `;
      return Response.json(rows as World[]);
    }

    // 4b. Queries-Real — N separate queries in parallel (TechEmpower strict)
    if (path === "/queries-real") {
      const n = Math.min(
        Math.max(parseInt(url.searchParams.get("queries") ?? "1") || 1, 1),
        20
      );
      const results = await Promise.all(
        Array.from({ length: n }, async () => {
          const id = randomId();
          const rows = await sql`
            SELECT id, randomnumber FROM world WHERE id = ${id}
          `;
          return (rows[0] as World) ?? { id, randomnumber: 0 };
        })
      );
      return Response.json(results);
    }

    // 5. Fortunes
    if (path === "/fortunes") {
      const rows = (await sql`SELECT id, message FROM fortune`) as Fortune[];

      const fortunes: Fortune[] = [
        { id: 0, message: "Additional fortune added at request time." },
        ...rows,
      ];

      fortunes.sort((a, b) => a.message.localeCompare(b.message));

      const rows_html = fortunes
        .map((f) => `<tr><td>${f.id}</td><td>${f.message}</td></tr>`)
        .join("\n");

      const html = `<!DOCTYPE html>
<html><head><title>Fortunes</title></head>
<body><table>
<tr><th>id</th><th>message</th></tr>
${rows_html}
</table></body></html>`;

      return new Response(html, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Bun server running on http://localhost:${server.port}`);
