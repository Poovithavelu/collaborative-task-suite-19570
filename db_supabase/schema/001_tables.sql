-- 001_tables.sql
-- CollabTask base schema: users, organizations, memberships, projects, tasks
-- Idempotent DDL using CREATE IF NOT EXISTS and conditional drops for objects

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- AUTH AND USER TABLES

-- Users table (application-level, can be mapped to Supabase auth if used)
CREATE TABLE IF NOT EXISTS public.auth_users (
    id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    email         citext UNIQUE NOT NULL,
    password_hash text NOT NULL,
    display_name  text,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Update trigger to keep updated_at fresh
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'set_updated_at'
    ) THEN
        CREATE FUNCTION public.set_updated_at() RETURNS trigger AS $f$
        BEGIN
            NEW.updated_at = now();
            RETURN NEW;
        END;
        $f$ LANGUAGE plpgsql;
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'tr_auth_users_updated_at'
    ) THEN
        CREATE TRIGGER tr_auth_users_updated_at
        BEFORE UPDATE ON public.auth_users
        FOR EACH ROW EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END
$$;

-- ORGANIZATIONS

CREATE TABLE IF NOT EXISTS public.organizations (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        text NOT NULL,
    owner_id    uuid NOT NULL REFERENCES public.auth_users(id) ON DELETE RESTRICT,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE(owner_id, name)
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'tr_organizations_updated_at'
    ) THEN
        CREATE TRIGGER tr_organizations_updated_at
        BEFORE UPDATE ON public.organizations
        FOR EACH ROW EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END
$$;

-- MEMBERSHIPS

CREATE TYPE public.membership_role AS ENUM ('owner', 'admin', 'member', 'viewer');
-- Guard enum creation if exists (above will error if exists in some PGs). Alternative safe create:
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'membership_role') THEN
        CREATE TYPE public.membership_role AS ENUM ('owner', 'admin', 'member', 'viewer');
    END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.memberships (
    id        uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id   uuid NOT NULL REFERENCES public.auth_users(id) ON DELETE CASCADE,
    org_id    uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    role      public.membership_role NOT NULL DEFAULT 'member',
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, org_id)
);

CREATE INDEX IF NOT EXISTS idx_memberships_user_id ON public.memberships(user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_org_id ON public.memberships(org_id);

-- PROJECTS

CREATE TABLE IF NOT EXISTS public.projects (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    org_id      uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE(org_id, name)
);

CREATE INDEX IF NOT EXISTS idx_projects_org_id ON public.projects(org_id);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'tr_projects_updated_at'
    ) THEN
        CREATE TRIGGER tr_projects_updated_at
        BEFORE UPDATE ON public.projects
        FOR EACH ROW EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END
$$;

-- TASKS

CREATE TYPE public.task_status AS ENUM ('todo', 'in_progress', 'done', 'archived');
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_status') THEN
        CREATE TYPE public.task_status AS ENUM ('todo', 'in_progress', 'done', 'archived');
    END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.tasks (
    id           uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id   uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    title        text NOT NULL,
    description  text,
    status       public.task_status NOT NULL DEFAULT 'todo',
    assignee_id  uuid REFERENCES public.auth_users(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON public.tasks(project_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON public.tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_assignee_id ON public.tasks(assignee_id);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'tr_tasks_updated_at'
    ) THEN
        CREATE TRIGGER tr_tasks_updated_at
        BEFORE UPDATE ON public.tasks
        FOR EACH ROW EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END
$$;

-- Helper function to get a task's org_id via project
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'get_project_org_id'
    ) THEN
        CREATE FUNCTION public.get_project_org_id(p_project_id uuid)
        RETURNS uuid
        LANGUAGE sql
        STABLE
        AS $f$
            SELECT org_id FROM public.projects WHERE id = p_project_id
        $f$;
    END IF;
END
$$;

-- Minimal seed for local dev (optional, guarded)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.auth_users WHERE email = 'owner@example.com') THEN
        INSERT INTO public.auth_users (email, password_hash, display_name)
        VALUES ('owner@example.com', crypt('Password123!', gen_salt('bf')), 'Owner');
    END IF;
END$$;

DO $$
DECLARE
    v_owner uuid;
    v_org uuid;
BEGIN
    SELECT id INTO v_owner FROM public.auth_users WHERE email = 'owner@example.com';
    IF v_owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.organizations WHERE name = 'Default Org') THEN
        INSERT INTO public.organizations (name, owner_id) VALUES ('Default Org', v_owner) RETURNING id INTO v_org;
        INSERT INTO public.memberships (user_id, org_id, role) VALUES (v_owner, v_org, 'owner') ON CONFLICT DO NOTHING;
    END IF;
END$$;
