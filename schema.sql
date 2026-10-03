-- =========================================================================
-- EventShield QR - Supabase Database Schema (v2.6.0)
-- 100% Free PostgreSQL & Realtime Backend Setup
-- Features: Security RPCs, Atomic Check-In, Pass-Out / Re-Entry, Event Cloning, Capacity Headcount
-- Instructions: Paste this entire script into your Supabase SQL Editor and click RUN.
-- =========================================================================

-- 1. Create Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. Events Table
CREATE TABLE IF NOT EXISTS public.events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL, -- Short code for gate pin login e.g. "SUMMIT26"
    date TEXT NOT NULL,
    location TEXT NOT NULL,
    gate_pin TEXT NOT NULL DEFAULT '1234', -- 4-digit PIN for quick scanner mobile entry
    tiers JSONB NOT NULL DEFAULT '["VIP General Access", "Standard Pass", "Speaker / Backstage", "Press / Media"]'::jsonb,
    capacity INT NOT NULL DEFAULT 500, -- Maximum venue capacity for live headcount tracking
    status TEXT NOT NULL DEFAULT 'ACTIVE', -- ACTIVE, ARCHIVED
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Ensure capacity column exists if upgrading from v1
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS capacity INT NOT NULL DEFAULT 500;

-- 3. App Users / Staff Table
CREATE TABLE IF NOT EXISTS public.app_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username TEXT UNIQUE NOT NULL,
    email TEXT,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('MASTER_ADMIN', 'EVENT_ADMIN', 'TICKETING_AGENT', 'TICKET_SCANNER')),
    assigned_event_ids JSONB DEFAULT '[]'::jsonb, -- Array of event UUIDs this staff has access to
    full_name TEXT,
    status TEXT NOT NULL DEFAULT 'ACTIVE', -- ACTIVE, REVOKED
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Tickets Registry Table
CREATE TABLE IF NOT EXISTS public.tickets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    token TEXT UNIQUE NOT NULL, -- UUID QR Code Payload
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

-- Upgrade existing tickets table schema safely
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS passed_out_at TIMESTAMPTZ;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS pass_out_gate TEXT;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS re_entry_count INT DEFAULT 0;

ALTER TABLE public.tickets DROP CONSTRAINT IF EXISTS tickets_status_check;
ALTER TABLE public.tickets ADD CONSTRAINT tickets_status_check CHECK (status IN ('VALID', 'CHECKED_IN', 'CHECKED_OUT', 'REVOKED'));

-- 5. Audit & Scan Verification Logs Table
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    token TEXT,
    attendee_name TEXT,
    result_type TEXT NOT NULL, -- SUCCESS_CHECKIN, SUCCESS_REENTRY, PASS_OUT, REJECTED_DUPLICATE, REJECTED_INVALID, TICKET_ISSUED, TICKET_REMOVED, TICKET_REVOKED
    notes TEXT,
    gate TEXT DEFAULT 'Gate 1',
    staff_name TEXT DEFAULT 'Staff Scanner',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for lightning-fast QR lookups at the gate
CREATE INDEX IF NOT EXISTS idx_tickets_token ON public.tickets(token);
CREATE INDEX IF NOT EXISTS idx_tickets_event_id ON public.tickets(event_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event_id ON public.audit_logs(event_id);
CREATE INDEX IF NOT EXISTS idx_events_code ON public.events(code);

-- 6. Enable Row Level Security (RLS) & Open Public Access Policies
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow public all events') THEN
        CREATE POLICY "Allow public all events" ON public.events FOR ALL USING (true) WITH CHECK (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow public all users') THEN
        CREATE POLICY "Allow public all users" ON public.app_users FOR ALL USING (true) WITH CHECK (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow public all tickets') THEN
        CREATE POLICY "Allow public all tickets" ON public.tickets FOR ALL USING (true) WITH CHECK (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow public all audit_logs') THEN
        CREATE POLICY "Allow public all audit_logs" ON public.audit_logs FOR ALL USING (true) WITH CHECK (true);
    END IF;
END $$;

-- Enable Realtime broadcasting on tickets and audit_logs
ALTER PUBLICATION supabase_realtime ADD TABLE public.tickets;
ALTER PUBLICATION supabase_realtime ADD TABLE public.audit_logs;

-- =========================================================================
-- 7. 🛡️ SECURITY & ATOMIC DATABASE PROCEDURES (RPC)
-- =========================================================================

-- A. Atomic Check-In & Re-Entry RPC
CREATE OR REPLACE FUNCTION check_in_ticket_rpc(
    p_event_id UUID,
    p_token TEXT,
    p_gate TEXT,
    p_scanner_user TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ticket RECORD;
    v_is_reentry BOOLEAN := false;
BEGIN
    -- 1. Find ticket by token and event
    SELECT * INTO v_ticket 
    FROM public.tickets 
    WHERE event_id = p_event_id AND LOWER(token) = LOWER(p_token);

    IF NOT FOUND THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, p_token, 'Unknown Attendee', 'REJECTED_INVALID', p_gate, p_scanner_user, 'Ticket not registered for this event');
        
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'INVALID',
            'message', 'Ticket not found in this event registry.'
        );
    END IF;

    -- 2. Revoked check
    IF v_ticket.status = 'REVOKED' THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'REJECTED_INVALID', p_gate, p_scanner_user, 'Ticket has been revoked');
        
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'REVOKED',
            'message', 'This ticket has been revoked by event administration.'
        );
    END IF;

    -- 3. Duplicate check (already inside venue)
    IF v_ticket.status = 'CHECKED_IN' THEN
        INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
        VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'REJECTED_DUPLICATE', p_gate, p_scanner_user, 
                format('Duplicate entry attempt. Original scan at %s via %s', v_ticket.scanned_at, v_ticket.scanned_gate));

        RETURN jsonb_build_object(
            'success', false,
            'reason', 'DUPLICATE',
            'attendee_name', v_ticket.attendee_name,
            'tier', v_ticket.tier,
            'token', v_ticket.token,
            'scanned_at', v_ticket.scanned_at,
            'scanned_gate', v_ticket.scanned_gate,
            'scanned_by', v_ticket.scanned_by
        );
    END IF;

    -- 4. Re-entry check (was checked out)
    IF v_ticket.status = 'CHECKED_OUT' THEN
        v_is_reentry := true;
    END IF;

    -- 5. Atomic Update
    UPDATE public.tickets
    SET status = 'CHECKED_IN',
        scanned_at = NOW(),
        scanned_gate = p_gate,
        scanned_by = p_scanner_user,
        re_entry_count = COALESCE(re_entry_count, 0) + CASE WHEN v_is_reentry THEN 1 ELSE 0 END
    WHERE id = v_ticket.id;

    -- 6. Record Audit Log
    INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
    VALUES (
        p_event_id, 
        v_ticket.token, 
        v_ticket.attendee_name, 
        CASE WHEN v_is_reentry THEN 'SUCCESS_REENTRY' ELSE 'SUCCESS_CHECKIN' END, 
        p_gate, 
        p_scanner_user, 
        CASE WHEN v_is_reentry THEN format('Re-entry approved (Exit was logged at %s)', v_ticket.passed_out_at) ELSE format('Entry approved via %s', p_gate) END
    );

    RETURN jsonb_build_object(
        'success', true,
        'is_reentry', v_is_reentry,
        'attendee_name', v_ticket.attendee_name,
        'tier', v_ticket.tier,
        'token', v_ticket.token,
        'scanned_at', NOW(),
        'scanned_gate', p_gate
    );
END;
$$;

-- B. Atomic Pass-Out / Exit Tracking RPC
CREATE OR REPLACE FUNCTION pass_out_ticket_rpc(
    p_event_id UUID,
    p_token TEXT,
    p_gate TEXT,
    p_scanner_user TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ticket RECORD;
BEGIN
    SELECT * INTO v_ticket 
    FROM public.tickets 
    WHERE event_id = p_event_id AND LOWER(token) = LOWER(p_token);

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'INVALID', 'message', 'Ticket not found.');
    END IF;

    IF v_ticket.status = 'CHECKED_OUT' THEN
        RETURN jsonb_build_object(
            'success', false, 
            'reason', 'ALREADY_OUT', 
            'message', format('Attendee already logged out at %s via %s', v_ticket.passed_out_at, v_ticket.pass_out_gate),
            'attendee_name', v_ticket.attendee_name,
            'tier', v_ticket.tier
        );
    END IF;

    IF v_ticket.status != 'CHECKED_IN' THEN
        RETURN jsonb_build_object(
            'success', false, 
            'reason', 'NOT_CHECKED_IN', 
            'message', 'Cannot log pass-out: attendee has not checked into the event yet.',
            'attendee_name', v_ticket.attendee_name,
            'tier', v_ticket.tier
        );
    END IF;

    -- Update to CHECKED_OUT
    UPDATE public.tickets
    SET status = 'CHECKED_OUT',
        passed_out_at = NOW(),
        pass_out_gate = p_gate
    WHERE id = v_ticket.id;

    INSERT INTO public.audit_logs (event_id, token, attendee_name, result_type, gate, staff_name, notes)
    VALUES (p_event_id, v_ticket.token, v_ticket.attendee_name, 'PASS_OUT', p_gate, p_scanner_user, format('Pass-out / exit logged via %s', p_gate));

    RETURN jsonb_build_object(
        'success', true,
        'attendee_name', v_ticket.attendee_name,
        'tier', v_ticket.tier,
        'token', v_ticket.token,
        'passed_out_at', NOW(),
        'pass_out_gate', p_gate
    );
END;
$$;

-- C. 1-Click Event Cloning RPC
CREATE OR REPLACE FUNCTION clone_event_rpc(
    p_source_event_id UUID,
    p_new_name TEXT,
    p_new_code TEXT,
    p_new_date TEXT,
    p_new_location TEXT,
    p_creator_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_source RECORD;
    v_new_id UUID := uuid_generate_v4();
    v_user_assigned JSONB;
BEGIN
    SELECT * INTO v_source FROM public.events WHERE id = p_source_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Source event not found.');
    END IF;

    -- Insert cloned event
    INSERT INTO public.events (id, name, code, date, location, gate_pin, tiers, capacity, status)
    VALUES (
        v_new_id,
        p_new_name,
        p_new_code,
        p_new_date,
        p_new_location,
        v_source.gate_pin,
        v_source.tiers,
        COALESCE(v_source.capacity, 500),
        'ACTIVE'
    );

    -- If creator user is provided, add new event ID to user's assigned events
    IF p_creator_user_id IS NOT NULL THEN
        SELECT assigned_event_ids INTO v_user_assigned FROM public.app_users WHERE id = p_creator_user_id;
        IF FOUND AND v_user_assigned IS NOT NULL THEN
            UPDATE public.app_users
            SET assigned_event_ids = (v_user_assigned || to_jsonb(v_new_id::text))
            WHERE id = p_creator_user_id;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'id', v_new_id,
        'name', p_new_name,
        'code', p_new_code,
        'date', p_new_date,
        'location', p_new_location,
        'capacity', COALESCE(v_source.capacity, 500)
    );
END;
$$;

-- Grant execution to public / anon for easy client RPC access
GRANT EXECUTE ON FUNCTION check_in_ticket_rpc(UUID, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION pass_out_ticket_rpc(UUID, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION clone_event_rpc(UUID, TEXT, TEXT, TEXT, TEXT, UUID) TO anon, authenticated, service_role;

-- 8. Seed Initial Master Admin and Demo Event
INSERT INTO public.events (id, name, code, date, location, gate_pin, tiers, capacity)
VALUES (
    'a0000000-0000-0000-0000-000000000001',
    'TechHorizon Global Summit 2026',
    'TECH26',
    '2026-11-15',
    'Grand Metropolitan Convention Center',
    '7788',
    '["VIP Platinum Pass", "General Delegate", "Speaker / VIP", "Press & Media"]'::jsonb,
    500
) ON CONFLICT (code) DO NOTHING;

INSERT INTO public.app_users (id, username, email, password_hash, role, assigned_event_ids, full_name)
VALUES 
(
    'b0000000-0000-0000-0000-000000000001',
    'master_admin',
    'superadmin@eventshield.io',
    'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
    'MASTER_ADMIN',
    '[]'::jsonb,
    'Global System Director'
),
(
    'b0000000-0000-0000-0000-000000000002',
    'event_admin',
    'admin@techhorizon.com',
    'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
    'EVENT_ADMIN',
    '["a0000000-0000-0000-0000-000000000001"]'::jsonb,
    'Event Coordinator Sarah'
),
(
    'b0000000-0000-0000-0000-000000000003',
    'agent_marcus',
    'marcus@tickets.org',
    'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
    'TICKETING_AGENT',
    '["a0000000-0000-0000-0000-000000000001"]'::jsonb,
    'Ticketing Desk Marcus'
),
(
    'b0000000-0000-0000-0000-000000000004',
    'gate_scanner',
    NULL,
    'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
    'TICKET_SCANNER',
    '["a0000000-0000-0000-0000-000000000001"]'::jsonb,
    'Gate 1 Scanner Station'
) ON CONFLICT (username) DO NOTHING;

-- Seed Sample Tickets
INSERT INTO public.tickets (event_id, token, attendee_name, attendee_email, tier, status)
VALUES 
('a0000000-0000-0000-0000-000000000001', 'ed321a4f-8891-49b2-a42e-111111111111', 'Alex Johnson', 'alex.j@cyber.com', 'VIP Platinum Pass', 'VALID'),
('a0000000-0000-0000-0000-000000000001', 'b83d99fa-71a2-4a02-b21a-222222222222', 'Elena Rostova', 'elena.r@speakers.net', 'Speaker / VIP', 'VALID'),
('a0000000-0000-0000-0000-000000000001', 'c52e88bb-12a1-4209-a111-333333333333', 'Marcus Vance', 'marcus.v@media.org', 'General Delegate', 'VALID')
ON CONFLICT (token) DO NOTHING;
