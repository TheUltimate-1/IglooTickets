-- =========================================================================
-- EventShield QR - Supabase Database Schema
-- 100% Free PostgreSQL & Realtime Backend Setup
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
    status TEXT NOT NULL DEFAULT 'ACTIVE', -- ACTIVE, ARCHIVED
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. App Users / Staff Table
-- Supports login with username and optional email without mandatory email confirmation
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
    status TEXT NOT NULL DEFAULT 'VALID' CHECK (status IN ('VALID', 'CHECKED_IN', 'REVOKED')),
    issued_at TIMESTAMPTZ DEFAULT NOW(),
    issued_by TEXT DEFAULT 'System',
    scanned_at TIMESTAMPTZ,
    scanned_by TEXT,
    scanned_gate TEXT,
    notes TEXT
);

-- 5. Audit & Scan Verification Logs Table
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    token TEXT,
    attendee_name TEXT,
    result_type TEXT NOT NULL, -- SUCCESS_CHECKIN, REJECTED_DUPLICATE, REJECTED_INVALID, TICKET_ISSUED, TICKET_REMOVED, TICKET_REVOKED
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
-- (For straightforward anon-key client access. You can lock this down further if required)
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Allow anon public read/write for seamless client interaction
CREATE POLICY "Allow public all events" ON public.events FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow public all users" ON public.app_users FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow public all tickets" ON public.tickets FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow public all audit_logs" ON public.audit_logs FOR ALL USING (true) WITH CHECK (true);

-- Enable Realtime broadcasting on tickets and audit_logs
ALTER PUBLICATION supabase_realtime ADD TABLE public.tickets;
ALTER PUBLICATION supabase_realtime ADD TABLE public.audit_logs;

-- 7. Seed Initial Master Admin and Demo Event
-- Master Admin (username: master_admin, password: password123)
-- SHA-256 for 'password123' = ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f
INSERT INTO public.events (id, name, code, date, location, gate_pin, tiers)
VALUES (
    'a0000000-0000-0000-0000-000000000001',
    'TechHorizon Global Summit 2026',
    'TECH26',
    '2026-11-15',
    'Grand Metropolitan Convention Center',
    '7788',
    '["VIP Platinum Pass", "General Delegate", "Speaker / VIP", "Press & Media"]'::jsonb
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
