-- ============================================================
-- CENTRAL DE VENDAS · ARZNSTORESP
-- Migração de Segurança — Supabase Auth + RLS  v4
-- Execute no Supabase SQL Editor (Dashboard → SQL Editor → New query)
-- ============================================================
--
-- ANTES DE EXECUTAR — BACKUP OBRIGATÓRIO:
--   Dashboard → Table Editor → contatos → Export CSV
--   Dashboard → Table Editor → progresso_dias → Export CSV
--
-- COMO USAR ESTE ARQUIVO:
--   1. Execute a SEÇÃO 0 (leitura, sem alterações) e salve o output.
--   2. Execute o bloco DO $body$ (migration completa — transacional).
--   3. Execute a SEÇÃO VERIFICAÇÃO FINAL e confirme os resultados.
-- ============================================================


-- ============================================================
-- SEÇÃO 0: PRÉ-VOO — leitura do estado atual (sem alterações)
-- Execute e salve o output antes de prosseguir.
-- ============================================================
SELECT
  'POLICIES EXISTENTES — salve este output antes de continuar' AS aviso,
  tablename,
  policyname,
  cmd,
  roles,
  qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename, cmd;

SELECT
  'RLS ATUAL' AS aviso,
  tablename,
  rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename;

SELECT
  'GRANTS ATUAIS EM SCHEMAS' AS aviso,
  grantee, privilege_type
FROM information_schema.role_schema_grants
WHERE table_schema = 'public'
  AND grantee IN ('anon','authenticated','PUBLIC')
ORDER BY grantee;


-- ============================================================
-- MIGRATION PRINCIPAL — bloco transacional
--
-- NOTA TÉCNICA: o delimitador externo é $body$ (não $$) para que
-- a criação da função interna possa usar $$ sem conflito de parser.
--
-- Em caso de qualquer erro, o PostgreSQL reverte tudo
-- automaticamente (nenhuma alteração parcial persiste).
-- ============================================================
DO $body$
DECLARE
  -- variável usada no loop de remoção de policies existentes (Passo 5)
  r RECORD;
BEGIN

-- ------------------------------------------------------------
-- PASSO 1: Permissões no schema public
--
-- Por padrão, o PostgreSQL concede CREATE no schema public a PUBLIC
-- (= todos os roles). Isso permite que qualquer usuário autenticado
-- crie tabelas, funções ou outros objetos. Revogamos para limitar
-- a criação de objetos apenas a superusuários e ao papel postgres
-- do Supabase.
--
-- USAGE é mantido em authenticated para que as queries RLS
-- (policies, funções SECURITY DEFINER) possam resolver objetos no
-- schema public. Sem USAGE, nenhum objeto seria visível.
--
-- Esta alteração não afeta operações das migrations do Supabase,
-- que rodam como postgres/superuser.
-- ------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM anon;
-- authenticated mantém USAGE (necessário para RLS funcionar):
GRANT USAGE ON SCHEMA public TO authenticated;

-- ------------------------------------------------------------
-- PASSO 2: Criar tabela de papéis de usuário
-- user_roles mapeia auth.users.id → role ('admin' ou 'vendedor')
-- ON DELETE CASCADE: se o usuário for removido do Auth,
-- o papel é removido junto, sem deixar linhas órfãs.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_roles (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role       TEXT NOT NULL CHECK (role IN ('admin','vendedor')),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS user_roles_role_idx ON public.user_roles(role);

-- ------------------------------------------------------------
-- PASSO 3: Adicionar vendor_id à tabela contatos
-- Nullable para não quebrar registros existentes.
-- Contatos com vendor_id = NULL ficam visíveis apenas para admin
-- após a migration. Veja a seção RECUPERAÇÃO no final.
-- ------------------------------------------------------------
ALTER TABLE public.contatos
  ADD COLUMN IF NOT EXISTS vendor_id UUID REFERENCES auth.users(id);

CREATE INDEX IF NOT EXISTS contatos_vendor_id_idx ON public.contatos(vendor_id);

-- ------------------------------------------------------------
-- PASSO 4: Ativar RLS nas quatro tabelas sensíveis
-- ------------------------------------------------------------
ALTER TABLE public.contatos        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.progresso_dias  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.precos_xbz      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles      ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- PASSO 5: Revogar acessos diretos das roles anon e authenticated
-- nas quatro tabelas, e depois conceder o mínimo necessário.
--
-- Por que revogar de anon explicitamente?
--   RLS é a principal barreira, mas um GRANT direto a anon
--   (criado pelo Supabase em versões mais antigas ou pelo dashboard)
--   pode permitir acesso a metadados mesmo sem dados, e em caso de
--   bug na policy seria a única linha de defesa. Revogar de anon
--   adiciona uma segunda camada: chamadas diretas à API Supabase
--   com a chave anon nunca chegam às policies destas tabelas.
--
-- Por que conceder a authenticated?
--   RLS exige que a role tenha GRANT para que as policies sejam
--   avaliadas. Sem GRANT, o acesso é negado antes mesmo de chegar
--   às policies. O GRANT dá a "porta de entrada"; as policies
--   definem quem passa por ela.
-- ------------------------------------------------------------

REVOKE ALL ON TABLE public.contatos FROM anon;
REVOKE ALL ON TABLE public.contatos FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.contatos TO authenticated;

REVOKE ALL ON TABLE public.progresso_dias FROM anon;
REVOKE ALL ON TABLE public.progresso_dias FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.progresso_dias TO authenticated;

REVOKE ALL ON TABLE public.precos_xbz FROM anon;
REVOKE ALL ON TABLE public.precos_xbz FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.precos_xbz TO authenticated;

REVOKE ALL ON TABLE public.user_roles FROM anon;
REVOKE ALL ON TABLE public.user_roles FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_roles TO authenticated;

-- ------------------------------------------------------------
-- PASSO 6: Remover TODAS as policies existentes nas 4 tabelas
-- O loop lê as policies atuais e as remove dinamicamente,
-- independente de nome — não deixa nenhuma policy antiga ativa.
-- A variável r foi declarada no DECLARE do bloco externo.
-- ------------------------------------------------------------
FOR r IN
  SELECT policyname, tablename
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
LOOP
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
END LOOP;

-- ------------------------------------------------------------
-- PASSO 7: Função auxiliar get_my_role()
--
-- NOTA: A função é criada com delimitador $$ dentro do bloco DO
-- $body$. Os dois delimitadores são diferentes, portanto o
-- PostgreSQL não confunde o fim da função com o fim do DO.
--
-- SECURITY DEFINER: executa com privilégios do dono da função
--   (postgres/superuser), não do chamador. Necessário para que
--   as policies possam ler user_roles sem expor a tabela
--   diretamente.
--
-- SET search_path = public: previne search_path injection.
--   Sem isso, um usuário com CREATE em algum schema poderia
--   criar um objeto que "shadeia" public, fazendo a função ler
--   uma user_roles falsa e retornar role arbitrário.
--   (O Passo 1 revoga CREATE de PUBLIC, o que já reduz muito
--   este risco; SET search_path é a segunda camada.)
--
-- STABLE: sinaliza ao PostgreSQL que a função não modifica o
--   banco e pode ser otimizada dentro de uma query.
--
-- REVOKE FROM PUBLIC: por padrão, PostgreSQL concede EXECUTE
--   a PUBLIC (todos os roles) em novas funções. Revogamos e
--   concedemos apenas a authenticated. A role anon jamais
--   precisa chamar esta função.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT role FROM public.user_roles WHERE user_id = auth.uid() LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.get_my_role() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated;

-- ------------------------------------------------------------
-- PASSO 8: Policies — tabela contatos (7 policies)
--
-- Modelo de acesso:
--   admin    → SELECT, INSERT, UPDATE, DELETE em qualquer contato
--   vendedor → SELECT, INSERT, UPDATE apenas nos próprios (vendor_id = uid())
--              DELETE bloqueado (ausência de policy DELETE para vendedor)
--   anon     → zero acesso (sem policy + REVOKE de GRANT)
--
-- TO authenticated: aplica a policy apenas à role authenticated,
--   impedindo avaliação para anon mesmo que houvesse um GRANT
--   residual de versões antigas do Supabase.
--
-- Proteção de vendor_id no UPDATE do vendedor:
--   USING:      garante que só rows com vendor_id = uid() podem ser alvo
--   WITH CHECK: garante que vendor_id não pode ser alterado para NULL
--               nem para o uuid de outro usuário na row resultante
-- ------------------------------------------------------------
CREATE POLICY "admin_select_contatos"
  ON public.contatos FOR SELECT
  TO authenticated
  USING (public.get_my_role() = 'admin');

CREATE POLICY "admin_insert_contatos"
  ON public.contatos FOR INSERT
  TO authenticated
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_update_contatos"
  ON public.contatos FOR UPDATE
  TO authenticated
  USING  (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_delete_contatos"
  ON public.contatos FOR DELETE
  TO authenticated
  USING (public.get_my_role() = 'admin');

CREATE POLICY "vendedor_select_contatos"
  ON public.contatos FOR SELECT
  TO authenticated
  USING (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

CREATE POLICY "vendedor_insert_contatos"
  ON public.contatos FOR INSERT
  TO authenticated
  WITH CHECK (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

CREATE POLICY "vendedor_update_contatos"
  ON public.contatos FOR UPDATE
  TO authenticated
  USING (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  )
  WITH CHECK (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

-- ------------------------------------------------------------
-- PASSO 9: Policies — tabela progresso_dias (4 policies)
--
-- DECISÃO DE DESIGN — plano compartilhado ou por vendedor?
--
-- OPÇÃO A (implementada): plano compartilhado
--   Todos os usuários autenticados veem e marcam os mesmos 30 dias.
--   Impacto: vendedores interferem no progresso uns dos outros.
--   Adequado quando há uma equipe pequena com plano único.
--
-- OPÇÃO B (não implementada): plano por vendedor
--   Requer ALTER TABLE progresso_dias ADD COLUMN user_id UUID
--   REFERENCES auth.users(id) + policies por user_id = auth.uid().
--   Cada vendedor teria seu próprio progresso de 30 dias.
--   Requer migration adicional e ajuste no frontend.
--
-- Para migrar para a Opção B, não execute este arquivo antes de
-- decidir — a alteração de schema exige planejamento separado.
-- ------------------------------------------------------------
CREATE POLICY "authenticated_select_progresso"
  ON public.progresso_dias FOR SELECT
  TO authenticated
  USING (auth.role() = 'authenticated');

CREATE POLICY "authenticated_insert_progresso"
  ON public.progresso_dias FOR INSERT
  TO authenticated
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "authenticated_update_progresso"
  ON public.progresso_dias FOR UPDATE
  TO authenticated
  USING  (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- Apenas admin pode apagar registros do plano de 30 dias
CREATE POLICY "admin_delete_progresso"
  ON public.progresso_dias FOR DELETE
  TO authenticated
  USING (public.get_my_role() = 'admin');

-- ------------------------------------------------------------
-- PASSO 10: Policies — tabela precos_xbz (4 policies)
-- Qualquer autenticado lê (catálogo de produtos e propostas).
-- Apenas admin escreve (preços são dados internos sensíveis).
-- ------------------------------------------------------------
CREATE POLICY "authenticated_select_precos"
  ON public.precos_xbz FOR SELECT
  TO authenticated
  USING (auth.role() = 'authenticated');

CREATE POLICY "admin_insert_precos"
  ON public.precos_xbz FOR INSERT
  TO authenticated
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_update_precos"
  ON public.precos_xbz FOR UPDATE
  TO authenticated
  USING  (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_delete_precos"
  ON public.precos_xbz FOR DELETE
  TO authenticated
  USING (public.get_my_role() = 'admin');

-- ------------------------------------------------------------
-- PASSO 11: Policies — tabela user_roles (5 policies)
--
-- Regras:
--   Qualquer autenticado lê a PRÓPRIA linha (app precisa do role)
--   Admin lê TODAS as linhas (gerenciamento de usuários)
--   Somente admin insere, atualiza ou remove papéis
--   Vendedor NÃO pode se autopromover: sem policy de INSERT/UPDATE
--   para vendedor → banco rejeita qualquer tentativa
--
-- WITH CHECK explícito em admin_update_user_roles:
--   Evita depender do comportamento implícito do PostgreSQL
--   (que usaria USING como WITH CHECK quando omitido).
--   A separação explícita facilita auditoria futura.
-- ------------------------------------------------------------
CREATE POLICY "user_read_own_role"
  ON public.user_roles FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "admin_select_user_roles"
  ON public.user_roles FOR SELECT
  TO authenticated
  USING (public.get_my_role() = 'admin');

CREATE POLICY "admin_insert_user_roles"
  ON public.user_roles FOR INSERT
  TO authenticated
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_update_user_roles"
  ON public.user_roles FOR UPDATE
  TO authenticated
  USING  (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_delete_user_roles"
  ON public.user_roles FOR DELETE
  TO authenticated
  USING (public.get_my_role() = 'admin');

END $body$;
-- Fim do bloco transacional — se chegou aqui sem erro, tudo foi aplicado.
-- Se qualquer instrução falhou, nada foi aplicado (rollback automático do DO).
-- Total de policies criadas: 20


-- ============================================================
-- PASSO 12: Criar o primeiro usuário Admin
-- (fora do bloco DO — requer UUID do usuário criado no painel
--  Authentication após a migration)
--
-- 1. Dashboard → Authentication → Users → Add user
-- 2. Copie o UUID gerado e execute abaixo (substitua o UUID):
-- ============================================================
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('<UUID-DO-SEU-USUARIO>', 'admin');


-- ============================================================
-- SEÇÃO RECUPERAÇÃO — Contatos sem vendor_id
-- Execute como admin após a migration, se necessário.
-- ============================================================
-- Contatos criados antes desta migration têm vendor_id = NULL.
-- Eles ficam visíveis apenas para admin, sem perda de dados.
-- Use as queries abaixo para atribuí-los a vendedores.
--
-- Ver todos os contatos sem dono:
-- SELECT id, empresa, contato, criado_em
-- FROM public.contatos WHERE vendor_id IS NULL ORDER BY criado_em;
--
-- Atribuir TODOS a um vendedor específico:
-- UPDATE public.contatos
-- SET vendor_id = '<UUID-DO-VENDEDOR>'
-- WHERE vendor_id IS NULL;
--
-- Atribuir por empresa (filtro parcial):
-- UPDATE public.contatos
-- SET vendor_id = '<UUID-DO-VENDEDOR>'
-- WHERE vendor_id IS NULL AND empresa ILIKE '%Nome%';


-- ============================================================
-- SEÇÃO RECUPERAÇÃO DE EMERGÊNCIA
-- Use apenas se algo der errado após a migration.
-- Este script:
--   - Remove apenas as policies criadas por esta migration
--   - NÃO desabilita RLS (tabelas continuam protegidas)
--   - NÃO reabre acesso anônimo (GRANTs para anon permanecem revogados)
--   - Os dados permanecem intactos
-- Execute apenas se necessário; reavalie antes de reaplicar a migration.
-- ============================================================
-- DO $body$
-- DECLARE r RECORD;
-- BEGIN
--   FOR r IN
--     SELECT policyname, tablename FROM pg_policies
--     WHERE schemaname = 'public'
--       AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
--       AND policyname IN (
--         'admin_select_contatos','admin_insert_contatos','admin_update_contatos',
--         'admin_delete_contatos','vendedor_select_contatos','vendedor_insert_contatos',
--         'vendedor_update_contatos','authenticated_select_progresso',
--         'authenticated_insert_progresso','authenticated_update_progresso',
--         'admin_delete_progresso','authenticated_select_precos','admin_insert_precos',
--         'admin_update_precos','admin_delete_precos','user_read_own_role',
--         'admin_select_user_roles','admin_insert_user_roles','admin_update_user_roles',
--         'admin_delete_user_roles'
--       )
--   LOOP
--     EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
--   END LOOP;
-- END $body$;
-- -- RLS continua ativo. Para reverter GRANTs (não recomendado sem novo plano):
-- -- GRANT ALL ON TABLE public.contatos TO anon;
-- -- GRANT ALL ON TABLE public.progresso_dias TO anon;
-- -- GRANT ALL ON TABLE public.precos_xbz TO anon;
-- -- GRANT ALL ON TABLE public.user_roles TO anon;


-- ============================================================
-- VERIFICAÇÃO FINAL — execute após o bloco DO $body$
-- ============================================================

-- 1. RLS ativo nas 4 tabelas (esperado: rls_enabled = true para todas):
SELECT tablename, rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename;

-- 2. Total de policies criadas (esperado: total_policies = 20):
SELECT COUNT(*) AS total_policies
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles');

-- 3. Lista completa de policies com role e comando:
SELECT tablename, policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename, cmd;

-- 4. Confirmar get_my_role(): SECURITY DEFINER + search_path fixo
-- (esperado: prosecdef = true, proconfig contém 'search_path=public'):
SELECT proname, prosecdef, proconfig
FROM pg_proc
WHERE proname = 'get_my_role'
  AND pronamespace = 'public'::regnamespace;

-- 5. GRANT de anon deve estar vazio nas 4 tabelas
-- (esperado: 0 linhas):
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('contatos','progresso_dias','precos_xbz','user_roles')
  AND grantee = 'anon';

-- 6. EXECUTE em get_my_role() deve ser apenas para authenticated
-- (esperado: apenas 'authenticated' na coluna grantee):
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name = 'get_my_role';

-- 7. CREATE no schema public revogado de PUBLIC e anon
-- (esperado: nenhuma linha com privilege_type = 'CREATE' para anon ou PUBLIC):
SELECT grantee, privilege_type
FROM information_schema.role_schema_grants
WHERE table_schema = 'public'
  AND privilege_type = 'CREATE'
  AND grantee IN ('anon','PUBLIC');

-- ============================================================
-- FIM DA MIGRAÇÃO — v4
-- ============================================================
