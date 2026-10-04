// Supabase Edge Function: send-ticket-email
// Sends transactional HTML ticket passes with embedded QR payloads and RFC 5545 .ics calendar attachments.
// Supported email providers: Resend API (via RESEND_API_KEY secret)
//
// Deploy: supabase functions deploy send-ticket-email
// Set secret: supabase secrets set RESEND_API_KEY=re_your_api_key

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const fail = (message: string, status = 400, extra: Record<string, unknown> = {}) =>
  json({ success: false, message, ...extra }, status);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail("Method not allowed", 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  const emailFrom = Deno.env.get("EMAIL_FROM") || "IglooTickets <tickets@resend.dev>";

  // 1. Authenticate caller
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return fail("Not signed in.", 401);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return fail("Invalid JSON payload.");
  }

  const { ticketId, token, recipientEmail, signedPayload, icsContent } = body || {};

  const emailOk = typeof recipientEmail === "string" && recipientEmail.length <= 254 &&
    /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/.test(recipientEmail);
  if (!emailOk) {
    return fail("Valid recipient email is required.");
  }
  if (typeof ticketId !== "string" && typeof token !== "string") {
    return fail("ticketId or token is required.");
  }

  // 2. Only active issuing staff with access to the ticket's event may send
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: caller } = await admin
    .from("app_users").select("role, status, assigned_event_ids")
    .eq("id", userData.user.id).maybeSingle();
  if (!caller || caller.status !== "ACTIVE" ||
      !["MASTER_ADMIN", "EVENT_ADMIN", "TICKETING_AGENT"].includes(caller.role)) {
    return fail("You are not allowed to send tickets.", 403);
  }

  const ticketQuery = admin.from("tickets")
    .select("id, event_id, token, attendee_name, tier, status");
  const { data: ticketRecord } = await (typeof ticketId === "string"
    ? ticketQuery.eq("id", ticketId)
    : ticketQuery.eq("token", token)).maybeSingle();
  if (!ticketRecord) return fail("Ticket not found.", 404);

  const eventIds: string[] = caller.assigned_event_ids ?? [];
  if (caller.role !== "MASTER_ADMIN" && !eventIds.includes(ticketRecord.event_id)) {
    return fail("You do not have access to this event.", 403);
  }
  if (ticketRecord.status === "REVOKED") {
    return fail("This ticket has been revoked and cannot be sent.", 409);
  }

  const { data: eventRecord } = await admin.from("events")
    .select("name, date, location, logo_url, brand_color").eq("id", ticketRecord.event_id).maybeSingle();
  if (!eventRecord) return fail("Event not found.", 404);

  // Everything shown in the email comes from the database, not from the request.
  const clean = (v: unknown) => String(v ?? "").replace(/[\r\n]+/g, " ").slice(0, 200);
  const displayAttendee = clean(ticketRecord.attendee_name) || "Attendee";
  const displayEvent = clean(eventRecord.name) || "Event";
  const displayTier = clean(ticketRecord.tier) || "Standard Pass";
  const displayToken = ticketRecord.token;
  const eventDate = clean(eventRecord.date);
  const eventLocation = clean(eventRecord.location);
  const logoUrl = typeof eventRecord.logo_url === "string" && /^https?:\/\//i.test(eventRecord.logo_url) ? eventRecord.logo_url.slice(0, 500) : null;
  const brandColor = typeof eventRecord.brand_color === "string" && /^#[0-9a-fA-F]{6}$/.test(eventRecord.brand_color) ? eventRecord.brand_color : "#0284c7";

  // The client signs the QR payload; accept it only if it wraps this ticket's token.
  const qrData = typeof signedPayload === "string" && signedPayload.startsWith(displayToken) &&
    signedPayload.length <= displayToken.length + 40 ? signedPayload : displayToken;
  const safeIcs = typeof icsContent === "string" && icsContent.startsWith("BEGIN:VCALENDAR") &&
    icsContent.length <= 10000 ? icsContent : null;

  // If Resend API key is not configured, inform the user cleanly
  if (!resendApiKey) {
    return json({
      success: false,
      configured: false,
      message: "RESEND_API_KEY secret is not set in Supabase. Run 'supabase secrets set RESEND_API_KEY=re_...' to enable direct email dispatch.",
      previewHtml: generateTicketEmailHtml(displayAttendee, displayEvent, eventDate, eventLocation, displayTier, displayToken, qrData, logoUrl, brandColor)
    });
  }

  // 3. Dispatch via Resend
  try {
    const emailHtml = generateTicketEmailHtml(displayAttendee, displayEvent, eventDate, eventLocation, displayTier, displayToken, qrData, logoUrl, brandColor);
    const attachments: Array<{ filename: string; content: string }> = [];

    if (safeIcs) {
      // Base64 encode the .ics content
      const enc = new TextEncoder();
      const icsBytes = enc.encode(safeIcs);
      let binary = "";
      for (let i = 0; i < icsBytes.byteLength; i++) {
        binary += String.fromCharCode(icsBytes[i]);
      }
      attachments.push({
        filename: `${displayEvent.replace(/[^a-zA-Z0-9]/g, "_")}_Invite.ics`,
        content: btoa(binary)
      });
    }

    const resendPayload: any = {
      from: emailFrom,
      to: [recipientEmail],
      subject: `Your E-Ticket Pass: ${displayEvent} (${displayTier})`,
      html: emailHtml,
    };

    if (attachments.length > 0) {
      resendPayload.attachments = attachments;
    }

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(resendPayload)
    });

    const resData = await res.json();
    if (!res.ok) {
      return fail(`Resend API error: ${resData?.message || res.statusText}`, 502, { details: resData });
    }

    return json({
      success: true,
      configured: true,
      provider: "resend",
      emailId: resData.id,
      recipient: recipientEmail
    });
  } catch (err: any) {
    return fail(`Email dispatch failed: ${err.message || String(err)}`, 500);
  }
});

function generateTicketEmailHtml(
  attendee: string,
  event: string,
  date: string,
  location: string,
  tier: string,
  token: string,
  qrText: string,
  logoUrl?: string | null,
  brandColor?: string | null
): string {
  const qrUrl = `https://api.qrserver.com/v1/create-qr-code/?size=240x240&data=${encodeURIComponent(qrText)}`;
  const accent = brandColor && /^#[0-9a-fA-F]{6}$/.test(brandColor) ? brandColor : "#0284c7";
  const logoHtml = logoUrl
    ? `<div style="margin-bottom: 12px;"><img src="${escapeHtml(logoUrl)}" alt="${escapeHtml(event)} Logo" style="max-height: 44px; max-width: 180px; object-fit: contain; vertical-align: middle;"></div>`
    : "";

  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Your E-Ticket: ${escapeHtml(event)}</title>
</head>
<body style="margin: 0; padding: 24px; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #0b0f19; color: #f1f5f9;">
  <div style="max-width: 520px; margin: 0 auto; background-color: #111827; border-radius: 20px; border: 1px solid #374151; overflow: hidden; box-shadow: 0 20px 40px rgba(0,0,0,0.6);">
    <!-- Header with custom branding -->
    <div style="background: linear-gradient(135deg, ${accent}, #0f172a); padding: 28px 24px; text-align: center; border-bottom: 1px solid rgba(255,255,255,0.1);">
      ${logoHtml}
      <h1 style="margin: 0; font-size: 20px; font-weight: 700; color: #ffffff; letter-spacing: -0.5px;">${escapeHtml(event)}</h1>
      <p style="margin: 6px 0 0 0; font-size: 13px; color: #e0e7ff; opacity: 0.9;">Official Digital Admission Pass</p>
    </div>

    <!-- Ticket Body -->
    <div style="padding: 24px;">
      <div style="background-color: #1f2937; border-radius: 14px; padding: 16px; border: 1px solid #374151; margin-bottom: 20px;">
        <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
          <tr>
            <td style="color: #9ca3af; padding-bottom: 8px;">Attendee:</td>
            <td style="color: #ffffff; font-weight: 600; text-align: right; padding-bottom: 8px;">${escapeHtml(attendee)}</td>
          </tr>
          <tr>
            <td style="color: #9ca3af; padding-bottom: 8px;">Pass Tier:</td>
            <td style="color: ${accent}; font-weight: 700; text-align: right; padding-bottom: 8px;">${escapeHtml(tier)}</td>
          </tr>
          <tr>
            <td style="color: #9ca3af; padding-bottom: 8px;">Date:</td>
            <td style="color: #ffffff; text-align: right; padding-bottom: 8px;">${escapeHtml(date || "Scheduled Event")}</td>
          </tr>
          <tr>
            <td style="color: #9ca3af;">Venue:</td>
            <td style="color: #ffffff; text-align: right;">${escapeHtml(location || "Main Venue")}</td>
          </tr>
        </table>
      </div>

      <!-- QR Code Section -->
      <div style="text-align: center; background-color: #ffffff; border-radius: 16px; padding: 20px; margin: 0 auto; max-width: 260px; box-shadow: 0 4px 12px rgba(0,0,0,0.2);">
        <img src="${qrUrl}" alt="Ticket QR Code" width="220" height="220" style="display: block; margin: 0 auto; border-radius: 8px;">
        <p style="margin: 10px 0 0 0; font-family: monospace; font-size: 11px; color: #4b5563; word-break: break-all;">${escapeHtml(token.slice(0, 18))}...</p>
      </div>

      <!-- Verification Instructions -->
      <div style="margin-top: 24px; padding: 14px; background-color: #0f172a; border-radius: 12px; border: 1px solid #1e293b; text-align: center;">
        <p style="margin: 0; font-size: 12px; color: #94a3b8; line-height: 1.5;">
          Present this QR code on your mobile device at any turnstile entrance. Single-use cryptographic security is verified at the gate.
        </p>
      </div>
    </div>

    <!-- Footer -->
    <div style="padding: 14px 24px; background-color: #0b0f19; border-top: 1px solid #1f2937; text-align: center; font-size: 11px; color: #64748b;">
      Powered by IglooTickets &bull; Secure Turnstile & E-Ticketing System
    </div>
  </div>
</body>
</html>`;
}

function escapeHtml(str: string): string {
  if (!str) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}
