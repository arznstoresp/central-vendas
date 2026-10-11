-- ============================================================
-- CENTRAL DE VENDAS · ARZNSTORESP
-- Migração de Segurança — Supabase Auth + RLS
-- Execute no Supabase SQL Editor (Dashboard → SQL Editor → New query)
-- ============================================================
-- IMPORTANTE: Faça backup dos dados antes de executar!
-- Dashboard → Table Editor → contatos → Export CSV
--             Table Editor → progresso_dias → Export CSV
-- ============================================================

-- ------------------------------------------------------------
-- PASSO 1: Criar tabela de perfis/papéis de usuário
-- (user_roles mapeia auth.users.id → role)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_roles (
  user_id  UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role     TEXT NOT NULL CHECK (role IN ('admin','vendedor')),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Índice para buscas rápidas por role
CREATE INDEX IF NOT EXISTS user_roles_role_idx ON public.user_roles(role);

-- ------------------------------------------------------------
-- PASSO 2: Adicionar coluna vendor_id à tabela contatos
-- (owner do contato = auth.users.id de quem criou)
-- Coluna é nullable para não perder contatos existentes.
-- Contatos com vendor_id = NULL ficam visíveis apenas para admin
-- até que o admin os atribua manualmente (ver seção RECUPERAÇÃO).
-- ------------------------------------------------------------
ALTER TABLE public.contatos
  ADD COLUMN IF NOT EXISTS vendor_id UUID REFERENCES auth.users(id);

-- Índice para filtros por vendedor
CREATE INDEX IF NOT EXISTS contatos_vendor_id_idx ON public.contatos(vendor_id);

-- ------------------------------------------------------------
-- PASSO 3: Ativar RLS em todas as tabelas sensíveis
-- ------------------------------------------------------------
ALTER TABLE public.contatos        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.progresso_dias  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.precos_xbz      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles      ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- PASSO 4: Remover TODAS as policies existentes nas 4 tabelas
-- (remove policies antigas pelo nome genérico E qualquer outra
--  que possa ter sido criada anteriormente via dashboard)
-- ------------------------------------------------------------
DO $$
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
END$$;

-- ------------------------------------------------------------
-- PASSO 5: Helper function para checar role do usuário atual
-- SECURITY DEFINER: executa com privilégios do dono da função,
-- não do chamador — necessário para ler user_roles sem expor
-- a tabela diretamente nas policies.
-- SET search_path = public: protege contra search_path injection
-- (impede que um schema malicioso sobreponha public.user_roles).
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

-- ------------------------------------------------------------
-- PASSO 6: Policies — tabela contatos
--
-- Regras:
--   Admin  → acesso total (SELECT, INSERT, UPDATE, DELETE)
--   Vendedor → somente seus próprios contatos (vendor_id = uid())
--              não pode deletar nem reatribuir vendor_id
--   Anônimo → zero acesso (nenhuma policy cobre anon)
-- ------------------------------------------------------------

-- Admin: SELECT — todos os contatos
CREATE POLICY "admin_select_contatos"
  ON public.contatos FOR SELECT
  USING (public.get_my_role() = 'admin');

-- Admin: INSERT — pode inserir qualquer contato
CREATE POLICY "admin_insert_contatos"
  ON public.contatos FOR INSERT
  WITH CHECK (public.get_my_role() = 'admin');

-- Admin: UPDATE — pode atualizar qualquer contato (incluindo vendor_id)
CREATE POLICY "admin_update_contatos"
  ON public.contatos FOR UPDATE
  USING  (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

-- Admin: DELETE
CREATE POLICY "admin_delete_contatos"
  ON public.contatos FOR DELETE
  USING (public.get_my_role() = 'admin');

-- Vendedor: SELECT — apenas contatos onde vendor_id = próprio uid
-- Contatos com vendor_id = NULL não aparecem (apenas admin os vê)
CREATE POLICY "vendedor_select_contatos"
  ON public.contatos FOR SELECT
  USING (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

-- Vendedor: INSERT — obrigatório setar vendor_id = próprio uid
-- Impede inserção sem vendor_id ou com vendor_id de outro usuário
CREATE POLICY "vendedor_insert_contatos"
  ON public.contatos FOR INSERT
  WITH CHECK (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

-- Vendedor: UPDATE — somente seus próprios contatos
-- USING filtra quais linhas podem ser alvo do UPDATE
-- WITH CHECK garante que vendor_id não seja alterado para outro uid
-- (se vendedor tentar mudar vendor_id para NULL ou outro uuid, a
--  condição vendor_id = auth.uid() falha no WITH CHECK e bloqueia)
CREATE POLICY "vendedor_update_contatos"
  ON public.contatos FOR UPDATE
  USING (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  )
  WITH CHECK (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

-- Vendedor: DELETE — não permitido
-- (ausência de policy DELETE para vendedor bloqueia deleção)

-- ------------------------------------------------------------
-- PASSO 7: Policies — tabela progresso_dias
-- O plano de 30 dias é compartilhado entre todos os usuários
-- autenticados. Apenas admin pode apagar registros.
-- ------------------------------------------------------------
CREATE POLICY "authenticated_select_progresso"
  ON public.progresso_dias FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "authenticated_insert_progresso"
  ON public.progresso_dias FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "authenticated_update_progresso"
  ON public.progresso_dias FOR UPDATE
  USING  (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- Apenas admin pode apagar registros do plano de 30 dias
CREATE POLICY "admin_delete_progresso"
  ON public.progresso_dias FOR DELETE
  USING (public.get_my_role() = 'admin');

-- ------------------------------------------------------------
-- PASSO 8: Policies — tabela precos_xbz
-- Qualquer autenticado pode consultar (necessário para propostas
-- e catálogo de produtos). Apenas admin pode modificar.
-- ------------------------------------------------------------
CREATE POLICY "authenticated_select_precos"
  ON public.precos_xbz FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "admin_insert_precos"
  ON public.precos_xbz FOR INSERT
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_update_precos"
  ON public.precos_xbz FOR UPDATE
  USING  (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_delete_precos"
  ON public.precos_xbz FOR DELETE
  USING (public.get_my_role() = 'admin');

-- ------------------------------------------------------------
-- PASSO 9: Policies — tabela user_roles
--
-- Regras:
--   Qualquer autenticado lê a PRÓPRIA linha (para o app checar role)
--   Admin lê todas as linhas (para gerenciar usuários)
--   Somente admin pode inserir, atualizar ou deletar papéis
--   Vendedor NÃO pode se auto-promover a admin
-- ------------------------------------------------------------

-- Usuário lê apenas a própria linha (necessário para _fetchRole no app)
CREATE POLICY "user_read_own_role"
  ON public.user_roles FOR SELECT
  USING (user_id = auth.uid());

-- Admin lê todos os papéis (necessário para gerenciamento)
CREATE POLICY "admin_select_user_roles"
  ON public.user_roles FOR SELECT
  USING (public.get_my_role() = 'admin');

-- Somente admin pode inserir novos papéis
-- Impede que um vendedor insira uma linha com role = 'admin' para si
CREATE POLICY "admin_insert_user_roles"
  ON public.user_roles FOR INSERT
  WITH CHECK (public.get_my_role() = 'admin');

-- Somente admin pode atualizar papéis
-- WITH CHECK explícito garante que o role resultante ainda passa pela
-- checagem de admin (evita ambiguidade do default PostgreSQL)
CREATE POLICY "admin_update_user_roles"
  ON public.user_roles FOR UPDATE
  USING  (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

-- Somente admin pode remover papéis
CREATE POLICY "admin_delete_user_roles"
  ON public.user_roles FOR DELETE
  USING (public.get_my_role() = 'admin');

-- ============================================================
-- PASSO 10: Criar o primeiro usuário Admin
-- Execute no Supabase Dashboard → Authentication → Users → Add user
-- Após criar, copie o UUID gerado e execute:
-- ============================================================
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('<UUID-DO-SEU-USUARIO>', 'admin');
--
-- Exemplo (substitua pelo UUID real):
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('00000000-0000-0000-0000-000000000000', 'admin');

-- ============================================================
-- PASSO 11 (OPCIONAL): RECUPERAÇÃO — Contatos sem vendor_id
-- ============================================================
-- Após a migration, contatos existentes com vendor_id = NULL
-- ficam visíveis APENAS para o admin.
-- Para atribuí-los a um vendedor específico, execute como admin:
--
-- Ver contatos sem dono:
-- SELECT id, empresa, contato, criado_em
-- FROM public.contatos
-- WHERE vendor_id IS NULL
-- ORDER BY criado_em;
--
-- Atribuir TODOS os contatos sem dono a um vendedor:
-- UPDATE public.contatos
-- SET vendor_id = '<UUID-DO-VENDEDOR>'
-- WHERE vendor_id IS NULL;
--
-- Atribuir contatos específicos (por empresa):
-- UPDATE public.contatos
-- SET vendor_id = '<UUID-DO-VENDEDOR>'
-- WHERE vendor_id IS NULL
--   AND empresa ILIKE '%Nome da Empresa%';

-- ============================================================
-- PASSO 12: Verificação final — execute após a migration
-- ============================================================
-- 1. RLS ativo nas 4 tabelas:
SELECT
  tablename,
  rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename;
-- Esperado: rls_enabled = true para todas as 4 tabelas

-- 2. Contagem de policies criadas (deve retornar 18):
SELECT COUNT(*) AS total_policies
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles');

-- 3. Listar todas as policies e suas tabelas:
SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename, cmd;

-- 4. Confirmar que get_my_role() existe com SECURITY DEFINER:
SELECT proname, prosecdef, proconfig
FROM pg_proc
WHERE proname = 'get_my_role'
  AND pronamespace = 'public'::regnamespace;
-- Esperado: prosecdef = true, proconfig inclui 'search_path=public'

-- ============================================================
-- FIM DA MIGRAÇÃO
-- ============================================================
