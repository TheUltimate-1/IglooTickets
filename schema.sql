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

-- Migration from v2.x: drop stored password hashes and rows with no auth account.
ALTER TABLE public.app_users DROP COLUMN IF EXISTS password_hash;
DO $$
BEGIN
    DELETE FROM public.app_users WHERE id NOT IN (SELECT id FROM auth.users);
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.app_users'::regclass AND conname = 'app_users_id_auth_fkey'
    ) THEN
        ALTER TABLE public.app_users
            ADD CONSTRAINT app_users_id_auth_fkey
            FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
    END IF;
EXCEPTION WHEN duplicate_object THEN NULL;
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
    event_code TEXT NOT NULL,
    attempted_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tickets_token ON public.tickets(token);
CREATE INDEX IF NOT EXISTS idx_tickets_event_id ON public.tickets(event_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event_id ON public.audit_logs(event_id);
CREATE INDEX IF NOT EXISTS idx_events_code ON public.events(code);
CREATE INDEX IF NOT EXISTS idx_gate_failures ON public.gate_login_failures(event_code, attempted_at);

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
    USING (id = auth.uid() OR public.app_role() = 'MASTER_ADMIN');
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

-- Gate scanner login: Event Code + PIN. Requires an (anonymous) Supabase session.
CREATE OR REPLACE FUNCTION public.gate_login_rpc(p_code TEXT, p_pin TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_event RECORD;
    v_code TEXT := UPPER(TRIM(COALESCE(p_code, '')));
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Not signed in.');
    END IF;

    DELETE FROM public.gate_login_failures WHERE attempted_at < NOW() - INTERVAL '1 hour';
    IF (SELECT COUNT(*) FROM public.gate_login_failures
        WHERE event_code = v_code AND attempted_at > NOW() - INTERVAL '10 minutes') >= 10 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Too many failed attempts. Try again in 10 minutes.');
    END IF;

    SELECT * INTO v_event FROM public.events
    WHERE UPPER(code) = v_code AND gate_pin = p_pin AND status = 'ACTIVE';

    IF NOT FOUND THEN
        INSERT INTO public.gate_login_failures (event_code) VALUES (v_code);
        RETURN jsonb_build_object('success', false, 'message', 'Invalid event code or PIN.');
    END IF;

    INSERT INTO public.gate_sessions (user_id, event_id) VALUES (auth.uid(), v_event.id)
    ON CONFLICT (user_id) DO UPDATE SET event_id = EXCLUDED.event_id, created_at = NOW();

    RETURN jsonb_build_object('success', true, 'event_id', v_event.id, 'name', v_event.name, 'code', v_event.code);
END;
$$;

-- Atomic check-in / re-entry (row-locked). Staff identity comes from the session.
CREATE OR REPLACE FUNCTION public.check_in_ticket_rpc(
    p_event_id UUID, p_token TEXT, p_gate TEXT, p_scanner_user TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_ticket RECORD;
    v_is_reentry BOOLEAN := false;
    v_staff TEXT;
BEGIN
    IF NOT public.can_access_event(p_event_id) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'FORBIDDEN', 'message', 'You do not have access to this event.');
    END IF;
    v_staff := COALESCE((SELECT COALESCE(full_name, username) FROM public.app_users WHERE id = auth.uid()), NULLIF(p_scanner_user, ''), 'Gate Scanner');

    SELECT * INTO v_ticket FROM public.tickets
    WHERE event_id = p_event_id AND LOWER(token) = LOWER(p_token) FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, p_token, 'Unknown Attendee', 'REJECTED_INVALID', p_gate, v_staff, 'Ticket not registered for this event');
        RETURN jsonb_build_object('success', false, 'reason', 'INVALID', 'message', 'Ticket not found in this event registry.');
    END IF;

    IF v_ticket.status = 'REVOKED' THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'REJECTED_INVALID', p_gate, v_staff, 'Ticket has been revoked');
        RETURN jsonb_build_object('success', false, 'reason', 'REVOKED', 'message', 'This ticket has been revoked by event administration.');
    END IF;

    IF v_ticket.status = 'CHECKED_IN' THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'REJECTED_DUPLICATE', p_gate, v_staff,
                format('Duplicate entry attempt. Original scan at %s via %s', v_ticket.scanned_at, v_ticket.scanned_gate));
        RETURN jsonb_build_object('success', false, 'reason', 'DUPLICATE',
            'attendee_name', v_ticket.attendee_name, 'tier', v_ticket.tier, 'token', v_ticket.token,
            'scanned_at', v_ticket.scanned_at, 'scanned_gate', v_ticket.scanned_gate, 'scanned_by', v_ticket.scanned_by);
    END IF;

    IF v_ticket.status = 'CHECKED_OUT' THEN v_is_reentry := true; END IF;

    UPDATE public.tickets
    SET status = 'CHECKED_IN', scanned_at = NOW(), scanned_gate = p_gate, scanned_by = v_staff,
        re_entry_count = COALESCE(re_entry_count, 0) + CASE WHEN v_is_reentry THEN 1 ELSE 0 END
    WHERE id = v_ticket.id;

    INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
    VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name,
            CASE WHEN v_is_reentry THEN 'SUCCESS_REENTRY' ELSE 'SUCCESS_CHECKIN' END, p_gate, v_staff,
            CASE WHEN v_is_reentry THEN format('Re-entry approved (Exit was logged at %s)', v_ticket.passed_out_at)
                 ELSE format('Entry approved via %s', p_gate) END);

    RETURN jsonb_build_object('success', true, 'is_reentry', v_is_reentry,
        'attendee_name', v_ticket.attendee_name, 'tier', v_ticket.tier, 'token', v_ticket.token,
        'scanned_at', NOW(), 'scanned_gate', p_gate);
END;
$$;

-- Atomic pass-out / exit (row-locked)
CREATE OR REPLACE FUNCTION public.pass_out_ticket_rpc(
    p_event_id UUID, p_token TEXT, p_gate TEXT, p_scanner_user TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_ticket RECORD;
    v_staff TEXT;
BEGIN
    IF NOT public.can_access_event(p_event_id) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'FORBIDDEN', 'message', 'You do not have access to this event.');
    END IF;
    v_staff := COALESCE((SELECT COALESCE(full_name, username) FROM public.app_users WHERE id = auth.uid()), NULLIF(p_scanner_user, ''), 'Gate Scanner');

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

    UPDATE public.tickets SET status = 'CHECKED_OUT', passed_out_at = NOW(), pass_out_gate = p_gate
    WHERE id = v_ticket.id;

    INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
    VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'PASS_OUT', p_gate, v_staff,
            format('Pass-out / exit logged via %s', p_gate));

    RETURN jsonb_build_object('success', true, 'attendee_name', v_ticket.attendee_name,
        'tier', v_ticket.tier, 'token', v_ticket.token, 'passed_out_at', NOW(), 'pass_out_gate', p_gate);
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

    INSERT INTO public.events (id, name, code, date, location, gate_pin, tiers, stations, capacity, status, created_by)
    VALUES (v_new_id, p_new_name, UPPER(p_new_code), p_new_date, p_new_location,
            COALESCE(p_new_pin, v_source.gate_pin, '1234'),
            COALESCE(p_new_tiers, v_source.tiers, '["VIP Pass", "Standard Pass"]'::jsonb),
            COALESCE(p_new_stations, v_source.stations, '["Gate 1 (Main Entrance)", "Gate 2 (VIP / Media)", "North Turnstile", "South Turnstile"]'::jsonb),
            COALESCE(p_new_capacity, v_source.capacity, 500), 'ACTIVE', auth.uid());
    -- trg_assign_event_to_creator grants the creator access automatically.

    RETURN jsonb_build_object('success', true, 'id', v_new_id, 'name', p_new_name, 'code', UPPER(p_new_code),
        'date', p_new_date, 'location', p_new_location, 'capacity', COALESCE(p_new_capacity, v_source.capacity, 500));
END;
$$;

-- =========================================================================
-- 9. Function permissions: nobody gets anything by default, then grant explicitly
-- =========================================================================
REVOKE ALL ON FUNCTION public.gate_login_rpc(TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.check_in_ticket_rpc(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pass_out_ticket_rpc(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clone_event_rpc(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, INT, JSONB, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gate_login_rpc(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_in_ticket_rpc(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pass_out_ticket_rpc(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clone_event_rpc(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, INT, JSONB, JSONB) TO authenticated;

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
