# 🎟️ IglooTickets &bull; Security Audit & Phased Launch Roadmap

This document outlines the findings of the comprehensive security audit, bug analysis, and phased development roadmap for **IglooTickets (v3.0.0)** to prepare the platform for public commercial deployment.

---

## 🎯 Production Phasing Matrix

```mermaid
graph TD
    subgraph "Phase 1: Launch Security & Stability (Completed)"
        P1_1["DoS Fix on Gate PIN Authentication"]
        P1_2["Scanner Identity Spoofing Mitigation"]
        P1_3["Edge Function Role Scope Isolation"]
        P1_4["True Ticket Revocation with Audit Retention"]
        P1_5["Cryptographic UUID Token Generation"]
        P1_6["Offline Scan Conflict Logging"]
        P1_7["Chunked Bulk CSV Import & Roster Export"]
        P1_8["Canvas PDF Unicode Entity Fix"]
    end

    subgraph "Phase 2: Gate Security & Field Operations (Completed)"
        P2_1["Cryptographically Signed QR Tokens (HMAC-SHA256)"]
        P2_2["Daylight High-Contrast Anti-Glare Theme"]
    end

    subgraph "Phase 3: Attendee Ecosystem & Scale (Completed)"
        P3_1["Automated Email Dispatch (Resend) & RFC 5545 .ics Invites"]
        P3_2["Apple Wallet PassKit (.json) Integration"]
        P3_3["Gate Velocity & Bottleneck Monitoring Dashboard"]
        P3_4["Tier-Restricted & Station-Restricted Turnstiles"]
    end

    Phase 1 --> Phase 2 --> Phase 3
```

---

## 🛡️ Audit Findings & Implemented Fixes (Phase 1)

### 1. [CRITICAL] Gate PIN Denial-of-Service (DoS) Mitigation
* **Vulnerability**: `gate_login_rpc` counted failed PIN attempts globally by `event_code`. After 10 failed attempts, all authentication for that event code was locked for 10 minutes. An external adversary could brute-force bogus PINs and paralyze all entrance turnstiles during peak ingress hours.
* **Resolution**: Re-architected `gate_login_failures` to track attempts per `user_id` session. Device-level lockouts trigger after 5 consecutive failures without locking out legitimate turnstiles on other devices.

### 2. [HIGH] Scanner Identity Spoofing Neutralization
* **Vulnerability**: In `check_in_ticket_rpc` and `pass_out_ticket_rpc`, anonymous gate operators could pass an arbitrary `p_scanner_user` string, allowing an untrusted client to forge staff names (such as "Master Admin") in audit trails.
* **Resolution**: Verified server-side user resolution. If the caller has an active `app_users` record, their authenticated name is used. For anonymous gate sessions, the server binds the identity deterministically to `Gate Scanner [Gate Name]`.

### 3. [HIGH] Edge Function Access Control Enforcement
* **Vulnerability**: In `supabase/functions/staff-admin/index.ts`, Event Admin event boundary validation checked `ids.every(...)`. For users with empty event arrays (`[]`), `every()` evaluated to `true`, allowing Event Admins to manage or reset credentials for unassigned staff.
* **Resolution**: Enforced strict non-empty event validation (`ids.length > 0 && ids.every(...)`) and prevented Event Admins from modifying accounts outside their assigned events.

### 4. [HIGH] True Ticket Revocation Semantics
* **Vulnerability**: The UI previously executed a raw SQL `DELETE` when revoking tickets. This permanently deleted rows, broke historical audit logging, caused RLS permission errors for Ticketing Agents, and caused revoked passes to show up as "Unknown Ticket" rather than "TICKET REVOKED" at the gate.
* **Resolution**: Added `revoke_ticket_rpc` to set `status = 'REVOKED'`, log the event in `audit_logs`, and display prominent revocation warnings at gates. Row deletion is restricted to Master and Event Admins for test record removal.

### 5. [MEDIUM] Cryptographic Randomness for Ticket QR Tokens
* **Vulnerability**: `generateUUID()` relied on pseudo-random `Math.random()`, which is susceptible to seed inference.
* **Resolution**: Upgraded token generation to standard Web Crypto `crypto.randomUUID()` with fallback to `crypto.getRandomValues()`.

### 6. [MEDIUM] Canvas PDF Ticket Entity Rendering
* **Vulnerability**: `buildTicketCanvas` rendered the HTML entity `&bull;` directly onto the 2D canvas, outputting literal `&bull;` on exported PDF tickets.
* **Resolution**: Replaced with unicode bullet character `•` (`\u2022`).

### 7. [MEDIUM] Database Error Handling & Optimistic Event Updates
* **Vulnerability**: `handleCreateEventSubmit` fired asynchronous Supabase calls in the background without awaiting them, hiding RLS or duplicate key errors while notifying users of success.
* **Resolution**: Awaited database operations with proper loading states and error notifications.

### 8. [FUNCTIONAL] Attendee Roster CSV Export & Chunked Bulk Import
* **Enhancement**: Added full attendee list CSV export (`exportAttendeesCsv`) with check-in timestamps, gates, and statuses. Batch-chunked bulk attendee imports into 100-record transactions.

---

## ⚡ Implemented Phase 2 Features (Gate Operations & Cryptography)

### 1. Cryptographically Signed QR Tokens (HMAC-SHA256)
* **Design**: Every event maintains a private signing secret (`signing_secret` in database, with event-derived fallback).
* **Generation**: When issuing QR codes (in the Live Preview, QR Inspection Modal, and Canvas PDF Ticket), the QR payload embeds a compact HMAC signature formatted as `${ticket.token}.${signature}`.
* **Turnstile Verification**: When scanned at the gate, the engine separates the UUID from the cryptographic signature and computes `HMAC-SHA256(token + event_id, secret)`.
* **Zero-Latency Counterfeit Detection**: Forged or copied passes are rejected immediately with a distinct `FORGED / COUNTERFEIT PASS: CRYPTO MISMATCH` alert without database latency. Validated signed tickets display a verified security shield indicator.

### 2. Daylight High-Contrast Anti-Glare Theme
* **Design**: Dedicated turnstile theme switch optimized for outdoor festivals and bright daytime gates where mobile screen glare impedes readability.
* **Display**: Pure white high-contrast background, deep black typography, high-saturation status borders, and prominent text badges.
* **Persistence**: Saved to `localStorage` (`iglootickets_sunlight_mode`) so turnstile staff retain the high-contrast view across browser sessions and reloads.

---

## 🏢 Implemented Phase 3 Features (Attendee Ecosystem & Turnstile Velocity)

### 1. Gate Velocity & Bottleneck Monitoring Dashboard
* **Real-Time Throughput Engine**: Dynamically calculates rolling scan velocity (`scans/min`), peak throughput spikes, average processing pace (`sec/scan`), and active turnstile count.
* **Gate Station Load Distribution**: Interactive progress metrics for each station (Gate 1, Gate 2, VIP, Turnstiles), tracking scan volumes, percentage of total ingress, and error flags.
* **Intelligent Bottleneck Detection**: Automatically detects disproportionate load balance (>65% of volume converging on a single station) and alerts coordinators to redeploy staff to alternate turnstiles.
* **Ingress Arrival Curve**: Visual hourly histogram displaying admission influx curves across operational time blocks.

### 2. Tier-Restricted & Station-Restricted Turnstiles
* **Granular Access Control**: Organizers can specify authorized pass tiers per station (e.g. `Gate 2 (VIP / Media): VIP Platinum, Speaker / VIP`) in event settings.
* **Dual-Layer Enforcement**: Enforced both in the database via `check_in_ticket_rpc` and client-side during camera and manual lookups.
* **Directional Guidance**: When an attendee scans at an unauthorized gate, turnstiles present an amber restriction card displaying permitted passes and directing the attendee to the correct entrance.

### 3. Automated Email Dispatch (Resend) & RFC 5545 `.ics` Calendar Invites
* **Supabase Edge Function (`send-ticket-email`)**: Serverless transactional email pipeline integrating with Resend API for delivering branded HTML ticket passes, embedded QR tokens, and calendar invites.
* **Standards-Compliant iCalendar**: Generates RFC 5545 `.ics` calendar files downloadable with one click from ticket tables, QR modals, and email notifications.
* **One-Click Email Dispatch**: Staff can dispatch e-tickets directly to attendee email addresses from the Registry and QR inspection dialogs.

### 4. Apple Wallet (PassKit) & Digital Passes
* **PassKit Specification**: Generates valid Apple Wallet `eventTicket` JSON payloads (`pass.json`) formatted with primary, secondary, and auxiliary fields, RGB styling tokens, and ISO-8859-1 barcode payloads.
* **Instant Export**: Downloadable `.json` PassKit package ready for wallet pass distribution and compilation.

---

## 📋 Pre-Launch Verification Checklist

Before taking the system live for public events:
1. **Database Schema**: Execute [`schema.sql`](schema.sql) in the Supabase SQL Editor.
2. **Edge Functions**: Deploy both functions:
   - `supabase functions deploy staff-admin`
   - `supabase functions deploy send-ticket-email`
   *(Optional: configure `supabase secrets set RESEND_API_KEY=re_...` for automated email dispatch).*
3. **Admin Bootstrap**: Run the Master Admin bootstrap query in `schema.sql` with your production admin email.
4. **Service Worker**: Verify `sw.js` is registered and caches static assets for offline redundancy.
5. **Turnstile Testing**: Verify entry, duplicate rejection, tier restriction, pass-out, and re-entry across camera and manual lookup modes.
