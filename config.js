/**
 * IglooTickets - Configuration
 * The Supabase anon key is public by design; all data access is protected by
 * Row Level Security and server-side authentication (see schema.sql).
 */

const APP_CONFIG = {
    supabaseUrl: 'https://dvkrjustiobsvgyulnfc.supabase.co',
    supabaseAnonKey: 'sb_publishable_U3IhicX7ha_RqEfrKL-uCg_f--zMcfZ',

    // App Metadata
    version: '3.0.0',
    appName: 'IglooTickets',

    // Minimum length for staff passwords
    minPasswordLength: 8
};
