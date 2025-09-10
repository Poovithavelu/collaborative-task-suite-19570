-- 002_rls.sql
-- Enable RLS and define org-scoped policies across organizations, memberships, projects, tasks.

-- NOTES:
-- This RLS strategy expects two session parameters to be set per connection:
--   - app.current_user_id (uuid): the authenticated user's id
--   - app.current_org_id  (uuid): the active organization context
-- In Supabase, you can map these via JWT claims using current_setting with fallback:
-- current_setting('request.jwt.claims', true)::json->>'sub' etc.
-- For local psql sessions or backend services, set:
--   SELECT set_config('app.current_user_id', '<uuid>', true);
--   SELECT set_config('app.current_org_id',  '<uuid>', true);

-- Helper functions to read session values with safe null handling
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'app') THEN
        CREATE SCHEMA app;
    END IF;
END$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'current_user_id') THEN
        CREATE FUNCTION app.current_user_id() RETURNS uuid
        LANGUAGE plpgsql STABLE AS $f$
        DECLARE
            v uuid;
        BEGIN
            BEGIN
                v := NULLIF(current_setting('app.current_user_id', true), '')::uuid;
            EXCEPTION WHEN others THEN
                v := NULL;
            END;
            RETURN v;
        END
        $f$;
    END IF;
END$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'current_org_id') THEN
        CREATE FUNCTION app.current_org_id() RETURNS uuid
        LANGUAGE plpgsql STABLE AS $f$
        DECLARE
            v uuid;
        BEGIN
            BEGIN
                v := NULLIF(current_setting('app.current_org_id', true), '')::uuid;
            EXCEPTION WHEN others THEN
                v := NULL;
            END;
            RETURN v;
        END
        $f$;
    END IF;
END$$;

-- Organizations: enable RLS
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

-- Only org members can select; only owner/admin can update/delete; insert allowed for any authenticated user creating own org.
DROP POLICY IF EXISTS org_select ON public.organizations;
CREATE POLICY org_select ON public.organizations
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships m
            WHERE m.org_id = organizations.id
              AND m.user_id = app.current_user_id()
        )
    );

DROP POLICY IF EXISTS org_insert ON public.organizations;
CREATE POLICY org_insert ON public.organizations
    FOR INSERT
    WITH CHECK (owner_id = app.current_user_id());

DROP POLICY IF EXISTS org_update ON public.organizations;
CREATE POLICY org_update ON public.organizations
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships m
            WHERE m.org_id = organizations.id
              AND m.user_id = app.current_user_id()
              AND m.role IN ('owner','admin')
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.memberships m
            WHERE m.org_id = organizations.id
              AND m.user_id = app.current_user_id()
              AND m.role IN ('owner','admin')
        )
    );

DROP POLICY IF EXISTS org_delete ON public.organizations;
CREATE POLICY org_delete ON public.organizations
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships m
            WHERE m.org_id = organizations.id
              AND m.user_id = app.current_user_id()
              AND m.role IN ('owner')
        )
    );

-- Memberships: enable RLS
ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

-- Only members of same org can see membership rows
DROP POLICY IF EXISTS memberships_select ON public.memberships;
CREATE POLICY memberships_select ON public.memberships
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = memberships.org_id
              AND me.user_id = app.current_user_id()
        )
    );

-- Insert membership only by owner/admin of that org (e.g., inviting users)
DROP POLICY IF EXISTS memberships_insert ON public.memberships;
CREATE POLICY memberships_insert ON public.memberships
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = memberships.org_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    );

-- Update membership only by owner/admin of same org; members can update their own role? We'll restrict to admin/owner
DROP POLICY IF EXISTS memberships_update ON public.memberships;
CREATE POLICY memberships_update ON public.memberships
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = memberships.org_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = memberships.org_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    );

-- Delete membership only by owner/admin (owner cannot remove self guard is app-level)
DROP POLICY IF EXISTS memberships_delete ON public.memberships;
CREATE POLICY memberships_delete ON public.memberships
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = memberships.org_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    );

-- Projects: enable RLS
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

-- Select projects in current org membership
DROP POLICY IF EXISTS projects_select ON public.projects;
CREATE POLICY projects_select ON public.projects
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = projects.org_id
              AND me.user_id = app.current_user_id()
        )
    );

-- Insert project: member of the org
DROP POLICY IF EXISTS projects_insert ON public.projects;
CREATE POLICY projects_insert ON public.projects
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = projects.org_id
              AND me.user_id = app.current_user_id()
        )
    );

-- Update project: admin or owner in the org
DROP POLICY IF EXISTS projects_update ON public.projects;
CREATE POLICY projects_update ON public.projects
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = projects.org_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = projects.org_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    );

-- Delete project: admin or owner
DROP POLICY IF EXISTS projects_delete ON public.projects;
CREATE POLICY projects_delete ON public.projects
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM public.memberships me
            WHERE me.org_id = projects.org_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    );

-- Tasks: enable RLS
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;

-- Only members of the task's project org can read tasks
DROP POLICY IF EXISTS tasks_select ON public.tasks;
CREATE POLICY tasks_select ON public.tasks
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.projects p
            JOIN public.memberships me ON me.org_id = p.org_id
            WHERE p.id = tasks.project_id
              AND me.user_id = app.current_user_id()
        )
    );

-- Insert tasks allowed for any member in the project's org
DROP POLICY IF EXISTS tasks_insert ON public.tasks;
CREATE POLICY tasks_insert ON public.tasks
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.projects p
            JOIN public.memberships me ON me.org_id = p.org_id
            WHERE p.id = tasks.project_id
              AND me.user_id = app.current_user_id()
        )
    );

-- Update tasks allowed for members; optionally restrict fields via app layer
DROP POLICY IF EXISTS tasks_update ON public.tasks;
CREATE POLICY tasks_update ON public.tasks
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1
            FROM public.projects p
            JOIN public.memberships me ON me.org_id = p.org_id
            WHERE p.id = tasks.project_id
              AND me.user_id = app.current_user_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.projects p
            JOIN public.memberships me ON me.org_id = p.org_id
            WHERE p.id = tasks.project_id
              AND me.user_id = app.current_user_id()
        )
    );

-- Delete tasks allowed for admin/owner in the project's org
DROP POLICY IF EXISTS tasks_delete ON public.tasks;
CREATE POLICY tasks_delete ON public.tasks
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1
            FROM public.projects p
            JOIN public.memberships me ON me.org_id = p.org_id
            WHERE p.id = tasks.project_id
              AND me.user_id = app.current_user_id()
              AND me.role IN ('owner','admin')
        )
    );

-- auth_users: RLS optional - typically unrestricted to service role; here we allow self-access
ALTER TABLE public.auth_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_users_self_select ON public.auth_users;
CREATE POLICY auth_users_self_select ON public.auth_users
    FOR SELECT
    USING (id = app.current_user_id());

DROP POLICY IF EXISTS auth_users_self_update ON public.auth_users;
CREATE POLICY auth_users_self_update ON public.auth_users
    FOR UPDATE
    USING (id = app.current_user_id())
    WITH CHECK (id = app.current_user_id());
