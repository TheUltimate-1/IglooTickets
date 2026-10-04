-- =========================================================================
-- IglooTickets - Supabase Database Schema (v3.0, secured)
-- Server-side authentication (Supabase Auth) + Row Level Security.
-- Safe to run on a fresh project OR on top of the v2.x schema (it migrates).
-- Instructions: paste this whole script into the Supabase SQL Editor and RUN.
--
-- BEFORE FIRST LOGIN (one time):
--   1. Supabase Dashboard > Authentication > Providers: keep "Email" enabled and
--      enable "Allow anonymous sign-ins" (used by gate scanners with Event Code + PIN).
--   2. Supabase Dashboard > Authentication > Users > "Add user": create the Master
--      Admin with a STRONG password (tick "Auto Confirm User").
--   3. Run the bootstrap statement at the very bottom of this file with that email.
--   4. Deploy the `staff-admin` Edge Function (see supabase/functions/staff-admin).
-- =========================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Events ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL,
    date TEXT NOT NULL,
    location TEXT NOT NULL,
    gate_pin TEXT NOT NULL DEFAULT '1234',
    tiers JSONB NOT NULL DEFAULT '["VIP General Access", "Standard Pass", "Speaker / Backstage", "Press / Media"]'::jsonb,
    stations JSONB NOT NULL DEFAULT '["Gate 1 (Main Entrance)", "Gate 2 (VIP / Media)", "North Turnstile", "South Turnstile"]'::jsonb,
    capacity INT NOT NULL DEFAULT 500,
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    created_by UUID DEFAULT auth.uid(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS capacity INT NOT NULL DEFAULT 500;
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS stations JSONB NOT NULL DEFAULT '["Gate 1 (Main Entrance)", "Gate 2 (VIP / Media)", "North Turnstile", "South Turnstile"]'::jsonb;
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS created_by UUID DEFAULT auth.uid();
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS signing_secret TEXT DEFAULT uuid_generate_v4()::text;
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS gate_restrictions JSONB DEFAULT '{}'::jsonb;
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS logo_url TEXT DEFAULT NULL;
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS brand_color TEXT DEFAULT '#0284c7';

-- 2. Staff profiles (identity + password live in auth.users, never here) ----
CREATE TABLE IF NOT EXISTS public.app_users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    username TEXT UNIQUE NOT NULL,
    email TEXT,
    role TEXT NOT NULL CHECK (role IN ('MASTER_ADMIN', 'EVENT_ADMIN', 'TICKETING_AGENT', 'TICKET_SCANNER')),
    assigned_event_ids JSONB DEFAULT '[]'::jsonb,
    full_name TEXT,
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Migration: ensure password_hash column is dropped (passwords live securely in auth.users)
ALTER TABLE public.app_users DROP COLUMN IF EXISTS password_hash;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.app_users'::regclass AND conname = 'app_users_id_auth_fkey'
    ) THEN
        -- Add foreign key without deleting any existing user records
        ALTER TABLE public.app_users
            ADD CONSTRAINT app_users_id_auth_fkey
            FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE NOT VALID;
    END IF;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- 3. Tickets ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tickets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    token TEXT UNIQUE NOT NULL,
    attendee_name TEXT NOT NULL,
    attendee_email TEXT,
    tier TEXT NOT NULL DEFAULT 'Standard Pass',
    status TEXT NOT NULL DEFAULT 'VALID',
    issued_at TIMESTAMPTZ DEFAULT NOW(),
    issued_by TEXT DEFAULT 'System',
    scanned_at TIMESTAMPTZ,
    scanned_by TEXT,
    scanned_gate TEXT,
    passed_out_at TIMESTAMPTZ,
    pass_out_gate TEXT,
    re_entry_count INT DEFAULT 0,
    notes TEXT
);
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS passed_out_at TIMESTAMPTZ;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS pass_out_gate TEXT;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS re_entry_count INT DEFAULT 0;

DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN (
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'public.tickets'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%status%'
    ) LOOP
        EXECUTE 'ALTER TABLE public.tickets DROP CONSTRAINT IF EXISTS ' || quote_ident(r.conname);
    END LOOP;
    ALTER TABLE public.tickets ADD CONSTRAINT tickets_status_check
        CHECK (status IN ('VALID', 'CHECKED_IN', 'CHECKED_OUT', 'REVOKED'));
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- 4. Audit log ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    token TEXT,
    attendee_name TEXT,
    result_type TEXT NOT NULL,
    notes TEXT,
    gate TEXT DEFAULT 'Gate 1',
    staff_name TEXT DEFAULT 'Staff Scanner',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. Gate scanner sessions (Event Code + PIN login) -----------------------------
CREATE TABLE IF NOT EXISTS public.gate_sessions (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.gate_login_failures (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    event_code TEXT NOT NULL,
    attempted_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.gate_login_failures ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_tickets_token ON public.tickets(token);
CREATE INDEX IF NOT EXISTS idx_tickets_event_id ON public.tickets(event_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event_id ON public.audit_logs(event_id);
CREATE INDEX IF NOT EXISTS idx_events_code ON public.events(code);
CREATE INDEX IF NOT EXISTS idx_gate_failures ON public.gate_login_failures(user_id, attempted_at);
CREATE INDEX IF NOT EXISTS idx_gate_failures_code ON public.gate_login_failures(event_code, attempted_at);

-- =========================================================================
-- 6. Access helper functions
-- =========================================================================
CREATE OR REPLACE FUNCTION public.app_role()
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT role FROM public.app_users WHERE id = auth.uid() AND status = 'ACTIVE';
$$;

CREATE OR REPLACE FUNCTION public.can_access_event(p_event UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.app_users u
        WHERE u.id = auth.uid() AND u.status = 'ACTIVE'
          AND (u.role = 'MASTER_ADMIN' OR COALESCE(u.assigned_event_ids, '[]'::jsonb) ? p_event::text)
    ) OR EXISTS (
        SELECT 1 FROM public.gate_sessions g WHERE g.user_id = auth.uid() AND g.event_id = p_event
    );
$$;

-- =========================================================================
-- 7. Row Level Security (replaces the old open "USING (true)" policies)
-- =========================================================================
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gate_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gate_login_failures ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'public'
             AND tablename IN ('events', 'app_users', 'tickets', 'audit_logs', 'gate_sessions', 'gate_login_failures')
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
    END LOOP;
END $$;

-- events
CREATE POLICY events_select ON public.events FOR SELECT TO authenticated
    USING (created_by = auth.uid() OR public.can_access_event(id));
CREATE POLICY events_insert ON public.events FOR INSERT TO authenticated
    WITH CHECK (public.app_role() IN ('MASTER_ADMIN', 'EVENT_ADMIN'));
CREATE POLICY events_update ON public.events FOR UPDATE TO authenticated
    USING (public.can_access_event(id) AND public.app_role() IN ('MASTER_ADMIN', 'EVENT_ADMIN'))
    WITH CHECK (public.can_access_event(id) AND public.app_role() IN ('MASTER_ADMIN', 'EVENT_ADMIN'));
CREATE POLICY events_delete ON public.events FOR DELETE TO authenticated
    USING (public.app_role() = 'MASTER_ADMIN');

-- app_users (inserts/deletes happen only through the staff-admin Edge Function)
CREATE POLICY app_users_select ON public.app_users FOR SELECT TO authenticated
    USING (
        id = auth.uid()
        OR public.app_role() = 'MASTER_ADMIN'
        OR (public.app_role() = 'EVENT_ADMIN'
            AND role IN ('TICKETING_AGENT', 'TICKET_SCANNER')
            AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(assigned_event_ids, '[]'::jsonb)) e
                        WHERE public.can_access_event(e::uuid)))
    );
-- Only the user themself or the Master Admin may update a profile directly (privileged
-- columns are blocked for non-masters by trg_guard_app_users_update). Event Admins manage
-- their agents/scanners through the staff-admin Edge Function.
CREATE POLICY app_users_update ON public.app_users FOR UPDATE TO authenticated
    USING (id = auth.uid() OR public.app_role() = 'MASTER_ADMIN')
    WITH CHECK (id = auth.uid() OR public.app_role() = 'MASTER_ADMIN');

-- tickets
CREATE POLICY tickets_select ON public.tickets FOR SELECT TO authenticated
    USING (public.can_access_event(event_id));
CREATE POLICY tickets_insert ON public.tickets FOR INSERT TO authenticated
    WITH CHECK (public.can_access_event(event_id)
                AND public.app_role() IN ('MASTER_ADMIN', 'EVENT_ADMIN', 'TICKETING_AGENT'));
CREATE POLICY tickets_update ON public.tickets FOR UPDATE TO authenticated
    USING (public.can_access_event(event_id)
           AND public.app_role() IN ('MASTER_ADMIN', 'EVENT_ADMIN', 'TICKETING_AGENT'))
    WITH CHECK (public.can_access_event(event_id));
CREATE POLICY tickets_delete ON public.tickets FOR DELETE TO authenticated
    USING (public.can_access_event(event_id) AND public.app_role() IN ('MASTER_ADMIN', 'EVENT_ADMIN'));

-- audit_logs (append-only)
CREATE POLICY audit_select ON public.audit_logs FOR SELECT TO authenticated
    USING (public.can_access_event(event_id));
CREATE POLICY audit_insert ON public.audit_logs FOR INSERT TO authenticated
    WITH CHECK (public.can_access_event(event_id));

-- gate_sessions / gate_login_failures: no direct client access (RPC only)

-- Staff may edit their own name/username/email only; privileged columns are master-only.
CREATE OR REPLACE FUNCTION public.guard_app_users_update()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF auth.uid() IS NULL OR public.app_role() = 'MASTER_ADMIN' THEN
        RETURN NEW; -- service role (Edge Function) or master admin
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.role IS DISTINCT FROM OLD.role
       OR NEW.status IS DISTINCT FROM OLD.status
       OR NEW.assigned_event_ids IS DISTINCT FROM OLD.assigned_event_ids THEN
        RAISE EXCEPTION 'Only the Master Admin can change role, status or event assignments.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_app_users_update ON public.app_users;
CREATE TRIGGER trg_guard_app_users_update BEFORE UPDATE ON public.app_users
    FOR EACH ROW EXECUTE FUNCTION public.guard_app_users_update();

-- Event creators automatically get access to the events they create.
CREATE OR REPLACE FUNCTION public.assign_event_to_creator()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN
        UPDATE public.app_users
        SET assigned_event_ids = COALESCE(assigned_event_ids, '[]'::jsonb) || to_jsonb(NEW.id::text)
        WHERE id = auth.uid() AND role <> 'MASTER_ADMIN'
          AND NOT (COALESCE(assigned_event_ids, '[]'::jsonb) ? NEW.id::text);
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_assign_event_to_creator ON public.events;
CREATE TRIGGER trg_assign_event_to_creator AFTER INSERT ON public.events
    FOR EACH ROW EXECUTE FUNCTION public.assign_event_to_creator();

-- Audit rows written by a signed-in client always carry the server-resolved staff
-- name and timestamp, so a client cannot attribute an entry to someone else.
CREATE OR REPLACE FUNCTION public.guard_audit_insert()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_name TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW; -- service role / internal
    END IF;
    SELECT COALESCE(full_name, username) INTO v_name
    FROM public.app_users WHERE id = auth.uid() AND status = 'ACTIVE';
    NEW.staff_name := COALESCE(v_name, format('Gate Scanner [%s]', COALESCE(NEW.gate, 'Gate')));
    NEW.created_at := NOW();
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_audit_insert ON public.audit_logs;
CREATE TRIGGER trg_guard_audit_insert BEFORE INSERT ON public.audit_logs
    FOR EACH ROW EXECUTE FUNCTION public.guard_audit_insert();

-- Realtime (RLS applies to realtime events too)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'tickets') THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.tickets;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'audit_logs') THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.audit_logs;
    END IF;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- =========================================================================
-- 8. Server-side procedures (RPC)
-- =========================================================================

-- Gate scanner login: Event Code + PIN.
CREATE OR REPLACE FUNCTION public.gate_login_rpc(p_code TEXT, p_pin TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_event RECORD;
    v_code TEXT := UPPER(TRIM(COALESCE(p_code, '')));
    v_uid UUID := auth.uid();
BEGIN
    DELETE FROM public.gate_login_failures WHERE attempted_at < NOW() - INTERVAL '1 hour';
    -- Rate-limit per session so one device cannot lock out the other gates
    IF v_uid IS NOT NULL AND (SELECT COUNT(*) FROM public.gate_login_failures
        WHERE user_id = v_uid AND attempted_at > NOW() - INTERVAL '10 minutes') >= 5 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Too many failed attempts from this device. Please wait 10 minutes.');
    END IF;
    -- Backstop per event code to prevent brute force
    IF (SELECT COUNT(*) FROM public.gate_login_failures
        WHERE UPPER(event_code) = v_code AND attempted_at > NOW() - INTERVAL '1 hour') >= 100 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Too many failed attempts for this event. Please try again later or contact the event administrator.');
    END IF;

    SELECT * INTO v_event FROM public.events
    WHERE UPPER(code) = v_code AND gate_pin = p_pin AND status = 'ACTIVE';

    IF NOT FOUND THEN
        INSERT INTO public.gate_login_failures (user_id, event_code) VALUES (v_uid, v_code);
        RETURN jsonb_build_object('success', false, 'message', 'Invalid event code or PIN.');
    END IF;

    IF v_uid IS NOT NULL THEN
        INSERT INTO public.gate_sessions (user_id, event_id) VALUES (v_uid, v_event.id)
        ON CONFLICT (user_id) DO UPDATE SET event_id = EXCLUDED.event_id, created_at = NOW();
    END IF;

    RETURN jsonb_build_object('success', true, 'event_id', v_event.id, 'name', v_event.name, 'code', v_event.code);
END;
$$;

-- Atomic check-in / re-entry (row-locked). Staff identity is verified server-side.
CREATE OR REPLACE FUNCTION public.check_in_ticket_rpc(
    p_event_id UUID, p_token TEXT, p_gate TEXT, p_scanner_user TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_ticket RECORD;
    v_is_reentry BOOLEAN := false;
    v_staff TEXT;
    v_gate TEXT := COALESCE(NULLIF(TRIM(p_gate), ''), 'Main Gate');
    v_restrictions JSONB;
BEGIN
    IF NOT public.can_access_event(p_event_id) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'FORBIDDEN', 'message', 'You do not have access to this event.');
    END IF;

    -- Resolve scanner staff identity securely: registered staff uses DB profile; gate PIN session is bound to station
    SELECT COALESCE(full_name, username) INTO v_staff FROM public.app_users WHERE id = auth.uid() AND status = 'ACTIVE';
    IF v_staff IS NULL THEN
        v_staff := format('Gate Scanner [%s]', v_gate);
    END IF;

    SELECT * INTO v_ticket FROM public.tickets
    WHERE event_id = p_event_id AND LOWER(token) = LOWER(p_token) FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, p_token, 'Unknown Attendee', 'REJECTED_INVALID', v_gate, v_staff, 'Ticket not registered for this event');
        RETURN jsonb_build_object('success', false, 'reason', 'INVALID', 'message', 'Ticket not found in this event registry.');
    END IF;

    IF v_ticket.status = 'REVOKED' THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'REJECTED_INVALID', v_gate, v_staff, 'Ticket has been revoked');
        RETURN jsonb_build_object('success', false, 'reason', 'REVOKED', 'message', 'This ticket has been revoked by event administration.');
    END IF;

    -- Gate tier restriction check
    SELECT gate_restrictions INTO v_restrictions FROM public.events WHERE id = p_event_id;
    IF v_restrictions IS NOT NULL AND v_restrictions ? v_gate THEN
        IF jsonb_array_length(v_restrictions->v_gate) > 0 AND NOT (v_restrictions->v_gate ? v_ticket.tier) THEN
            INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
            VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'REJECTED_TIER_RESTRICTION', v_gate, v_staff,
                    format('Gate restriction: Tier "%s" is not permitted at %s', v_ticket.tier, v_gate));
            RETURN jsonb_build_object('success', false, 'reason', 'TIER_RESTRICTION',
                'message', format('Gate restriction: Pass tier "%s" is not valid at %s. Please direct attendee to an authorized entrance.', v_ticket.tier, v_gate),
                'attendee_name', v_ticket.attendee_name, 'tier', v_ticket.tier);
        END IF;
    END IF;

    IF v_ticket.status = 'CHECKED_IN' THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'REJECTED_DUPLICATE', v_gate, v_staff,
                format('Duplicate entry attempt. Original scan at %s via %s', v_ticket.scanned_at, v_ticket.scanned_gate));
        RETURN jsonb_build_object('success', false, 'reason', 'DUPLICATE',
            'attendee_name', v_ticket.attendee_name, 'tier', v_ticket.tier, 'token', v_ticket.token,
            'scanned_at', v_ticket.scanned_at, 'scanned_gate', v_ticket.scanned_gate, 'scanned_by', v_ticket.scanned_by);
    END IF;

    IF v_ticket.status = 'CHECKED_OUT' THEN v_is_reentry := true; END IF;

    UPDATE public.tickets
    SET status = 'CHECKED_IN', scanned_at = NOW(), scanned_gate = v_gate, scanned_by = v_staff,
        re_entry_count = COALESCE(re_entry_count, 0) + CASE WHEN v_is_reentry THEN 1 ELSE 0 END
    WHERE id = v_ticket.id;

    INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
    VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name,
            CASE WHEN v_is_reentry THEN 'SUCCESS_REENTRY' ELSE 'SUCCESS_CHECKIN' END, v_gate, v_staff,
            CASE WHEN v_is_reentry THEN format('Re-entry approved (Exit was logged at %s)', v_ticket.passed_out_at)
                 ELSE format('Entry approved via %s', v_gate) END);

    RETURN jsonb_build_object('success', true, 'is_reentry', v_is_reentry,
        'attendee_name', v_ticket.attendee_name, 'tier', v_ticket.tier, 'token', v_ticket.token,
        'scanned_at', NOW(), 'scanned_gate', v_gate);
END;
$$;

-- Atomic pass-out / exit (row-locked)
CREATE OR REPLACE FUNCTION public.pass_out_ticket_rpc(
    p_event_id UUID, p_token TEXT, p_gate TEXT, p_scanner_user TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_ticket RECORD;
    v_staff TEXT;
    v_gate TEXT := COALESCE(NULLIF(TRIM(p_gate), ''), 'Main Gate');
BEGIN
    IF NOT public.can_access_event(p_event_id) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'FORBIDDEN', 'message', 'You do not have access to this event.');
    END IF;

    SELECT COALESCE(full_name, username) INTO v_staff FROM public.app_users WHERE id = auth.uid() AND status = 'ACTIVE';
    IF v_staff IS NULL THEN
        v_staff := format('Gate Scanner [%s]', v_gate);
    END IF;

    SELECT * INTO v_ticket FROM public.tickets
    WHERE event_id = p_event_id AND LOWER(token) = LOWER(p_token) FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'INVALID', 'message', 'Ticket not found.');
    END IF;
    IF v_ticket.status = 'REVOKED' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'REVOKED', 'message', 'This ticket has been revoked by event administration.');
    END IF;
    IF v_ticket.status = 'CHECKED_OUT' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'ALREADY_OUT',
            'message', format('Attendee already logged out at %s via %s', v_ticket.passed_out_at, v_ticket.pass_out_gate),
            'attendee_name', v_ticket.attendee_name, 'tier', v_ticket.tier);
    END IF;
    IF v_ticket.status <> 'CHECKED_IN' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'NOT_CHECKED_IN',
            'message', 'Cannot log pass-out: attendee has not checked into the event yet.',
            'attendee_name', v_ticket.attendee_name, 'tier', v_ticket.tier);
    END IF;

    UPDATE public.tickets SET status = 'CHECKED_OUT', passed_out_at = NOW(), pass_out_gate = v_gate
    WHERE id = v_ticket.id;

    INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
    VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'PASS_OUT', v_gate, v_staff,
            format('Pass-out / exit logged via %s', v_gate));

    RETURN jsonb_build_object('success', true, 'attendee_name', v_ticket.attendee_name,
        'tier', v_ticket.tier, 'token', v_ticket.token, 'passed_out_at', NOW(), 'pass_out_gate', v_gate);
END;
$$;

-- Event cloning (Master Admin / Event Admin only). Creator comes from the session.
DROP FUNCTION IF EXISTS public.clone_event_rpc(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, INT, JSONB);
DROP FUNCTION IF EXISTS public.clone_event_rpc(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, INT, JSONB, JSONB);
CREATE OR REPLACE FUNCTION public.clone_event_rpc(
    p_source_event_id UUID, p_new_name TEXT, p_new_code TEXT, p_new_date TEXT, p_new_location TEXT,
    p_creator_user_id UUID DEFAULT NULL, p_new_id UUID DEFAULT NULL, p_new_pin TEXT DEFAULT NULL,
    p_new_capacity INT DEFAULT NULL, p_new_tiers JSONB DEFAULT NULL, p_new_stations JSONB DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_source RECORD;
    v_new_id UUID := COALESCE(p_new_id, uuid_generate_v4());
BEGIN
    IF public.app_role() NOT IN ('MASTER_ADMIN', 'EVENT_ADMIN') OR NOT public.can_access_event(p_source_event_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'You are not allowed to clone this event.');
    END IF;
    IF EXISTS (SELECT 1 FROM public.events WHERE UPPER(code) = UPPER(p_new_code)) THEN
        RETURN jsonb_build_object('success', false, 'message', 'An event with this code already exists. Please choose a unique code.');
    END IF;

    SELECT * INTO v_source FROM public.events WHERE id = p_source_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Source event not found.');
    END IF;

    INSERT INTO public.events (id, name, code, date, location, gate_pin, tiers, stations, capacity, status, created_by, gate_restrictions, logo_url, brand_color)
    VALUES (v_new_id, p_new_name, UPPER(p_new_code), p_new_date, p_new_location,
            COALESCE(p_new_pin, v_source.gate_pin, '1234'),
            COALESCE(p_new_tiers, v_source.tiers, '["VIP Pass", "Standard Pass"]'::jsonb),
            COALESCE(p_new_stations, v_source.stations, '["Gate 1 (Main Entrance)", "Gate 2 (VIP / Media)", "North Turnstile", "South Turnstile"]'::jsonb),
            COALESCE(p_new_capacity, v_source.capacity, 500), 'ACTIVE', auth.uid(),
            COALESCE(v_source.gate_restrictions, '{}'::jsonb),
            v_source.logo_url, COALESCE(v_source.brand_color, '#0284c7'));
    -- trg_assign_event_to_creator grants the creator access automatically.

    RETURN jsonb_build_object('success', true, 'id', v_new_id, 'name', p_new_name, 'code', UPPER(p_new_code),
        'date', p_new_date, 'location', p_new_location, 'capacity', COALESCE(p_new_capacity, v_source.capacity, 500));
END;
$$;

-- Atomic ticket revocation (with audit trail)
CREATE OR REPLACE FUNCTION public.revoke_ticket_rpc(
    p_ticket_id UUID, p_reason TEXT DEFAULT 'Manually revoked by staff'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_ticket RECORD;
    v_staff TEXT;
BEGIN
    SELECT * INTO v_ticket FROM public.tickets WHERE id = p_ticket_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ticket not found.');
    END IF;

    IF NOT public.can_access_event(v_ticket.event_id) OR public.app_role() NOT IN ('MASTER_ADMIN', 'EVENT_ADMIN', 'TICKETING_AGENT') THEN
        RETURN jsonb_build_object('success', false, 'message', 'You do not have permission to revoke tickets for this event.');
    END IF;

    SELECT COALESCE(full_name, username) INTO v_staff FROM public.app_users WHERE id = auth.uid();

    UPDATE public.tickets
    SET status = 'REVOKED', notes = COALESCE(notes || E'\n', '') || format('[REVOKED by %s on %s: %s]', COALESCE(v_staff, 'Staff'), NOW()::text, COALESCE(p_reason, ''))
    WHERE id = v_ticket.id;

    INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
    VALUES (v_ticket.event_id, v_ticket.token, v_ticket.attendee_name, 'TICKET_REVOKED', 'Administration Desk', COALESCE(v_staff, 'Staff'), COALESCE(p_reason, 'Ticket manually revoked'));

    RETURN jsonb_build_object('success', true, 'attendee_name', v_ticket.attendee_name, 'token', v_ticket.token);
END;
$$;

-- =========================================================================
-- 9. Function permissions: nobody gets anything by default, then grant explicitly
-- =========================================================================
REVOKE ALL ON FUNCTION public.gate_login_rpc(TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.check_in_ticket_rpc(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pass_out_ticket_rpc(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clone_event_rpc(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, INT, JSONB, JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_ticket_rpc(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gate_login_rpc(TEXT, TEXT) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.check_in_ticket_rpc(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pass_out_ticket_rpc(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clone_event_rpc(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, INT, JSONB, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_ticket_rpc(UUID, TEXT) TO authenticated;

-- The anon role (not signed in at all) gets no table access whatsoever.
REVOKE ALL ON public.events, public.app_users, public.tickets, public.audit_logs,
              public.gate_sessions, public.gate_login_failures FROM anon;

-- =========================================================================
-- 10. BOOTSTRAP THE MASTER ADMIN (run once, after creating the user in
--     Authentication > Users). Replace the email with your own:
-- =========================================================================
-- INSERT INTO public.app_users (id, username, email, role, full_name)
-- SELECT id, 'admin', email, 'MASTER_ADMIN', 'Master Admin'
-- FROM auth.users WHERE email = 'you@example.com'
-- ON CONFLICT (id) DO UPDATE SET role = 'MASTER_ADMIN', status = 'ACTIVE';
