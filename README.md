# EventShield QR Enterprise &bull; Modern Event E-Ticketing System

A full-featured, zero-cost event e-ticketing and access control platform with cryptographic single-use QR codes, multi-role staff authentication, mobile camera scanning, bulk CSV imports, canvas-rendered PDF ticket generation, real-time cloud database synchronization, and progressive web app (PWA) offline scanning.

---

## 🚀 Quick Start (Instant Demo Mode)

No installation or server setup is required to start exploring.

1. Double-click `index.html` in your browser (Chrome, Edge, Safari, or Firefox).
2. The application opens immediately in **Demo Mode**, pre-populated with sample events, attendee passes, and staff accounts.
3. Use the **Quick 1-Click Role Switcher** at the top right to test all 4 user roles instantly:
   - 👑 **Master Admin** (`master_admin` / `password123`)
   - 🛡️ **Event Admin** (`event_admin` / `password123`)
   - 🎟️ **Ticketing Agent** (`agent_marcus` / `password123`)
   - 📱 **Gate Scanner** (`gate_scanner` / `password123` or PIN: Code `TECH26`, PIN `7788`)

---

## ✨ What's New in v2.6.0

### 1. 🛡️ Security & Database Hardening
* **PostgreSQL RPC Functions**: Atomic validation and check-in procedures (`check_in_ticket_rpc`, `pass_out_ticket_rpc`, `clone_event_rpc`) execute server-side in a single transaction, locking down direct client manipulation of tickets.
* **Anti-Brute-Force Rate Limiting**: Automatic lockout cooldowns on repeated failed gate PIN inputs or rapid manual token searches.

### 2. ⚡ 1-Click Event Cloning
* Master Admins can duplicate any existing event with one click.
* Inherits custom ticket tiers, gate PIN, and venue capacity while assigning a new name, unique event code, and date.

### 3. 👥 Live Venue Capacity Headcount Meter
* Real-time headcount progress bar tracking:
  $$\text{Current Occupancy} = \text{Total Checked-In} - \text{Total Passed-Out}$$
* Displayed in both the top navigation bar and the gateway scanner station with visual safety alerts (🟢 Normal Flow, ⚠️ Near Capacity, ⛔ Full Capacity).

### 4. 🔄 Pass-Out & Re-Entry Tracking
* **Entrance Mode**: Checks in valid passes, blocks duplicate scans with historical time/gate details, or verifies return passes (`RE_ENTRY`).
* **Exit Mode**: Scanner can be switched to "Exit (Pass-Out)" with 1 tap. Scanning an attendee marks them as temporarily exited (`CHECKED_OUT`), decrementing the venue headcount and enabling seamless re-entry verification later.

### 5. 📶 Offline Pre-Cache & Background Sync (`IndexedDB`)
* The active event's attendee roster is pre-cached directly into browser `IndexedDB`.
* If venue cellular connectivity drops during entrance rush hours, the scanner validates tickets locally with **zero latency**.
* Scans performed offline are queued in `IndexedDB` and automatically synchronized to Supabase the moment connectivity is restored.

### 6. 📱 Progressive Web App (PWA) & Asset Caching
* Complete `manifest.json` and Service Worker (`sw.js`).
* Gate operators can "Add to Home Screen" on iOS & Android for a fullscreen native app experience.
* Core application shell and CDN dependencies (Tailwind, FontAwesome, jsQR, etc.) are cached for 100% offline startup.

---

## 👥 Role Hierarchy & Access Matrix

| Feature | Master Admin | Event Admin | Ticketing Agent | Gate Scanner |
| :--- | :---: | :---: | :---: | :---: |
| **Manage Multiple Events** *(Add, clone, archive)* | ✅ All Events | ❌ | ❌ | ❌ |
| **1-Click Event Cloning** | ✅ | ❌ | ❌ | ❌ |
| **Event Switcher Dropdown** | ✅ Global | ✅ Assigned Events | ❌ | ❌ |
| **Staff & User Management** *(Add user, reset password/PIN)* | ✅ All Users | ✅ Event Staff | ❌ | ❌ |
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

## ⚡ 100% Free Cloud Database Setup (Supabase Realtime)

To sync scans and ticket issuances across multiple devices in real-time (e.g. mobile scanners at venue gates and ticketing agents at laptop desks):

### Step 1: Create a Free Supabase Project
1. Go to [supabase.com](https://supabase.com) and sign up for a free account.
2. Click **New Project**, choose any name (e.g., `EventShield`), set a database password, and select your nearest region.

### Step 2: Run the SQL Schema
1. In your Supabase project dashboard, click **SQL Editor** on the left menu.
2. Open `schema.sql` from this repository.
3. Paste the entire script into the SQL Editor and click **Run**.
4. This sets up the tables, RPC stored procedures (`check_in_ticket_rpc`, `pass_out_ticket_rpc`, `clone_event_rpc`), indexes, and realtime broadcast publications.

### Step 3: Connect EventShield
1. In your Supabase dashboard, click **Project Settings (gear icon) &rarr; API** (or **Data API**).
2. Copy your **Project URL** and your **Publishable API key** (also called **anon public key**).
3. In `config.js`, update `supabaseUrl` and `supabaseAnonKey` (or click the cloud icon in `index.html` to save via the Database Setup Modal).
4. Your system is now connected to a live PostgreSQL cloud database with instant realtime multi-device sync!

---

## 📱 Mobile Scanner Usage & Free HTTPS Hosting

Modern mobile browsers (iOS Safari, Android Chrome) require **HTTPS** or `localhost` to access the camera hardware (`getUserMedia`). 

### Free 1-Click Hosting Options:
* **GitHub Pages (Free)**:
  1. Push this repository to GitHub: `https://github.com/TheUltimate-1/IglooTickets.git`.
  2. In repository settings, go to **Pages &rarr; Source &rarr; Deploy from branch `main`**.
  3. You get a free HTTPS link (e.g., `https://theultimate-1.github.io/IglooTickets/`). Open this on your mobile phone to scan passes at the gate!
* **Vercel or Netlify (Free)**:
  1. Import the GitHub repository into [Vercel](https://vercel.com) or [Netlify](https://netlify.com).
  2. Automatic deployment with free HTTPS on every git push.

---

## 🎫 Single-Use Anti-Duplicate Security Details

* **Cryptographic Tokens**: Each pass is assigned a random 128-bit RFC4122 v4 UUID embedded in a QR code.
* **Atomic First Scan**: On first scan, status flips to `CHECKED_IN`, recording the timestamp, scanner staff name, and entrance gate (e.g., *Gate 1*, *VIP Lane*).
* **Duplicate Rejection Alert**: Any subsequent scan of a checked-in pass triggers an immediate loud error buzzer, a flashing red warning, and displays the exact initial check-in time, gate location, and scanner staff name.
* **Concurrency Protection**: Even if two turnstiles scan the exact same QR code in the same millisecond, the database executes an atomic conditional check—only one succeeds, and the other is instantly flagged as a duplicate.
