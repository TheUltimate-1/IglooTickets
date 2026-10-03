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
    version: '2.6.1',
    appName: 'IglooTickets Enterprise',

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
        }
    ],

    // Default Seed Users (Only Master Admin Nethil is registered; staff accounts can be created via the Global Staff Directory)
    defaultUsers: [
        {
            id: 'b0000000-0000-0000-0000-000000000001',
            username: 'nethil',
            email: 'nethil2008@gmail.com',
            passwordHash: '77aae185203edc6357676db95caa25d0f398d402c1723e6a7b42cfe8d2967f2e',
            role: 'MASTER_ADMIN',
            fullName: 'Nethil',
            assignedEventIds: [], // All events
            status: 'ACTIVE',
            createdAt: new Date().toISOString()
        }
    ],

    // Default Seed Tickets (Clean slate for production launch)
    defaultTickets: []
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
