# Bun Benchmark Results - TechEmpower Style

## Configuração do Ambiente

### PostgreSQL (Docker)
```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:16
    container_name: pg-benchmark
    environment:
      POSTGRES_USER: benchmark
      POSTGRES_PASSWORD: benchmark
      POSTGRES_DB: hello_world
    ports:
      - "5432:5432"
    command: >
      postgres
      -c max_connections=100
      -c shared_buffers=1GB
      -c effective_cache_size=3GB
      -c work_mem=4MB
      -c maintenance_work_mem=256MB
      -c synchronous_commit=off
      -c wal_level=minimal
      -c max_wal_senders=0
      -c max_wal_size=1GB
      -c checkpoint_timeout=15min
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

### Bun Server (server.ts)
```typescript
const sql = new Bun.SQL({
  host: "localhost",
  port: 5432,
  database: "hello_world",
  user: "benchmark",
  password: "benchmark",
  pool_size: 16, // Realista: 10-20 conexões
});
```

### Preparação do Banco
```bash
docker exec pg-benchmark psql -U benchmark -d hello_world -c "
CREATE TABLE world (
  id INTEGER PRIMARY KEY,
  randomnumber INTEGER NOT NULL
);

INSERT INTO world (id, randomnumber)
SELECT i, (random() * 10000)::int
FROM generate_series(1, 10000) AS i;
"
```

---

## Rotas Implementadas

### 1. GET /plaintext
- Retorna texto puro: `"Hello, World!"`
- Header: `Content-Type: text/plain`

### 2. GET /json
- Retorna JSON: `{ "message": "Hello, World!" }`
- Header: `Content-Type: application/json`

### 3. GET /db
- 1 query no PostgreSQL (aleatória)
- Retorna: `{ "id": 123, "randomnumber": 456 }`
- **Implementação realista**

### 4. GET /queries?queries=N (otimizada)
- Usa `ANY(${sql.array(ids, "INT")})` 
- **1 query única** com array (NÃO é o padrão TechEmpower)
- ⚠️ **Otimização não permitida no TFB oficial**

### 5. GET /queries-real?queries=N (padrão TFB)
- **N queries separadas em paralelo** (Promise.all)
- Cada query: `SELECT id, randomnumber FROM world WHERE id = ${id}`
- **Fiel ao benchmark TechEmpower**

---

## Resultados dos Benchmarks

### Máquina de Teste
- **wrk**: 4 threads, 200 conexões, 15 segundos
- **PostgreSQL**: Docker com `synchronous_commit=off`, `max_connections=100`
- **Bun**: `pool_size=16`

---

### GET /db (1 query)

**Comando:**
```bash
wrk -t4 -c200 -d15s http://localhost:3001/db
```

**Resultados:**
| Métrica | Valor |
|--------|-------|
| **Requests/sec** | **21,886** |
| Latência Avg | 9.11ms |
| Latência p50 | 8.95ms |
| Latência p99 | **15.69ms** |
| Erros | 0 |

✅ **Avaliação**: Excelente (≥ 15k RPS, p99 < 50ms)

---

### GET /queries?queries=20 (otimizada com ANY)

**Comando:**
```bash
wrk -t4 -c200 -d15s "http://localhost:3001/queries?queries=20"
```

**Resultados:**
| Métrica | Valor |
|--------|-------|
| **Requests/sec** | **17,076** |
| Latência Avg | 11.70ms |
| Latência p50 | 11.39ms |
| Latência p99 | **20.24ms** |
| Erros | 0 |

⚠️ **Avaliação**: Rápido, mas **NÃO é o padrão TFB** (virou 1 query com ANY)

---

### GET /queries-real?queries=20 (padrão TFB)

**Comando:**
```bash
wrk -t4 -c200 -d15s "http://localhost:3001/queries-real?queries=20"
```

**Resultados:**
| Métrica | Valor |
|--------|-------|
| **Requests/sec** | **2,382** |
| Latência Avg | 83.85ms |
| Latência p50 | 86.20ms |
| Latência p99 | **120.59ms** |
| Erros | 0 |

❌ **Avaliação**: Abaixo do esperado (~5k-10k RPS, p99 < 80ms)

**Análise:**
- Pool pequeno (16) + 200 conexões HTTP × 20 queries = 4.000 queries simultâneas
- Gargalo no pool de conexões do banco
- Cada requisição leva ~20 round-trips sequenciais no pool

---

## Como Rodar os Testes

### 1. Subir o PostgreSQL
```bash
cd /home/seven/repos/zig/web/spider/bench/bun
docker-compose up -d
sleep 5
```

### 2. Preparar o Banco
```bash
docker exec pg-benchmark psql -U benchmark -d hello_world -c "
CREATE TABLE IF NOT EXISTS world (id INTEGER PRIMARY KEY, randomnumber INTEGER NOT NULL);
INSERT INTO world (id, randomnumber) SELECT i, (random() * 10000)::int FROM generate_series(1, 10000) AS i;
"
```

### 3. Iniciar o Servidor Bun
```bash
cd /home/seven/repos/zig/web/spider/bench/bun
bun run server.ts > bun.log 2>&1 &
sleep 2
pgrep -a bun  # Verificar se está rodando
```

### 4. Testar Rotas Manualmente
```bash
# Testar /db
curl -s http://localhost:3001/db

# Testar /queries (otimizada)
curl -s "http://localhost:3001/queries?queries=20" | head -c 200

# Testar /queries-real (padrão TFB)
curl -s "http://localhost:3001/queries-real?queries=20" | head -c 200
```

### 5. Rodar Benchmarks
```bash
# /db
wrk -t4 -c200 -d15s http://localhost:3001/db

# /queries (otimizada)
wrk -t4 -c200 -d15s "http://localhost:3001/queries?queries=20"

# /queries-real (padrão TFB)
wrk -t4 -c200 -d15s "http://localhost:3001/queries-real?queries=20"

# Com latências detalhadas (precisa do script Lua)
cat > /tmp/wrk_latency.lua << 'EOF'
wrk.method = "GET"
function done(summary, latency, requests)
  io.write("Latency p50: " .. string.format("%.2f", latency:percentile(50)) .. "ms\n")
  io.write("Latency p99: " .. string.format("%.2f", latency:percentile(99)) .. "ms\n")
  io.write("Errors: " .. summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout .. "\n")
end
EOF

wrk -t4 -c200 -d15s -s /tmp/wrk_latency.lua "http://localhost:3001/queries-real?queries=20"
```

### 6. Parar o Servidor
```bash
pkill -f "bun run server.ts"
```

---

## Conclusões

1. **O sistema é rápido de verdade**: `/db` com 21k RPS e p99 de 15ms é excelente.

2. **A rota `/queries` otimizada (com ANY) atinge 17k RPS**, mas não representa o benchmark padrão TechEmpower (que exige N queries separadas).

3. **A rota `/queries-real` é fiel ao TFB**, mas o resultado (2.4k RPS) está baixo devido ao pool pequeno (16) disputando com 200 conexões HTTP × 20 queries.

4. **Para competir no TFB real**, seria necessário:
   - Aumentar o pool do Bun para ~100-200
   - Tunar mais o PostgreSQL (índices, pgbench)
   - Usar prepared statements
   - Considerar arquitetura multi-processo (Bun.spawn)

---

## Código da Rota /queries-real (Fiel ao TFB)

```typescript
if (path === "/queries-real") {
  const n = Math.min(
    Math.max(parseInt(url.searchParams.get("queries") ?? "1") || 1, 1),
    20
  );
  
  // N queries SEPARADAS em paralelo (Promise.all)
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
```
