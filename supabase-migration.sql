-- ============================================================
-- CENTRAL DE VENDAS · ARZNSTORESP
-- Migração de Segurança — Supabase Auth + RLS  v5
-- Execute no Supabase SQL Editor (Dashboard → SQL Editor → New query)
-- ============================================================
--
-- ANTES DE EXECUTAR — BACKUP OBRIGATÓRIO:
--   Dashboard → Table Editor → contatos → Export CSV
--   Dashboard → Table Editor → progresso_dias → Export CSV
--
-- COMO USAR ESTE ARQUIVO:
--   1. Execute a SEÇÃO 0 (leitura, sem alterações) e salve o output.
--   2. Execute do BEGIN; até o COMMIT; (migration completa — transacional).
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
  'GRANTS ATUAIS NAS TABELAS' AS aviso,
  grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY grantee, table_name;

SELECT
  'CREATE NO SCHEMA PUBLIC (pré-migration)' AS aviso,
  has_schema_privilege('anon',          'public', 'CREATE') AS anon_pode_criar,
  has_schema_privilege('authenticated', 'public', 'CREATE') AS auth_pode_criar;


-- ============================================================
-- MIGRATION PRINCIPAL
--
-- Toda a migration está dentro de BEGIN; ... COMMIT; para que
-- qualquer erro reverta automaticamente, sem deixar o banco
-- parcialmente configurado.
--
-- O bloco DO $body$ é usado apenas no Passo 6, único trecho
-- que exige PL/pgSQL (loop dinâmico para remover policies).
-- Todo o restante é SQL puro.
-- ============================================================
BEGIN;

-- ------------------------------------------------------------
-- PASSO 1: Permissões no schema public
--
-- Por padrão, o PostgreSQL concede CREATE no schema public a
-- PUBLIC (= todos os roles). Isso permite que qualquer usuário
-- autenticado crie tabelas ou funções. Revogamos para limitar
-- a criação de objetos apenas a superusuários (postgres).
--
-- USAGE é mantido em authenticated: sem ele, nenhum objeto
-- do schema public seria visível para políticas RLS ou
-- funções SECURITY DEFINER.
--
-- As migrations do Supabase rodam como postgres/superuser e
-- não são afetadas por esta alteração.
-- ------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM anon;
GRANT USAGE ON SCHEMA public TO authenticated;

-- ------------------------------------------------------------
-- PASSO 2: Criar tabela de papéis de usuário
-- user_roles mapeia auth.users.id → role ('admin' | 'vendedor')
-- ON DELETE CASCADE: a remoção do usuário no Auth apaga o papel
-- automaticamente, sem deixar linhas órfãs.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_roles (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role       TEXT NOT NULL CHECK (role IN ('admin','vendedor')),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS user_roles_role_idx ON public.user_roles(role);

-- ------------------------------------------------------------
-- PASSO 3: Adicionar vendor_id à tabela contatos
-- Nullable: não quebra registros existentes.
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
-- PASSO 5: Revogar acessos das roles anon e authenticated nas
-- quatro tabelas e conceder o mínimo necessário.
--
-- Por que revogar de anon?
--   Versões antigas do Supabase e certas configurações do
--   dashboard podem conceder GRANT direto a anon. Com RLS ativo
--   e GRANT revogado, chamadas à API com a chave anon são
--   bloqueadas em duas camadas independentes.
--
-- Por que conceder a authenticated?
--   RLS exige GRANT na role para que as policies sejam
--   avaliadas. Sem GRANT, o banco nega o acesso antes mesmo
--   de consultar as policies.
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
-- DO $body$ é usado apenas aqui, para o loop dinâmico em
-- PL/pgSQL. O bloco roda dentro da transação aberta no BEGIN.
-- ------------------------------------------------------------
DO $body$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
                   r.policyname, r.tablename);
  END LOOP;
END $body$;

-- ------------------------------------------------------------
-- PASSO 7: Função auxiliar get_my_role()
--
-- CREATE OR REPLACE FUNCTION é SQL puro — não precisa de DO.
--
-- SECURITY DEFINER: executa com privilégios do dono da função
--   (postgres/supabase_admin). Necessário para que as policies
--   possam ler user_roles sem expor a tabela ao chamador.
--
-- SET search_path = public: previne search_path injection.
--   Sem isso, um usuário com CREATE em algum schema poderia
--   criar um objeto que "shadeia" public e fazer a função
--   retornar um role falso. O Passo 1 já revoga CREATE de
--   PUBLIC; este SET é a segunda camada de defesa.
--
-- STABLE: informa ao PostgreSQL que a função não modifica o
--   banco; permite otimização (chamada uma vez por query).
--
-- REVOKE EXECUTE FROM PUBLIC: por padrão, o PostgreSQL concede
--   EXECUTE a PUBLIC em novas funções. Revogamos e concedemos
--   apenas a authenticated. A role anon nunca deve chamar
--   esta função.
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
--   vendedor → SELECT, INSERT, UPDATE apenas nos próprios
--              (vendor_id = auth.uid()); DELETE bloqueado
--   anon     → zero acesso (REVOKE + ausência de policy)
--
-- TO authenticated: avalia a policy apenas para authenticated,
--   bloqueando anon mesmo que algum GRANT residual exista.
--
-- Proteção de vendor_id no UPDATE do vendedor:
--   USING      → apenas rows com vendor_id = uid() podem ser alvo
--   WITH CHECK → vendor_id não pode virar NULL nem uuid de outro
--                usuário após o UPDATE
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
-- OPÇÃO A (implementada): plano compartilhado
--   Todos os autenticados veem e marcam os mesmos 30 dias.
--   Impacto: vendedores interferem no progresso uns dos outros.
--   Adequado para equipe pequena com plano único.
--
-- OPÇÃO B (não implementada): plano por vendedor
--   Requer: ALTER TABLE progresso_dias ADD COLUMN user_id UUID
--     REFERENCES auth.users(id);
--   Policies filtrariam por user_id = auth.uid().
--   Cada vendedor teria seu próprio progresso de 30 dias.
--   Necessita migration separada e ajuste no frontend.
--   Não execute esta migration antes de decidir entre A e B.
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
-- Qualquer autenticado lê a PRÓPRIA linha (app precisa do role)
-- Admin lê TODAS as linhas (gerenciamento de usuários)
-- Apenas admin insere, atualiza ou remove papéis
-- Vendedor não pode se autopromover: sem policy INSERT/UPDATE
--   → banco rejeita qualquer tentativa
-- WITH CHECK explícito evita dependência no comportamento
--   implícito do PostgreSQL (que usaria USING quando omitido).
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

COMMIT;
-- Fim da migration.
-- Se chegou aqui sem erro: todas as 20 alterações foram aplicadas.
-- Se qualquer instrução falhou antes do COMMIT: o banco reverteu
-- automaticamente (nenhuma alteração parcial persiste).
-- Total de policies criadas: 20


-- ============================================================
-- PASSO 12: Criar o primeiro usuário Admin
-- (fora do BEGIN/COMMIT — requer UUID do usuário criado no
--  painel Authentication após a migration)
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
--
-- Este script:
--   - Remove apenas as 20 policies criadas por esta migration
--   - NÃO desabilita RLS (tabelas permanecem protegidas)
--   - NÃO reconecta acesso anônimo
--   - Os dados permanecem intactos
--
-- Após executar, nenhum usuário consegue acessar as tabelas
-- via policies. Reavalie antes de reaplicar a migration.
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
--     EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
--                    r.policyname, r.tablename);
--   END LOOP;
-- END $body$;


-- ============================================================
-- VERIFICAÇÃO FINAL — execute após o COMMIT
-- ============================================================

-- 1. RLS ativo nas 4 tabelas (esperado: rls_enabled = true para todas):
SELECT tablename, rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename;

-- 2. Total de policies (esperado: 20):
SELECT COUNT(*) AS total_policies
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles');

-- 3. Lista completa de policies com role e comando:
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename, cmd;

-- 4. get_my_role(): SECURITY DEFINER + search_path fixo
-- (esperado: prosecdef = true, proconfig = {search_path=public}):
SELECT proname, prosecdef, proconfig
FROM pg_proc
WHERE proname = 'get_my_role'
  AND pronamespace = 'public'::regnamespace;

-- 5. GRANT de anon deve estar vazio (esperado: 0 linhas):
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('contatos','progresso_dias','precos_xbz','user_roles')
  AND grantee = 'anon';

-- 6. EXECUTE em get_my_role() somente para authenticated
-- (esperado: apenas 'authenticated'; o role dono da função,
--  postgres ou supabase_admin, também aparece — isso é esperado):
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name = 'get_my_role';

-- 7. CREATE no schema public revogado
-- (esperado: anon_pode_criar = false, auth_pode_criar = false,
--  auth_tem_usage = true):
SELECT
  has_schema_privilege('anon',          'public', 'CREATE') AS anon_pode_criar,
  has_schema_privilege('authenticated', 'public', 'CREATE') AS auth_pode_criar,
  has_schema_privilege('authenticated', 'public', 'USAGE')  AS auth_tem_usage;

-- ============================================================
-- FIM DA MIGRAÇÃO — v5
-- ============================================================
