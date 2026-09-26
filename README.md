# Finch API

API Rails responsável por autenticação, cartões, categorias, transações, faturas, pagamentos, dashboard e classificação automática do Finch.

## Requisitos

- Ruby 3.2.6
- Bundler 2.4.19
- PostgreSQL

O `.ruby-version`, o `Gemfile` e o `Gemfile.lock` são a fonte canônica da
toolchain Ruby. Não execute Bundler com o Ruby global antes de ativar a versão
do projeto.

## Precheck da toolchain

No ambiente local atual, RVM fornece as versões instaladas. Antes de qualquer
comando Rails ou RSpec, entre no repositório e execute:

```bash
source /home/joaov/.rvm/scripts/rvm
rvm use 3.2.6
ruby -v
bundle -v
bundle exec ruby -v
```

O resultado esperado é Ruby `3.2.6` e Bundler `2.4.19`. Se o shell reportar
Ruby 3.3.5, pare e ative 3.2.6; não altere o `Gemfile` para acomodar o runtime
global.

## Configuração local

Copie `.env.example` para `.env` e configure os dois shards writers e um banco descartável de teste:

```env
DATABASE_URL_DEVEL=postgresql://USER:PASSWORD@HOST:PORT/finch_development
DATABASE_URL=postgresql://USER:PASSWORD@HOST:PORT/finch_production
DATABASE_URL_TEST=postgresql://USER:PASSWORD@HOST:PORT/finch_test
```

`DATABASE_URL_DEVEL` representa o banco local com dados fictícios. `DATABASE_URL` representa o Supabase com dados reais. Em um processo Rails executado como `production`, configure também `DATABASE_URL_LOCAL` se o switch para um PostgreSQL local estiver disponível nessa topologia.

O ambiente de dados fica na sessão e começa sempre em `local`. Os pools `local` e `supabase` são criados no boot, mas a aplicação nunca altera variáveis de ambiente ou restabelece conexões durante uma request.

## Sessão e implantação web

O navegador acessa a API somente pelo proxy same-origin do Finch Web. Antes de
qualquer `POST`, `PATCH`, `PUT` ou `DELETE`, o cliente chama `GET /api/csrf` e envia
o campo `csrf_token` recebido no header `X-CSRF-Token`. A resposta de token usa
`Cache-Control: no-store`; o proxy não deve armazená-la. Um token ausente ou
inválido retorna JSON com HTTP 403. O cliente busca um token novo após login,
pois o Devise limpa o token de CSRF durante a autenticação. O proxy deve
encaminhar cookies e `Set-Cookie` sem expor a API como origem pública.

Em production, o cookie de sessão é `Secure`, `HttpOnly` (padrão Rails) e
`SameSite=Lax`; o segredo de assinatura deve vir de `SECRET_KEY_BASE` ou de
credenciais Rails protegidas, nunca do repositório. Não compartilhe o segredo
entre ambientes. O registro público em `/api/register` é recusado em
production; usuários devem ser provisionados por um processo administrativo
controlado. Desativar um usuário revoga sua sessão na próxima request à API.

TLS público deve terminar no proxy de entrada. `force_ssl` no Rails permanece
desabilitado até que a configuração de `X-Forwarded-Proto` e a confiança no
proxy sejam verificadas no deploy; habilitá-lo antes dessa verificação pode
gerar redirecionamentos em loop. O proxy/edge também deve limitar tentativas
de login e acesso a endpoints sensíveis. Não há rate limiter no processo Rails.

Após autenticação, `GET /api/data_environment` retorna apenas o ambiente, disponibilidade da conexão, compatibilidade do schema e permissão de troca. `POST /api/data_environment/switch` recebe `{ "environment": "local" | "supabase" }` e exige o header interno `X-Finch-Data-Environment-Switch: confirmed`. Uma troca válida encerra a autenticação, reinicia a sessão, grava o destino e exige novo login; falhas preservam o ambiente e o login atuais.

`DATABASE_URL_TEST` é obrigatória para qualquer boot com `RAILS_ENV=test` e precisa apontar para um banco exclusivo cujo nome contenha `test` como segmento, por exemplo `finch_test` ou `test_finch`. Se `DATABASE_URL_TEST_SUPABASE` for informada, ela passa pelo mesmo guard antes de qualquer conexão.

O boot de teste é interrompido antes de migrations ou limpeza quando:

- `DATABASE_URL_TEST` está ausente;
- o nome do banco não identifica claramente um banco de teste;
- uma URL de teste aponta para o mesmo host, porta e banco de `DATABASE_URL`, `DATABASE_URL_DEVEL`, `DATABASE_URL_DEVELOPMENT`, `DATABASE_URL_LOCAL` ou `DATABASE_URL_PRODUCTION`.

Credenciais e parâmetros de query diferentes não tornam o mesmo banco seguro para testes.

## Instalação

```bash
bin/setup
```

O script prepara apenas o ambiente de desenvolvimento. A criação/preparação do banco de teste deve ser feita explicitamente depois de conferir `DATABASE_URL_TEST`.

## Testes

Confira primeiro se a URL de teste aponta para um banco descartável e execute:

```bash
RAILS_ENV=test bin/rails db:prepare
DISABLE_SPRING=1 bundle exec rspec
```

O guard de segurança pode ser testado isoladamente, sem carregar Rails ou conectar ao PostgreSQL:

```bash
bundle exec rspec spec/lib/test_database_safety_spec.rb
```

## Desenvolvimento

O ambiente development começa no shard local (`DATABASE_URL_DEVEL`), mantendo o Supabase (`DATABASE_URL`) disponível para troca autorizada pela interface:

```bash
bin/dev
```

Nunca reutilize uma URL de desenvolvimento ou produção em `DATABASE_URL_TEST`.

## Migrations por shard

Migrations nunca são executadas durante a troca de ambiente. Verifique e aplique cada destino explicitamente:

```bash
bin/rails db:migrate:status:local
bin/rails db:migrate:local
bin/rails db:migrate:status:supabase
bin/rails db:migrate:supabase
```

Confirme sempre o destino antes de migrar o Supabase. A API bloqueia o switch quando o conjunto de versões em `schema_migrations` não corresponde exatamente às migrations disponíveis no código; uma versão extra no banco, sem migration correspondente no repositório, também é incompatível e bloqueia a troca.

Os dumps automáticos após migrations são desabilitados para todos os shards: `db/migrate` é a fonte de evolução do schema e não é mantido um `supabase_schema.rb` redundante. O `db/schema.rb` existente é apenas um snapshot local; se ele precisar ser atualizado, faça isso deliberadamente com `bin/rails db:schema:dump:local`.

### Migration de revogação de sessão

`20260926120000_add_user_session_version` adiciona `users.session_version`
(`bigint`, default `0`, não nulo) e um trigger que incrementa a versão em toda
transição `active: true → false`, inclusive por SQL administrativo. Não há
backfill de dados financeiros. O primeiro deploy do código invalida as sessões
existentes, que ainda não possuem a versão vinculada no cookie.
O Devise não registra a estratégia `rememberable`; cookies legados de
"lembrar-me" não podem recriar autenticação. A coluna histórica
`remember_created_at` permanece sem uso e não exige mudança de schema.

Esta migration deve ser aplicada separadamente em cada shard antes de subir o
código que consulta `session_version`. Em janela controlada, com backup e
destino conferidos fora dos logs, confirme que não há outras migrations
pendentes e execute explicitamente:

```bash
RAILS_ENV=production bin/rails db:migrate:status:local
RAILS_ENV=production bin/rails db:migrate:up:local VERSION=20260926120000
RAILS_ENV=production bin/rails db:migrate:status:local

RAILS_ENV=production bin/rails db:migrate:status:supabase
RAILS_ENV=production bin/rails db:migrate:up:supabase VERSION=20260926120000
RAILS_ENV=production bin/rails db:migrate:status:supabase
```

Se o segundo shard falhar, mantenha o código antigo enquanto resolve a
incompatibilidade; não suba o novo código até ambos estarem migrados. O rollback
seguro exige invalidar todos os cookies de sessão (por rotação controlada do
segredo de sessão), voltar ao código anterior e só então, se necessário,
executar `db:migrate:down:local` e `db:migrate:down:supabase` com a mesma
`VERSION`, um destino por vez. O `down` remove os dados de versão; não restaure
cookies antigos depois dele.
