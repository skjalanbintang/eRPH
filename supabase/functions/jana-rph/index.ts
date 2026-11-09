// eRPH SKJB — jana RPH dengan Gemini (kunci disimpan dalam skema private)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const j = (o: unknown) => new Response(JSON.stringify(o), { headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: u } = await user.auth.getUser();
    if (!u?.user) return j({ error: "Sila log masuk semula." });

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: key } = await admin.rpc("rahsia_pelayan", { p_nama: "gemini_key" });
    if (!key) return j({ tiada_kunci: true });

    const { prompt } = await req.json();
    if (!prompt || String(prompt).length > 12000) return j({ error: "Prompt tidak sah." });
    const { data: st } = await admin.from("settings").select("ai_model").eq("id", 1).single();
    const model = st?.ai_model || "gemini-3.8-flash";

    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({
        contents: [{ parts: [{ text: String(prompt) }] }],
        generationConfig: { responseMimeType: "application/json", temperature: 0.7 },
      }),
    });
    const g = await r.json();
    if (!r.ok) return j({ error: g?.error?.message || `Ralat Gemini ${r.status}` });
    const text = (g.candidates?.[0]?.content?.parts ?? []).map((p: { text?: string }) => p.text ?? "").join("");
    return j({ text, model });
  } catch (e) {
    return j({ error: String((e as Error)?.message ?? e) });
  }
});
