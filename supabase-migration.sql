-- ============================================================
-- CENTRAL DE VENDAS · ARZNSTORESP
-- Migração de Segurança — Supabase Auth + RLS  v3
-- Execute no Supabase SQL Editor (Dashboard → SQL Editor → New query)
-- ============================================================
--
-- ANTES DE EXECUTAR — BACKUP OBRIGATÓRIO:
--   Dashboard → Table Editor → contatos → Export CSV
--   Dashboard → Table Editor → progresso_dias → Export CSV
--
-- COMO USAR ESTE ARQUIVO:
--   1. Execute a seção PRÉ-VOO (leitura, sem alterações) e salve o output.
--   2. Execute o bloco BEGIN ... COMMIT (migration completa).
--   3. Execute a seção VERIFICAÇÃO FINAL e confira os resultados.
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


-- ============================================================
-- MIGRATION PRINCIPAL — bloco transacional
-- Em caso de qualquer erro, o PostgreSQL reverte tudo
-- automaticamente (nenhuma alteração parcial persiste).
-- ============================================================
DO $$
BEGIN

-- ------------------------------------------------------------
-- PASSO 1: Criar tabela de papéis de usuário
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
-- PASSO 2: Adicionar vendor_id à tabela contatos
-- Nullable para não quebrar registros existentes.
-- Contatos com vendor_id = NULL ficam visíveis apenas para admin
-- após a migration. Veja a seção RECUPERAÇÃO no final.
-- ------------------------------------------------------------
ALTER TABLE public.contatos
  ADD COLUMN IF NOT EXISTS vendor_id UUID REFERENCES auth.users(id);

CREATE INDEX IF NOT EXISTS contatos_vendor_id_idx ON public.contatos(vendor_id);

-- ------------------------------------------------------------
-- PASSO 3: Ativar RLS nas quatro tabelas sensíveis
-- ------------------------------------------------------------
ALTER TABLE public.contatos        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.progresso_dias  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.precos_xbz      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles      ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- PASSO 4: Revogar acessos diretos das roles anon e authenticated
-- nas quatro tabelas, e depois conceder o mínimo necessário.
--
-- Por que revogar de anon explicitamente?
--   RLS é a principal barreira, mas um GRANT direto a anon (criado
--   pelo Supabase em versões mais antigas ou pelo dashboard) pode
--   permitir leituras de schema mesmo sem dados, e em caso de bug
--   na policy a linha de defesa seria apenas RLS. Revogar de anon
--   adiciona uma segunda camada, garantindo que chamadas diretas
--   à API Supabase com a chave anon nunca acessem estas tabelas.
--
-- Por que conceder a authenticated?
--   RLS exige que a role tenha GRANT para que as policies sejam
--   avaliadas. Sem GRANT, o acesso é negado antes mesmo de
--   chegar às policies. O GRANT dá a "porta de entrada"; as
--   policies definem quem passa por ela.
-- ------------------------------------------------------------

-- Contatos: anon sem acesso; authenticated com acesso completo
-- (as policies RLS restringem o que cada authenticated pode fazer)
REVOKE ALL ON TABLE public.contatos FROM anon;
REVOKE ALL ON TABLE public.contatos FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.contatos TO authenticated;

-- Progresso_dias: anon sem acesso; authenticated com acesso completo
REVOKE ALL ON TABLE public.progresso_dias FROM anon;
REVOKE ALL ON TABLE public.progresso_dias FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.progresso_dias TO authenticated;

-- Precos_xbz: anon sem acesso; authenticated pode ler
-- (as policies RLS bloqueiam escrita para não-admin)
REVOKE ALL ON TABLE public.precos_xbz FROM anon;
REVOKE ALL ON TABLE public.precos_xbz FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.precos_xbz TO authenticated;

-- User_roles: anon sem acesso; authenticated pode ler a própria linha
-- (as policies RLS bloqueiam leitura de outras linhas e toda escrita)
REVOKE ALL ON TABLE public.user_roles FROM anon;
REVOKE ALL ON TABLE public.user_roles FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_roles TO authenticated;

-- ------------------------------------------------------------
-- PASSO 5: Remover TODAS as policies existentes nas 4 tabelas
-- O loop lê as policies atuais e as remove dinamicamente,
-- independente de nome — não deixa nenhuma policy antiga ativa.
-- ------------------------------------------------------------
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END;

-- ------------------------------------------------------------
-- PASSO 6: Função auxiliar get_my_role()
--
-- SECURITY DEFINER: executa com privilégios do dono da função
--   (postgres/superuser), não do chamador. Necessário para que
--   as policies possam ler user_roles sem expor a tabela
--   diretamente a todo usuário autenticado.
--
-- SET search_path = public: previne search_path injection.
--   Sem isso, um usuário com CREATE em algum schema poderia
--   criar um schema com nome que "shadeia" public, fazendo a
--   função ler uma user_roles falsa e retornar role arbitrário.
--
-- STABLE: sinaliza ao PostgreSQL que a função não modifica o
--   banco e pode ser otimizada (chamada uma vez por query).
--
-- Permissões EXECUTE:
--   Revogamos de PUBLIC (padrão PostgreSQL concede a todos) e
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
-- PASSO 7: Policies — tabela contatos (7 policies)
--
-- Modelo de acesso:
--   admin    → SELECT, INSERT, UPDATE, DELETE em qualquer contato
--   vendedor → SELECT, INSERT, UPDATE apenas nos próprios (vendor_id = uid())
--              DELETE bloqueado (ausência de policy DELETE para vendedor)
--   anon     → zero acesso (sem policy + REVOKE de GRANT)
--
-- TO authenticated: aplica a policy apenas à role authenticated,
--   impedindo avaliação para anon mesmo que houvesse um GRANT.
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
-- PASSO 8: Policies — tabela progresso_dias (4 policies)
--
-- DECISÃO DE DESIGN — plano compartilhado ou por vendedor?
--
-- OPÇÃO A (implementada): plano compartilhado
--   Todos os usuários autenticados veem e marcam os mesmos 30 dias.
--   Impacto: vendedores interferem no progresso uns dos outros.
--   Adequado quando há uma equipe pequena com plano único.
--
-- OPÇÃO B (não implementada): plano por vendedor
--   Requer ALTER TABLE progresso_dias ADD COLUMN user_id UUID REFERENCES auth.users(id).
--   Políticas filtrariam por user_id = auth.uid() (igual a contatos).
--   Impacto: cada vendedor tem seu próprio progresso de 30 dias.
--   Requer migração adicional de schema e ajuste no frontend.
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
-- PASSO 9: Policies — tabela precos_xbz (4 policies)
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
-- PASSO 10: Policies — tabela user_roles (5 policies)
--
-- Regras:
--   Qualquer autenticado lê a PRÓPRIA linha (app precisa do role)
--   Admin lê TODAS as linhas (gerenciamento de usuários)
--   Somente admin insere, atualiza ou remove papéis
--   Vendedor NÃO pode se autopromover: sem policy de INSERT/UPDATE
--   para vendedor → banco rejeita qualquer tentativa
--
-- WITH CHECK em admin_update_user_roles:
--   Explícito para evitar o comportamento implícito do PostgreSQL
--   (que usaria USING como WITH CHECK quando omitido). A separação
--   explícita facilita auditoria futura.
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

END $$;
-- Fim do bloco transacional — se chegou aqui sem erro, tudo foi aplicado.
-- Se qualquer instrução falhou, nada foi aplicado (rollback automático).


-- ============================================================
-- PASSO 11: Criar o primeiro usuário Admin
-- (fora do bloco transacional — requer UUID do usuário criado
--  no painel Authentication)
--
-- 1. Dashboard → Authentication → Users → Add user
-- 2. Copie o UUID gerado e execute abaixo (substitua o UUID):
-- ============================================================
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('<UUID-DO-SEU-USUARIO>', 'admin');


-- ============================================================
-- SEÇÃO RECUPERAÇÃO — Contatos sem vendor_id (execute como admin)
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
-- SEÇÃO RECUPERAÇÃO DE EMERGÊNCIA — use apenas se algo der errado
-- Não desabilita RLS; apenas remove as policies desta migration.
-- Os dados permanecem intactos. Execute apenas se necessário.
-- ============================================================
-- DO $$
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
-- END $$;
-- REVOKE ALL ON TABLE public.contatos FROM authenticated;
-- REVOKE ALL ON TABLE public.progresso_dias FROM authenticated;
-- REVOKE ALL ON TABLE public.precos_xbz FROM authenticated;
-- REVOKE ALL ON TABLE public.user_roles FROM authenticated;
-- -- Após rollback, reative o acesso conforme configuração anterior
-- -- e reavalie com sua equipe antes de reaplicar a migration.


-- ============================================================
-- VERIFICAÇÃO FINAL — execute após o bloco BEGIN...COMMIT
-- ============================================================

-- 1. RLS ativo nas 4 tabelas (esperado: true para todas):
SELECT tablename, rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename;

-- 2. Total de policies criadas (esperado: 20):
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
-- (esperado: 0 linhas para cada tabela):
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('contatos','progresso_dias','precos_xbz','user_roles')
  AND grantee = 'anon';

-- 6. EXECUTE em get_my_role() deve ser apenas para authenticated
-- (esperado: apenas 'authenticated' na lista de grantees):
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name = 'get_my_role';

-- ============================================================
-- FIM DA MIGRAÇÃO — v3
-- ============================================================
