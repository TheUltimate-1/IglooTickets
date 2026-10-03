# 🎟️ IglooTickets Enterprise &bull; High-Performance Event E-Ticketing & Mobile Scanner

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2FTheUltimate-1%2FIglooTickets)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.6.1-emerald.svg)](config.js)
[![PWA Ready](https://img.shields.io/badge/PWA-Ready-purple.svg)](manifest.json)
[![Database: Supabase](https://img.shields.io/badge/Database-Supabase%20PostgreSQL-3ECF8E.svg)](schema.sql)

**IglooTickets** is a lightweight, zero-cost, enterprise-grade event e-ticketing and access control platform. It features cryptographic single-use QR codes, multi-role staff authentication, camera hardware scanning with anti-duplicate flash alerts, bulk CSV imports, canvas-rendered PDF ticket issuance, real-time PostgreSQL database synchronization, and full offline scanning with automated background sync.

---

## ⚡ 1-Click Instant Deployment (Vercel)

Click the button below to fork and deploy IglooTickets directly onto **Vercel** with full Edge CDN acceleration and zero server maintenance:

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2FTheUltimate-1%2FIglooTickets)

### Manual Vercel Deployment Steps:
1. Log in to [Vercel](https://vercel.com).
2. Click **Add New... &rarr; Project**.
3. Import your GitHub repository: `TheUltimate-1/IglooTickets`.
4. Click **Deploy**. Vercel will automatically detect the static project and deploy it within seconds with edge HTTPS.

---

## 🚀 Quick Start (Instant Demo Mode)

No backend configuration or local build steps are required.

1. Clone the repository:
   ```bash
   git clone https://github.com/TheUltimate-1/IglooTickets.git
   cd IglooTickets
   ```
2. Open `index.html` in your browser (Chrome, Safari, Edge, Firefox).
3. The application runs immediately in **Demo Mode**, pre-configured with default events and staff accounts.
4. Test all 4 user roles instantly using the top-right **Quick 1-Click Role Switcher**:
   - 👑 **Master Admin** (`nethil` or `nethil2008@gmail.com` / `Qwerty123`)
   - 🛡️ **Event Admin** (`event_admin` / `password123`)
   - 🎟️ **Ticketing Agent** (`agent_marcus` / `password123`)
   - 📱 **Gate Scanner** (`gate_scanner` / `password123` or PIN: Code `TECH26`, PIN `7788`)

---

## ✨ Key Enterprise Features

### 1. 🛡️ Database Hardening & Row Locks
* **PostgreSQL Atomic RPCs**: High-throughput validation and check-in procedures (`check_in_ticket_rpc`, `pass_out_ticket_rpc`, `clone_event_rpc`) execute server-side with `FOR UPDATE` row-level locks, eliminating race conditions when multiple turnstiles scan simultaneously.
* **Safe Search Paths & SQL Defenses**: All stored procedures enforce `SET search_path = public, pg_temp` to neutralize search path injection vulnerabilities.
* **CSV Injection Sanitization**: All attendee and log exports escape spreadsheet formula triggers (`=`, `+`, `-`, `@`, `\t`, `\r`).

### 2. ⚡ 1-Click Event Cloning
* Duplicate any active event with a single click.
* Inherits custom ticket tiers, gate PIN, and venue capacity while generating a fresh event code, name, and schedule.

### 3. 👥 Live Venue Capacity Headcount Meter
* Real-time venue headcount tracking:
  $$\text{Current Occupancy} = \text{Total Checked-In} - \text{Total Passed-Out}$$
* Displayed dynamically in both the top navigation bar and gateway scanner station with visual safety alerts (🟢 Normal Flow, ⚠️ Near Capacity, ⛔ Full Capacity).

### 4. 🔄 Pass-Out & Re-Entry Tracking
* **Entrance Mode**: Checks in valid passes, blocks duplicate scans with historical time/gate details, or verifies return passes (`RE_ENTRY`).
* **Exit Mode**: Scanner can be toggled to "Exit (Pass-Out)" with 1 tap. Scanning an attendee marks them as temporarily exited (`CHECKED_OUT`), decrementing the venue headcount and enabling seamless re-entry verification later.

### 5. 📶 Offline Pre-Cache & Background Sync (`IndexedDB`)
* The active event's attendee roster is pre-cached directly into browser `IndexedDB`.
* If venue cellular connectivity drops during entrance rush hours, the scanner validates tickets locally with **zero latency**.
* Scans performed offline are queued and automatically synchronized to Supabase the moment connectivity is restored.

### 6. 📱 Progressive Web App (PWA) & Asset Caching
* Complete `manifest.json` and Service Worker (`sw.js`).
* Gate operators can "Add to Home Screen" on iOS & Android for a fullscreen native app experience.
* Core application shell and CDN dependencies (Tailwind, FontAwesome, jsQR, etc.) are cached for 100% offline startup.

### 7. 👤 User Profile Management & Self-Service Password Reset
* **Self-Service Profile Edit**: All users can edit their profile (Full Name, Email) and change their own password directly via the in-app modal.
* **Self-Service Forgot Password**: Direct self-reset from the login modal allows account password recovery by username or email.
* **Administrative Staff Directory**: Admins can edit staff profiles, modify roles, assign events, and reset credentials.

---

## 👥 Role Hierarchy & Access Matrix

| Feature | Master Admin | Event Admin | Ticketing Agent | Gate Scanner |
| :--- | :---: | :---: | :---: | :---: |
| **Manage Multiple Events** *(Add, clone, archive)* | ✅ All Events | ❌ | ❌ | ❌ |
| **1-Click Event Cloning** | ✅ | ❌ | ❌ | ❌ |
| **Event Switcher Dropdown** | ✅ Global | ✅ Assigned Events | ❌ | ❌ |
| **Staff & User Management** *(Add user, reset password/PIN)* | ✅ All Users | ✅ Event Staff | ❌ | ❌ |
| **Edit Staff Profiles & Roles** | ✅ All Staff | ✅ Event Staff | ❌ | ❌ |
| **Self-Service Profile Edit & Password Reset** | ✅ | ✅ | ✅ | ✅ |
| **Issue Individual Passes & Custom Tiers** | ✅ | ✅ | ✅ | ❌ |
| **Bulk CSV Attendee Import** | ✅ | ✅ | ✅ | ❌ |
| **Download PDF Tickets & Badges** | ✅ | ✅ | ✅ | ❌ |
| **View Full Registered Attendee Details** | ✅ | ✅ | ✅ | ❌ |
| **Mobile Gateway QR Scanner (Camera & File)** | ✅ | ✅ | ❌ | ✅ |
| **Pass-Out & Re-Entry Tracking (Exit Mode)** | ✅ | ✅ | ❌ | ✅ |
| **Offline IndexedDB Validation & Auto-Sync** | ✅ | ✅ | ❌ | ✅ |
| **Live Venue Capacity Headcount Meter** | ✅ | ✅ | ❌ | ✅ |
| **Anti-Duplicate Flash & Audit Log** | ✅ | ✅ | ❌ | ✅ |
| **Real-time Analytics & CSV Export** | ✅ Global & Event | ✅ Event-Level | ❌ | ❌ |

---

## ⚡ Supabase Cloud Database Configuration

IglooTickets is pre-configured to connect to Supabase out-of-the-box via `config.js`. If you wish to connect your own independent Supabase instance:

### Step 1: Create a Free Supabase Project
1. Go to [supabase.com](https://supabase.com) and create a project.
2. Set your project name and database password.

### Step 2: Run the SQL Schema
1. In your Supabase dashboard, click **SQL Editor** on the left menu.
2. Open [`schema.sql`](schema.sql) from this repository.
3. Paste the entire script into the SQL Editor and click **Run**.
4. This creates tables, atomic RPC procedures, security indexes, row-level locks, and Realtime publications.

### Step 3: Connect Your Project
1. In your Supabase dashboard, go to **Project Settings &rarr; API**.
2. Copy your **Project URL** and **Anon Public Key**.
3. Paste them into `config.js` or configure them dynamically in the in-app **Cloud Database Setup** modal.

---

## 🎫 Single-Use Anti-Duplicate Security Details

* **Cryptographic Tokens**: Each pass is assigned a random 128-bit RFC4122 v4 UUID embedded in a QR code.
* **Atomic First Scan**: On first scan, status flips to `CHECKED_IN`, recording the timestamp, scanner staff name, and entrance gate (e.g., *Gate 1*, *VIP Lane*).
* **Duplicate Rejection Alert**: Any subsequent scan of an already-used pass triggers an immediate error tone, flashing red UI warning, and shows the exact previous check-in time, gate location, and scanner staff name.
* **Concurrency Protection**: Even if two turnstiles scan the exact same QR code in the same millisecond, the database executes an atomic `FOR UPDATE` conditional row lock—only one succeeds, and the other is flagged instantly.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
