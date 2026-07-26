const allowedOrigins = new Set([
  "https://piloz.fr",
  "https://www.piloz.fr",
  "http://localhost:3000",
  "http://localhost:5173",
]);

function cors(req: Request) {
  const origin = req.headers.get("origin") || "";
  return {
    "Access-Control-Allow-Origin": allowedOrigins.has(origin) ? origin : "https://piloz.fr",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(req: Request, data: unknown, status = 200, extra: HeadersInit = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors(req), "Content-Type": "application/json; charset=utf-8", ...extra },
  });
}

function clean(value: unknown, maxLength: number) {
  return String(value || "").replace(/\0/g, "").trim().slice(0, maxLength);
}

function html(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function sendWithFormSubmit(fields: {
  firstName: string;
  lastName: string;
  company: string;
  email: string;
  message: string;
  destination: string;
}) {
  const body = new FormData();
  body.set("Prénom", fields.firstName);
  body.set("Nom", fields.lastName);
  body.set("Entreprise", fields.company || "Non renseignée");
  body.set("Email", fields.email);
  body.set("Message", fields.message);
  body.set("_subject", `Nouveau contact Piloz — ${fields.company || `${fields.firstName} ${fields.lastName}`}`);
  body.set("_template", "table");
  body.set("_captcha", "false");
  const response = await fetch(`https://formsubmit.co/ajax/${fields.destination}`, {
    method: "POST",
    headers: {
      "Accept": "application/json",
      "Origin": "https://piloz.fr",
      "Referer": "https://piloz.fr/contact.html",
    },
    body,
  });
  if (!response.ok) return false;
  const result = await response.json().catch(() => ({}));
  return result?.success === true || result?.success === "true";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, { error: "Méthode non autorisée." }, 405);

  const contentLength = Number(req.headers.get("content-length") || 0);
  if (contentLength > 20_000) return json(req, { error: "Le message est trop volumineux." }, 413);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json(req, { error: "Le formulaire envoyé est invalide." }, 400);
  }

  // Champ invisible : une valeur indique généralement une soumission automatisée.
  if (clean(payload.website, 200)) return json(req, { sent: true });

  const firstName = clean(payload.first_name, 80);
  const lastName = clean(payload.last_name, 100);
  const company = clean(payload.company, 160);
  const email = clean(payload.email, 254).toLowerCase();
  const message = clean(payload.message, 5_000);

  if (firstName.length < 2 || lastName.length < 2) {
    return json(req, { error: "Renseignez votre prénom et votre nom." }, 400);
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
    return json(req, { error: "Renseignez une adresse e-mail valide." }, 400);
  }
  if (message.length < 10) {
    return json(req, { error: "Votre message doit contenir au moins 10 caractères." }, 400);
  }

  const destination = Deno.env.get("CONTACT_EMAIL") || "erp-piloz@outlook.com";
  const fullName = `${firstName} ${lastName}`;
  const subject = `Nouveau contact Piloz — ${company || fullName}`;
  const resendKey = Deno.env.get("RESEND_API_KEY");
  let sent = false;
  if (resendKey) {
    const providerResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: Deno.env.get("EMAIL_FROM") || "PILOZ <noreply@piloz.fr>",
        to: [destination],
        reply_to: email,
        subject,
        text: [
          `Prénom : ${firstName}`,
          `Nom : ${lastName}`,
          `Entreprise : ${company || "Non renseignée"}`,
          `E-mail : ${email}`,
          "",
          "Message :",
          message,
        ].join("\n"),
        html: `<h2>Nouveau message depuis piloz.fr</h2>
          <p><strong>Prénom :</strong> ${html(firstName)}<br>
          <strong>Nom :</strong> ${html(lastName)}<br>
          <strong>Entreprise :</strong> ${html(company || "Non renseignée")}<br>
          <strong>E-mail :</strong> <a href="mailto:${html(email)}">${html(email)}</a></p>
          <h3>Message</h3><p style="white-space:pre-wrap">${html(message)}</p>`,
      }),
    });
    sent = providerResponse.ok;
    if (!sent) console.error("[PILOZ Contact] Échec de Resend", { status: providerResponse.status });
  }

  if (!sent) sent = await sendWithFormSubmit({ firstName, lastName, company, email, message, destination });
  if (!sent) return json(req, { error: "Le message n’a pas pu être envoyé. Réessayez dans quelques instants." }, 502);

  return json(req, { sent: true });
});
