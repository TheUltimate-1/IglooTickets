# IglooTickets

A web-based event ticketing, badge issuance, and gate validation platform built for fast on-site access control, role-based administration, and offline resilience.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-3.0.0-emerald.svg)](config.js)
[![PWA Ready](https://img.shields.io/badge/PWA-Ready-purple.svg)](manifest.json)
[![Database: Supabase](https://img.shields.io/badge/Database-Supabase%20PostgreSQL-3ECF8E.svg)](schema.sql)

---

## Overview

IglooTickets is an event ticketing and entrance management system designed for physical event operations. It handles the end-to-end lifecycle of event access: creating events, provisioning staff accounts with granular permissions, issuing tickets (individually or via bulk CSV), and validating attendee passes at gates using standard mobile browsers and built-in cameras.

The platform is designed to operate reliably under real-world venue conditions, featuring server-side atomic validation to prevent duplicate entries across concurrent turnstiles, and an offline caching engine that keeps scanners operational even if venue connectivity drops.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Client Layer (PWA)                     │
│  - Single-page application (HTML5, ES6+, Tailwind CSS)      │
│  - Video feed QR decoder (WebRTC getUserMedia + jsQR)       │
│  - Off-screen Canvas PDF badge engine (jsPDF)               │
│  - Local roster cache & offline scan queue (IndexedDB)      │
└──────────────┬──────────────────────────────┬───────────────┘
               │ REST / WebSockets            │ HTTPS Invoke
               ▼                              ▼
┌──────────────────────────────┐ ┌────────────────────────────┐
│      Supabase PostgreSQL     │ │   Supabase Edge Functions  │
│  - Row Level Security (RLS)  │ │   (Deno / TypeScript)      │
│  - Atomic RPCs (FOR UPDATE)  │ │  - staff-admin             │
│  - Audit log append-only     │ │  - send-ticket-email       │
│  - Realtime publication      │ │    (Brevo / Resend API)    │
└──────────────────────────────┘ └────────────────────────────┘
```

### Core Technologies

- **Frontend**: Vanilla JavaScript (ES6+), Tailwind CSS, Font Awesome 6, Web App Manifest
- **Scanning Engine**: WebRTC `navigator.mediaDevices.getUserMedia` with `jsQR` real-time frame analysis
- **Pass Generation**: Off-screen HTML5 Canvas with `jsPDF` for badge output; `qrcodejs` for vector QR codes
- **Data Ingestion**: `PapaParse` for client-side attendee roster CSV import and export
- **Offline Storage**: Browser `IndexedDB` for local roster caching and offline scan queueing
- **Database & Auth**: Supabase (PostgreSQL 15+) with Row Level Security, PL/pgSQL stored procedures, and GoTrue Auth
- **Serverless API**: Supabase Edge Functions running on the Deno runtime

---

## Key Capabilities

### 1. High-Throughput Gate Validation
- Real-time camera viewfinder with automated barcode and QR detection.
- Sub-second validation feedback with visual and audio indicators for valid passes, duplicate scans, and revoked tickets.
- Support for manual token input, front/rear camera switching, and hardware flashlight toggle where supported.

### 2. Concurrency Control & Duplicate Prevention
- Check-ins run through an atomic database stored procedure (`check_in_ticket_rpc`) utilizing PostgreSQL row-level locks (`SELECT ... FOR UPDATE`).
- When multiple turnstiles scan the same pass simultaneously, only the first transaction commits; subsequent scans are immediately rejected with full details of the previous check-in (timestamp, station, and operator name).

### 3. Pass-Out & Re-Entry Tracking
- Scanners can switch between **Entrance** and **Exit** modes.
- Scanning an attendee in Exit mode marks their pass as temporarily checked out, enabling structured re-entry verification and re-entry counts when they return.

### 4. Offline Resilience
- The active event's attendee manifest is cached locally in browser `IndexedDB`.
- If network connectivity is lost, the scanner continues verifying tickets locally against the cached roster.
- Scans performed offline are queued and automatically synchronized to the cloud once connectivity is restored, with collision detection for scans recorded elsewhere during the outage.

### 5. Ticket Issuance & Delivery
- Single pass generation and batch CSV ingestion with automatic field mapping.
- Printable high-resolution landscape badges with event branding, attendee tier, barcode, and QR code.
- Cryptographic HMAC-SHA256 signature generation for tamper-evident verification.
- Direct digital ticket dispatch via transactional email (Brevo/Resend API), native mobile share sheets, and WhatsApp.
- Standard RFC 5545 `.ics` calendar invite generation.

### 6. Role-Based Access Control (RBAC)

The system enforces strict permission boundaries across four distinct roles:

| Capability | Master Admin | Event Admin | Ticketing Agent | Gate Scanner |
| :--- | :---: | :---: | :---: | :---: |
| Global event management (create, clone, archive) | Yes | Assigned only | Read-only | Read-only |
| 1-Click event duplication | Yes | No | No | No |
| Staff account provisioning & role assignment | All roles | Agents & Scanners | No | No |
| Self-service profile & password management | Yes | Yes | Yes | Yes |
| Ticket pass issuance (single & bulk CSV) | Yes | Yes | Yes | No |
| Attendee roster export (CSV) | Yes | Yes | Yes | No |
| Camera gate scanning & validation | Yes | Yes | No | Yes |
| Pass-out and re-entry tracking | Yes | Yes | No | Yes |
| Offline scan validation & auto-sync | Yes | Yes | No | Yes |
| Analytics & entrance audit logs | Global | Event-level | No | No |

---

## Getting Started

### Prerequisites

- A modern web browser supporting WebRTC and the Web Crypto API (Chrome, Safari, Firefox, Edge).
- A [Supabase](https://supabase.com) project (free tier is sufficient).

### 1. Database Setup

1. Open your Supabase project dashboard and navigate to the **SQL Editor**.
2. Open [`schema.sql`](schema.sql) in this repository and execute the script. This provisions:
   - Database tables (`events`, `app_users`, `tickets`, `audit_logs`, `gate_sessions`, `gate_login_failures`).
   - Row Level Security (RLS) policies.
   - Atomic stored procedures (`check_in_ticket_rpc`, `pass_out_ticket_rpc`, `clone_event_rpc`, `revoke_ticket_rpc`, `resolve_login_identifier`).
   - Realtime replication publications.

3. Create the initial Master Admin account:
   - In Supabase Dashboard, go to **Authentication > Users** and click **Add User** with a secure password (enable *Auto Confirm User*).
   - In the SQL Editor, execute:
     ```sql
     INSERT INTO public.app_users (id, username, email, role, full_name)
     SELECT id, 'admin', email, 'MASTER_ADMIN', 'Master Admin'
     FROM auth.users WHERE email = 'your-email@example.com'
     ON CONFLICT (id) DO UPDATE SET role = 'MASTER_ADMIN', status = 'ACTIVE';
     ```

### 2. Client Configuration

Update [`config.js`](config.js) with your Supabase credentials:

```javascript
const APP_CONFIG = {
    supabaseUrl: 'https://your-project-id.supabase.co',
    supabaseAnonKey: 'your-anon-publishable-key',
    version: '3.0.0',
    appName: 'IglooTickets',
    minPasswordLength: 8
};
```

### 3. Edge Functions Deployment (Optional)

Privileged staff management operations and transactional email delivery are handled via Supabase Edge Functions:

```bash
# Deploy staff administration service
supabase functions deploy staff-admin

# Deploy transactional email dispatcher (optional)
supabase functions deploy send-ticket-email
supabase secrets set BREVO_API_KEY="your-brevo-key"
```

### 4. Running the Application

Because IglooTickets is a static Progressive Web App, it requires no compilation step:

- **Local Development**: Serve the project root with any local HTTP server:
  ```bash
  npx serve .
  # or
  python -m http.server 8000
  ```
- **Production Deployment**: Deploy the directory to any static hosting provider (Vercel, Cloudflare Pages, Netlify, AWS S3 / CloudFront, GitHub Pages).

---

## Security Architecture

- **Row Level Security (RLS)**: Enforced across all tables. Anonymous clients have no direct table access; authenticated staff queries are filtered by assigned event IDs and role level.
- **Cryptographic Tokens**: Passes use 128-bit RFC 4122 v4 UUIDs generated via CSPRNG (`crypto.randomUUID` or `crypto.getRandomValues`). Optional HMAC-SHA256 signatures ensure tickets cannot be forged without the event signing secret.
- **Credential Storage**: Passwords and authentication credentials are handled exclusively by Supabase Auth (`auth.users`) and are never stored in application-level tables.
- **Formula Injection Mitigation**: CSV export functions sanitize cell inputs to prevent spreadsheet formula injection (`=`, `+`, `-`, `@`, `\t`, `\r`).
- **Input Sanitization**: Client rendering implements strict HTML escaping on all attendee-supplied and staff-supplied text.

---

## License

This project is open-source software licensed under the [MIT License](LICENSE).
