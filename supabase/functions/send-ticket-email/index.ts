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

const fail = (message: string, status = 200, extra: Record<string, unknown> = {}) =>
  json({ success: false, message, ...extra }, status);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail("Method not allowed", 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  // Resend default sandbox sender requires onboarding@resend.dev unless a custom domain is verified
  const emailFrom = Deno.env.get("EMAIL_FROM") || "IglooTickets <onboarding@resend.dev>";

  // 1. Authenticate caller
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return fail("Authentication session expired. Please sign in again to dispatch emails.", 200);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return fail("Invalid JSON payload.", 200);
  }

  const { ticketId, token, recipientEmail, signedPayload, icsContent, eventId } = body || {};

  const emailOk = typeof recipientEmail === "string" && recipientEmail.length <= 254 &&
    /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/.test(recipientEmail.trim());
  if (!emailOk) {
    return fail("A valid recipient email address is required.", 200);
  }
  if (typeof ticketId !== "string" && typeof token !== "string") {
    return fail("Ticket ID or pass token is required.", 200);
  }

  // 2. Only active staff (Master Admin, Event Admin, Ticketing Agent) may dispatch emails
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: caller } = await admin
    .from("app_users").select("role, status, assigned_event_ids")
    .eq("id", userData.user.id).maybeSingle();
  if (!caller || caller.status !== "ACTIVE" ||
      !["MASTER_ADMIN", "EVENT_ADMIN", "TICKETING_AGENT"].includes(caller.role)) {
    return fail("Permission denied: your account role is not allowed to dispatch ticket emails.", 200);
  }

  // Resolve ticket: try UUID id, then token
  let ticketRecord: any = null;
  if (typeof ticketId === "string" && /^[0-9a-f-]{36}$/i.test(ticketId)) {
    const { data } = await admin.from("tickets")
      .select("id, event_id, token, attendee_name, tier, status")
      .eq("id", ticketId).maybeSingle();
    ticketRecord = data;
  }
  if (!ticketRecord && typeof token === "string" && token.trim()) {
    const { data } = await admin.from("tickets")
      .select("id, event_id, token, attendee_name, tier, status")
      .eq("token", token.trim()).maybeSingle();
    ticketRecord = data;
  }

  if (ticketRecord && ticketRecord.status === "REVOKED") {
    return fail("This ticket has been revoked and cannot be emailed.", 200);
  }

  const targetEventId = ticketRecord?.event_id || (typeof eventId === "string" && /^[0-9a-f-]{36}$/i.test(eventId) ? eventId : null);
  const callerEvents: string[] = caller.assigned_event_ids ?? [];
  if (caller.role !== "MASTER_ADMIN" && targetEventId && !callerEvents.includes(targetEventId)) {
    return fail("You do not have administrative access to this event.", 200);
  }

  // Fetch event record
  let eventRecord: any = null;
  if (targetEventId) {
    const { data } = await admin.from("events")
      .select("name, date, location, logo_url, brand_color")
      .eq("id", targetEventId).maybeSingle();
    eventRecord = data;
  }

  const clean = (v: unknown) => String(v ?? "").replace(/[\r\n]+/g, " ").slice(0, 200);
  const displayAttendee = clean(ticketRecord?.attendee_name || body.attendeeName) || "Attendee";
  const displayEvent = clean(eventRecord?.name || body.eventName) || "Event";
  const displayTier = clean(ticketRecord?.tier || body.tier) || "Standard Pass";
  const displayToken = String(ticketRecord?.token || token || "").trim();
  const eventDate = clean(eventRecord?.date || body.eventDate);
  const eventLocation = clean(eventRecord?.location || body.eventLocation);
  const logoUrl = typeof eventRecord?.logo_url === "string" && /^https?:\/\//i.test(eventRecord.logo_url) ? eventRecord.logo_url.slice(0, 500) : null;
  const brandColor = typeof eventRecord?.brand_color === "string" && /^#[0-9a-fA-F]{6}$/.test(eventRecord.brand_color) ? eventRecord.brand_color : "#0284c7";

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
      to: [recipientEmail.trim()],
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
      const rawMsg = resData?.message || resData?.error || res.statusText || "Resend error";
      let hint = "";
      if (typeof rawMsg === "string" && rawMsg.includes("testing emails")) {
        hint = " (In Resend trial mode without a custom domain, you can only send test emails to your registered Resend account email).";
      } else if (typeof rawMsg === "string" && rawMsg.includes("domain")) {
        hint = " (Please verify your sending domain at resend.com/domains or use onboarding@resend.dev).";
      }
      return fail(`Resend API: ${rawMsg}${hint}`, 200, { details: resData });
    }

    return json({
      success: true,
      configured: true,
      provider: "resend",
      emailId: resData.id,
      recipient: recipientEmail
    });
  } catch (err: any) {
    return fail(`Email dispatch failed: ${err.message || String(err)}`, 200);
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
