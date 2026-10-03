# EventShield QR Enterprise &bull; Modern Event E-Ticketing System

A full-featured, zero-cost event e-ticketing and access control platform with cryptographic single-use QR codes, multi-role staff authentication, mobile camera scanning, bulk CSV imports, canvas-rendered PDF ticket generation, and real-time cloud database synchronization.

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

## 👥 Role Hierarchy & Access Matrix

| Feature | Master Admin | Event Admin | Ticketing Agent | Gate Scanner |
| :--- | :---: | :---: | :---: | :---: |
| **Manage Multiple Events** *(Add, edit, archive)* | ✅ All Events | ❌ | ❌ | ❌ |
| **Event Switcher Dropdown** | ✅ Global | ✅ Assigned Events | ❌ | ❌ |
| **Staff & User Management** *(Add user, reset password/PIN)* | ✅ All Users | ✅ Event Staff | ❌ | ❌ |
| **Issue Individual Passes & Custom Tiers** | ✅ | ✅ | ✅ | ❌ |
| **Bulk CSV Attendee Import** | ✅ | ✅ | ✅ | ❌ |
| **Download PDF Tickets & Badges** | ✅ | ✅ | ✅ | ❌ |
| **View Full Registered Attendee Details** | ✅ | ✅ | ✅ | ❌ |
| **Mobile Gateway QR Scanner** | ✅ | ✅ | ❌ | ✅ |
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
2. Open `schema.sql` from this folder (or click **Copy SQL Schema** in the app's Database Modal).
3. Paste the entire script into the SQL Editor and click **Run**.
4. This automatically creates the `events`, `app_users`, `tickets`, and `audit_logs` tables with indexes, RLS policies, and realtime broadcast publications.

### Step 3: Connect EventShield
1. In your Supabase dashboard, click **Project Settings (gear icon) &rarr; API** (or **Data API**).
2. Copy your **Project URL** and your **Publishable API key** (also called **anon public key**).
3. In `index.html`, click the cloud icon (or `Demo Mode` badge) in the top bar to open the **Database Setup Modal**.
4. Paste your Project URL and Publishable/Anon Key, then click **Connect & Save**.
5. Your system is now connected to a live PostgreSQL cloud database with instant realtime multi-device sync!

---

## 📱 Mobile Scanner Usage & Free HTTPS Hosting

Modern mobile browsers (iOS Safari, Android Chrome) require **HTTPS** or `localhost` to access the camera hardware (`getUserMedia`). 

### Free 1-Click Hosting Options:
* **GitHub Pages (Free)**:
  1. Push this folder to a GitHub repository.
  2. In repository settings, go to **Pages &rarr; Source &rarr; Deploy from branch `main`**.
  3. You get a free HTTPS link (e.g., `https://yourusername.github.io/qr-tickets/`). Open this on your mobile phone to scan passes at the gate!
* **Vercel or Netlify (Free)**:
  1. Drag and drop this folder into [Netlify Drop](https://app.netlify.com/drop) or deploy via Vercel CLI.
  2. Free automatic HTTPS domain provided in seconds.

---

## 🎫 Single-Use Anti-Duplicate Security Details

* **Cryptographic Tokens**: Each pass is assigned a random 128-bit RFC4122 v4 UUID embedded in a QR code.
* **Atomic First Scan**: On first scan, status flips to `CHECKED_IN`, recording the timestamp, scanner staff name, and entrance gate (e.g., *Gate 1*, *VIP Lane*).
* **Duplicate Rejection Alert**: Any subsequent scans trigger an immediate loud error buzzer, a flashing red warning, and display the exact initial check-in time and gate location.
* **Spotty Wi-Fi Resilience**: Mobile scanners cache the attendee roster locally. If venue Wi-Fi drops momentarily, the scanner continues validating tickets against the cache and pushes check-ins to Supabase once connectivity is restored.
