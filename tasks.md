# Spider Framework — Tarefas de Refatoração Restantes

## Status Atual
- ✅ `src/core/` — criado com `context.zig`, `app.zig`, `pipeline.zig`, `server.zig`
- ✅ `src/routing/` — criado com `router.zig`, `group.zig`
- ✅ `src/internal/` — criado com `logger.zig`, `metrics.zig`, `env.zig`, `buffer_pool.zig`
- ✅ `src/ws/` — criado com `websocket.zig`, `hub.zig`
- ✅ `src/drivers/pg/` — criado com `pg.zig`, `pool.zig`
- ✅ `src/modules/` — criado com `auth/auth.zig`, `static.zig`, `dashboard.zig`
- ✅ `src/spider.zig` — atualizado para re-exportar de todos os novos caminhos

## Tarefas Pendentes

### 1. Mover arquivos para `src/http/`
Mover sem alterar conteúdo:
- `src/web.zig` → `src/http/web.zig`
- Atualizar todos os arquivos que importam `web.zig` para apontar para `http/web.zig`
- Atualizar `spider.zig` para re-exportar `Request`, `Response`, `Method` de `http/web.zig`
- Verificar que `zig build` compila sem erros

### 2. Mover arquivos para `src/binding/`
Mover sem alterar conteúdo:
- `src/form.zig` → `src/binding/form.zig`
- `src/form_parser.zig` → `src/binding/parser.zig`
- Atualizar todos os arquivos que importam esses para apontar para `binding/`
- Verificar que `zig build` compila sem erros

### 3. Mover arquivos para `src/render/`
Mover sem alterar conteúdo:
- `src/template.zig` → `src/render/template.zig`
- `src/zmd/` (pasta inteira) → `src/render/zmd/`
- Atualizar todos os arquivos que importam esses para apontar para `render/`
- Verificar que `zig build` compila sem erros

### 4. Mover arquivos para `src/providers/`
Sem alterar conteúdo:
- `src/providers/google.zig` já está no lugar correto (em `src/providers/`)
- Verificar se há outros providers que precisam ser movidos

### 5. Atualizar imports em `src/modules/auth/auth.zig`
O arquivo `auth.zig` foi movido para `src/modules/auth/auth.zig` mas os imports internos podem precisar de ajustes:
- Verificar se `@import("../../web.zig")` está correto
- Verificar se todos os imports apontam para os novos caminhos

### 6. Limpar arquivos obsoletos
Remover sem alterar funcionalidade:
- `src/_old_spider.zig` — arquivo de backup, não mais necessário
- `src/root.zig` — pode estar redundante com `src/spider.zig`
- `src/test_templates.zig` — já está no `.gitignore`, considerar remoção se não usado
- `src/generate_templates.zig` — verificar se ainda é necessário
- `src/templates_stub.zig` — verificar se ainda é necessário

### 7. Verificar e atualizar `build.zig`
- Verificar se `build.zig` precisa de atualizações para os novos caminhos
- Confirmar que o root source file está correto (`src/spider.zig`)
- Verificar dependências de `src/main.zig`

### 8. Implementar suporte a parâmetros dinâmicos em `src/core/app.zig`
O `Server` em `core/app.zig` atual não suporta rotas com parâmetros (ex: `/users/:id`):
- Integrar com `routing/router.zig` para suporte a parâmetros dinâmicos
- Atualizar `listen()` para usar o `Router` em vez de `StringHashMap`
- Testar com `main.zig` para garantir que `/users/:id` funciona

### 9. Corrigir bugs pendentes do `SPIDER_AUDIT.md`
Prioridade alta (já documentada em `SPIDER_AUDIT.md`):
- JWT sem verificação de expiração em `src/modules/auth/auth.zig`
- Cookie sem flag `Secure` em `src/modules/auth/auth.zig`
- Headers dangling em `src/http/web.zig` (após mover)
- `bindJson` strings dangling em `src/http/web.zig` (após mover)
- Connection pool sem health check em `src/drivers/pg/pg.zig` e `pool.zig`

### 10. Escrever testes unitários
Cobrir casos corrigidos:
- JWT (expiração, formato inválido, payload grande)
- Router (params, wildcard, grupos)
- Pipeline (handleConnection, handlers)
- Auth (middleware, cookie, JWT)

## Notas
- Todas as tarefas devem manter `zig build` compilando sem erros
- Atualizar `spider.zig` para re-exportar conforme necessário
- Manter comentários em inglês no codebase
- Testar com `zig build run` após cada mudança significativa
