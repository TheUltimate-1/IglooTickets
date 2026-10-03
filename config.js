/**
 * EventShield QR - Configuration & Initial Data Store
 * Supports Dual Mode: Instant Local Demo Mode + Supabase Realtime Live Mode
 */

const APP_CONFIG = {
    // =========================================================================
    // ⚡ SUPABASE CLOUD CREDENTIALS
    // Paste your Supabase Project URL and Publishable/Anon Key here:
    // When filled, the app automatically connects in Live Multi-Device Sync mode!
    // =========================================================================
    supabaseUrl: 'https://dvkrjustiobsvgyulnfc.supabase.co',      // e.g. 'https://abcdefghijklm.supabase.co'
    supabaseAnonKey: 'sb_publishable_U3IhicX7ha_RqEfrKL-uCg_f--zMcfZ',  // e.g. 'sbp_...' or 'eyJhbGci...'

    // Mode: 'SUPABASE' (for live cloud sync) or 'DEMO' (for local test)
    mode: 'SUPABASE',

    // App Metadata
    version: '2.6.0',
    appName: 'EventShield QR Enterprise',

    // Default Seed Events (used for Demo Mode or initial sync)
    defaultEvents: [
        {
            id: 'a0000000-0000-0000-0000-000000000001',
            name: 'TechHorizon Global Summit 2026',
            code: 'TECH26',
            date: '2026-11-15',
            location: 'Metropolitan Convention Hall A',
            gatePin: '7788',
            tiers: ['VIP Platinum Pass', 'General Delegate', 'Speaker / VIP', 'Press & Media'],
            capacity: 500,
            status: 'ACTIVE',
            createdAt: new Date().toISOString()
        },
        {
            id: 'a0000000-0000-0000-0000-000000000002',
            name: 'CyberDefend Security Expo',
            code: 'CYBER26',
            date: '2026-12-04',
            location: 'Exhibition Center - Pavilion 3',
            gatePin: '4321',
            tiers: ['Security Officer', 'Exhibitor All-Access', 'Standard Attendee'],
            capacity: 350,
            status: 'ACTIVE',
            createdAt: new Date().toISOString()
        }
    ],

    // Default Seed Users (Password for all accounts is: password123)
    // SHA-256('password123') = ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f
    defaultUsers: [
        {
            id: 'b0000000-0000-0000-0000-000000000001',
            username: 'master_admin',
            email: 'master@eventshield.io',
            passwordHash: 'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
            role: 'MASTER_ADMIN',
            fullName: 'Alexander Vance (Master Director)',
            assignedEventIds: [], // All events
            status: 'ACTIVE',
            createdAt: new Date().toISOString()
        },
        {
            id: 'b0000000-0000-0000-0000-000000000002',
            username: 'event_admin',
            email: 'sarah.event@techhorizon.com',
            passwordHash: 'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
            role: 'EVENT_ADMIN',
            fullName: 'Sarah Connor (Event Manager)',
            assignedEventIds: ['a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002'],
            status: 'ACTIVE',
            createdAt: new Date().toISOString()
        },
        {
            id: 'b0000000-0000-0000-0000-000000000003',
            username: 'agent_marcus',
            email: 'marcus.tickets@convention.org',
            passwordHash: 'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
            role: 'TICKETING_AGENT',
            fullName: 'Marcus Vance (Ticket Agent)',
            assignedEventIds: ['a0000000-0000-0000-0000-000000000001'],
            status: 'ACTIVE',
            createdAt: new Date().toISOString()
        },
        {
            id: 'b0000000-0000-0000-0000-000000000004',
            username: 'gate_scanner',
            email: '', // Optional email
            passwordHash: 'ef92b778bafe771e89245b89ecbc08a44a4e166c06659911881f383d4473e94f',
            role: 'TICKET_SCANNER',
            fullName: 'Gate 1 Staff Scanner',
            assignedEventIds: ['a0000000-0000-0000-0000-000000000001'],
            status: 'ACTIVE',
            createdAt: new Date().toISOString()
        }
    ],

    // Default Seed Tickets
    defaultTickets: [
        {
            id: 'c0000000-0000-0000-0000-000000000001',
            eventId: 'a0000000-0000-0000-0000-000000000001',
            token: 'ed321a4f-8891-49b2-a42e-111111111111',
            attendeeName: 'Alex Johnson',
            attendeeEmail: 'alex.j@enterprise.com',
            tier: 'VIP Platinum Pass',
            status: 'VALID',
            issuedAt: new Date(Date.now() - 3600000 * 5).toISOString(),
            issuedBy: 'Marcus Vance',
            scannedAt: null,
            scannedBy: null,
            scannedGate: null
        },
        {
            id: 'c0000000-0000-0000-0000-000000000002',
            eventId: 'a0000000-0000-0000-0000-000000000001',
            token: 'b83d99fa-71a2-4a02-b21a-222222222222',
            attendeeName: 'Elena Rostova',
            attendeeEmail: 'elena.rostova@speakers.net',
            tier: 'Speaker / VIP',
            status: 'VALID',
            issuedAt: new Date(Date.now() - 3600000 * 3).toISOString(),
            issuedBy: 'Marcus Vance',
            scannedAt: null,
            scannedBy: null,
            scannedGate: null
        },
        {
            id: 'c0000000-0000-0000-0000-000000000003',
            eventId: 'a0000000-0000-0000-0000-000000000001',
            token: 'c52e88bb-12a1-4209-a111-333333333333',
            attendeeName: 'Devon Miles',
            attendeeEmail: 'devon@pressmedia.com',
            tier: 'Press & Media',
            status: 'VALID',
            issuedAt: new Date(Date.now() - 3600000 * 1).toISOString(),
            issuedBy: 'Sarah Connor',
            scannedAt: null,
            scannedBy: null,
            scannedGate: null
        }
    ]
};

// Helper: Secure SHA-256 string hash using browser Web Crypto API
async function hashPassword(plainText) {
    if (!plainText) return '';
    const encoder = new TextEncoder();
    const data = encoder.encode(plainText);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}
