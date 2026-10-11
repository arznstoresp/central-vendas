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
-- PASSO 4: Remover policies antigas (se existirem)
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "allow_all_contatos"      ON public.contatos;
DROP POLICY IF EXISTS "allow_all_progresso"     ON public.progresso_dias;
DROP POLICY IF EXISTS "allow_all_precos"        ON public.precos_xbz;
DROP POLICY IF EXISTS "allow_all_user_roles"    ON public.user_roles;

-- Remover qualquer policy permissiva existente
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
-- (evita subconsulta repetida nas policies)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT role FROM public.user_roles WHERE user_id = auth.uid() LIMIT 1;
$$;

-- ------------------------------------------------------------
-- PASSO 6: Policies — tabela contatos
-- Admin: acesso total
-- Vendedor: só vê/edita seus próprios contatos (vendor_id = uid())
-- Anônimo: sem acesso
-- ------------------------------------------------------------

-- Admin: SELECT
CREATE POLICY "admin_select_contatos"
  ON public.contatos FOR SELECT
  USING (public.get_my_role() = 'admin');

-- Admin: INSERT
CREATE POLICY "admin_insert_contatos"
  ON public.contatos FOR INSERT
  WITH CHECK (public.get_my_role() = 'admin');

-- Admin: UPDATE
CREATE POLICY "admin_update_contatos"
  ON public.contatos FOR UPDATE
  USING (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

-- Admin: DELETE
CREATE POLICY "admin_delete_contatos"
  ON public.contatos FOR DELETE
  USING (public.get_my_role() = 'admin');

-- Vendedor: SELECT — só seus próprios contatos
CREATE POLICY "vendedor_select_contatos"
  ON public.contatos FOR SELECT
  USING (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

-- Vendedor: INSERT — deve setar vendor_id como próprio uid
CREATE POLICY "vendedor_insert_contatos"
  ON public.contatos FOR INSERT
  WITH CHECK (
    public.get_my_role() = 'vendedor'
    AND vendor_id = auth.uid()
  );

-- Vendedor: UPDATE — só seus próprios contatos
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

-- Vendedor: DELETE — NÃO PERMITIDO (bloqueado por ausência de policy DELETE)

-- ------------------------------------------------------------
-- PASSO 7: Policies — tabela progresso_dias
-- Qualquer usuário autenticado pode ler e atualizar
-- (o plano de 30 dias é compartilhado)
-- ------------------------------------------------------------
CREATE POLICY "authenticated_select_progresso"
  ON public.progresso_dias FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "authenticated_insert_progresso"
  ON public.progresso_dias FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "authenticated_update_progresso"
  ON public.progresso_dias FOR UPDATE
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- Apenas admin pode apagar registros do plano
CREATE POLICY "admin_delete_progresso"
  ON public.progresso_dias FOR DELETE
  USING (public.get_my_role() = 'admin');

-- ------------------------------------------------------------
-- PASSO 8: Policies — tabela precos_xbz
-- Qualquer autenticado pode consultar preços (necessário para catálogo)
-- Apenas admin pode modificar
-- ------------------------------------------------------------
CREATE POLICY "authenticated_select_precos"
  ON public.precos_xbz FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "admin_insert_precos"
  ON public.precos_xbz FOR INSERT
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_update_precos"
  ON public.precos_xbz FOR UPDATE
  USING (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_delete_precos"
  ON public.precos_xbz FOR DELETE
  USING (public.get_my_role() = 'admin');

-- ------------------------------------------------------------
-- PASSO 9: Policies — tabela user_roles
-- Usuários podem ler o próprio papel (para o app verificar role)
-- Apenas admin pode gerenciar papéis
-- ------------------------------------------------------------

-- Qualquer autenticado lê a própria row (para _fetchRole funcionar)
CREATE POLICY "user_read_own_role"
  ON public.user_roles FOR SELECT
  USING (user_id = auth.uid());

-- Admin lê todos os papéis
CREATE POLICY "admin_select_user_roles"
  ON public.user_roles FOR SELECT
  USING (public.get_my_role() = 'admin');

-- Admin gerencia papéis
CREATE POLICY "admin_insert_user_roles"
  ON public.user_roles FOR INSERT
  WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "admin_update_user_roles"
  ON public.user_roles FOR UPDATE
  USING (public.get_my_role() = 'admin');

CREATE POLICY "admin_delete_user_roles"
  ON public.user_roles FOR DELETE
  USING (public.get_my_role() = 'admin');

-- ============================================================
-- PASSO 10: Criar o primeiro usuário Admin
-- (Execute no Supabase Dashboard → Authentication → Users → Add user)
-- Após criar o usuário, copie o UUID e execute:
-- ============================================================
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('<UUID-DO-SEU-USUARIO>', 'admin');

-- Exemplo com UUID fictício (substitua pelo real):
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('00000000-0000-0000-0000-000000000000', 'admin');

-- ============================================================
-- PASSO 11: Verificação — confirme que RLS está ativo
-- ============================================================
SELECT
  tablename,
  rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('contatos','progresso_dias','precos_xbz','user_roles')
ORDER BY tablename;

-- Deve retornar rls_enabled = true para todas as 4 tabelas
-- ============================================================
-- FIM DA MIGRAÇÃO
-- ============================================================
