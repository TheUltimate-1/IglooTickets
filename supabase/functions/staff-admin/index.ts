// Supabase Edge Function: staff-admin
// Creates / updates / resets / deletes staff accounts using the service role key.
// The caller's identity and role are verified server-side on every request.
//
// Deploy:  supabase functions deploy staff-admin
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const STAFF_ROLES = ["EVENT_ADMIN", "TICKETING_AGENT", "TICKET_SCANNER"];
const EVENT_ADMIN_MANAGEABLE = ["TICKETING_AGENT", "TICKET_SCANNER"];
const MIN_PASSWORD = 8;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const fail = (message: string, status = 400) => json({ success: false, message }, status);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail("Method not allowed", 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  let body: any;
  try { body = await req.json(); } catch { return fail("Invalid JSON body."); }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  // Unauthenticated action: Gate PIN login (works even when anonymous auth is disabled)
  if (body.action === "gate-login") {
    const eventCode = String(body.eventCode ?? "").trim().toUpperCase();
    const gatePin = String(body.gatePin ?? "").trim();
    if (!eventCode || !gatePin) return fail("Event code and Gate PIN are required.");

    const { data: event, error: eventErr } = await admin.from("events")
      .select("id, name, code, gate_pin, status")
      .eq("code", eventCode)
      .eq("status", "ACTIVE")
      .maybeSingle();

    if (eventErr || !event || event.gate_pin !== gatePin) {
      return fail("Invalid event code or PIN.");
    }

    // Deterministic scanner credentials for this event
    const scannerEmail = `gate_${event.code.toLowerCase()}_scanner@iglootickets.local`;
    const scannerPassword = `Gate_${event.gate_pin}_${event.id.replace(/-/g, "").slice(0, 12)}!`;

    let authUserId: string | null = null;
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: scannerEmail,
      password: scannerPassword,
      email_confirm: true,
      user_metadata: { role: "TICKET_SCANNER", event_id: event.id }
    });

    if (created?.user) {
      authUserId = created.user.id;
    } else {
      // If user already exists, update password to ensure sync
      const { data: userList } = await admin.auth.admin.listUsers({ perPage: 1000 });
      const match = userList?.users?.find((u: any) => u.email?.toLowerCase() === scannerEmail);
      if (match) {
        authUserId = match.id;
        await admin.auth.admin.updateUserById(match.id, { password: scannerPassword });
      } else {
        return fail("Could not establish gate session: " + (createErr?.message || "Auth error"));
      }
    }

    // Ensure staff profile in app_users
    await admin.from("app_users").upsert({
      id: authUserId,
      username: `gate_${event.code.toLowerCase()}`,
      email: scannerEmail,
      role: "TICKET_SCANNER",
      assigned_event_ids: [event.id],
      full_name: `Gate Scanner [${event.code}]`,
      status: "ACTIVE"
    }, { onConflict: "id" });

    // Ensure gate_sessions record for this user
    await admin.from("gate_sessions").upsert({
      user_id: authUserId,
      event_id: event.id,
      created_at: new Date().toISOString()
    }, { onConflict: "user_id" });

    return json({
      success: true,
      email: scannerEmail,
      password: scannerPassword,
      event: { id: event.id, name: event.name, code: event.code }
    });
  }

  // 1. Who is calling? (For administrative actions below)
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return fail("Not signed in.", 401);

  const { data: caller } = await admin
    .from("app_users").select("id, role, status, assigned_event_ids")
    .eq("id", userData.user.id).maybeSingle();

  if (!caller || caller.status !== "ACTIVE" || !["MASTER_ADMIN", "EVENT_ADMIN"].includes(caller.role)) {
    return fail("You are not allowed to manage staff.", 403);
  }
  const isMaster = caller.role === "MASTER_ADMIN";
  const callerEvents: string[] = caller.assigned_event_ids ?? [];

  const eventsAllowed = (ids: string[]) => isMaster || (ids.length > 0 && ids.every((id) => callerEvents.includes(id)));
  const cleanIds = (v: unknown): string[] =>
    Array.isArray(v) ? v.filter((x) => typeof x === "string" && /^[0-9a-f-]{36}$/i.test(x)) : [];

  // Load + authorize a target user for update/reset/delete
  const loadTarget = async (userId: string) => {
    if (typeof userId !== "string") return { error: fail("userId required.") };
    const { data: target } = await admin.from("app_users")
      .select("id, role, assigned_event_ids").eq("id", userId).maybeSingle();
    if (!target) return { error: fail("Staff account not found.", 404) };
    if (target.role === "MASTER_ADMIN" && target.id !== caller.id) return { error: fail("The Master Admin cannot be modified by others.", 403) };
    if (!isMaster) {
      const targetEvents: string[] = target.assigned_event_ids ?? [];
      if (
        !EVENT_ADMIN_MANAGEABLE.includes(target.role) ||
        targetEvents.length === 0 ||
        !targetEvents.every((id) => callerEvents.includes(id))
      ) {
        return { error: fail("You can only manage agents and scanners on your own events.", 403) };
      }
    }
    return { target };
  };

  try {
    switch (body.action) {
      case "create": {
        const username = String(body.username ?? "").trim().toLowerCase();
        const email = String(body.email ?? "").trim().toLowerCase();
        const password = String(body.password ?? "");
        const role = String(body.role ?? "");
        const fullName = String(body.fullName ?? "").trim();
        const events = cleanIds(body.assignedEventIds);

        if (!/^[a-z0-9._-]{3,32}$/.test(username)) return fail("Username must be 3-32 letters, numbers, dots, dashes or underscores.");

        // Staff email is optional. If not provided, generate an internal auth email
        const hasCustomEmail = Boolean(email && email.length > 0);
        if (hasCustomEmail && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
          return fail("Please enter a valid email address or leave it blank.");
        }
        const authEmail = hasCustomEmail ? email : `${username}@staff.iglootickets.internal`;

        if (password.length < MIN_PASSWORD) return fail(`Password must be at least ${MIN_PASSWORD} characters.`);
        if (!STAFF_ROLES.includes(role)) return fail("Invalid role.");
        if (!isMaster && !EVENT_ADMIN_MANAGEABLE.includes(role)) return fail("Event Admins can only create agents and scanners.", 403);
        if (!isMaster && events.length === 0) return fail("You must assign at least one of your events.", 400);
        if (!eventsAllowed(events)) return fail("You can only assign your own events.", 403);

        const { data: created, error: createErr } = await admin.auth.admin.createUser({
          email: authEmail, password, email_confirm: true,
        });
        if (createErr || !created?.user) return fail(createErr?.message ?? "Could not create account.");

        const { error: insErr } = await admin.from("app_users").insert({
          id: created.user.id,
          username,
          email: hasCustomEmail ? email : null,
          role,
          full_name: fullName || username,
          assigned_event_ids: events,
          status: "ACTIVE",
        });
        if (insErr) {
          await admin.auth.admin.deleteUser(created.user.id);
          return fail(insErr.message.includes("duplicate") ? "That username is already taken." : insErr.message);
        }
        return json({ success: true, id: created.user.id });
      }

      case "update": {
        const { target, error } = await loadTarget(body.userId);
        if (error) return error;
        const patch: Record<string, unknown> = {};
        if (typeof body.email === "string") {
          const cleanEmail = body.email.trim().toLowerCase();
          if (cleanEmail) {
            if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(cleanEmail)) return fail("Please enter a valid email address.");
            patch.email = cleanEmail;
          } else {
            patch.email = null;
          }
        }
        if (body.assignedEventIds !== undefined) {
          const ids = cleanIds(body.assignedEventIds);
          if (!isMaster && ids.length === 0) return fail("You must assign at least one of your events.", 400);
          if (!eventsAllowed(ids)) return fail("You can only assign your own events.", 403);
          patch.assigned_event_ids = ids;
        }
        if (body.role !== undefined) {
          if (!isMaster) return fail("Only the Master Admin can change roles.", 403);
          if (target!.role === "MASTER_ADMIN" || !STAFF_ROLES.includes(body.role)) return fail("Invalid role change.");
          patch.role = body.role;
        }
        if (body.status !== undefined) {
          if (!["ACTIVE", "REVOKED"].includes(body.status)) return fail("Invalid status.");
          if (target!.id === caller.id) return fail("You cannot change your own status.");
          patch.status = body.status;
        }
        if (patch.email !== undefined) {
          const authEmail = patch.email ? (patch.email as string) : `${target!.username}@staff.iglootickets.internal`;
          const { error: e } = await admin.auth.admin.updateUserById(target!.id, { email: authEmail, email_confirm: true });
          if (e) return fail(e.message);
        }
        const { error: upErr } = await admin.from("app_users").update(patch).eq("id", target!.id);
        if (upErr) return fail(upErr.message);
        if (patch.status === "REVOKED") await admin.auth.admin.signOut(target!.id as string).catch(() => {});
        return json({ success: true });
      }

      case "reset_password": {
        const { target, error } = await loadTarget(body.userId);
        if (error) return error;
        const password = String(body.password ?? "");
        if (password.length < MIN_PASSWORD) return fail(`Password must be at least ${MIN_PASSWORD} characters.`);
        const { error: e } = await admin.auth.admin.updateUserById(target!.id, { password });
        if (e) return fail(e.message);
        return json({ success: true });
      }

      case "delete": {
        const { target, error } = await loadTarget(body.userId);
        if (error) return error;
        if (target!.id === caller.id || target!.role === "MASTER_ADMIN") return fail("This account cannot be deleted.", 403);
        const { error: e } = await admin.auth.admin.deleteUser(target!.id);
        if (e) return fail(e.message);
        return json({ success: true });
      }

      default:
        return fail("Unknown action.");
    }
  } catch (err) {
    console.error(err);
    return fail("Unexpected server error.", 500);
  }
});
