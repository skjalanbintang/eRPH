// eRPH SKJB — hantar Web Push apabila notifikasi dicipta (dipanggil oleh pg_net, dilindungi x-push-secret)
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

Deno.serve(async (req) => {
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const rahsia = async (n: string) => (await admin.rpc("rahsia_pelayan", { p_nama: n })).data as string | null;
  const secret = await rahsia("push_secret");
  if (!secret || req.headers.get("x-push-secret") !== secret) return new Response("forbidden", { status: 403 });

  const { id } = await req.json();
  const { data: n } = await admin.from("notifikasi").select("*").eq("id", id).single();
  if (!n || n.dibaca) return new Response("skip");

  const [pub, priv] = await Promise.all([rahsia("vapid_public"), rahsia("vapid_private")]);
  webpush.setVapidDetails("https://skjalanbintang.github.io/erph/", pub!, priv!);

  const { data: subs } = await admin.from("push_subs").select("*").eq("user_id", n.user_id);
  const payload = JSON.stringify({ title: n.tajuk, body: n.mesej, url: n.pautan, tag: n.kunci });
  let ok = 0, gagal = 0;
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification(s.sub, payload, { TTL: 86400 });
      ok++;
    } catch (e) {
      gagal++;
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await admin.from("push_subs").delete().eq("id", s.id);
    }
  }));
  return new Response(JSON.stringify({ ok, gagal }), { headers: { "Content-Type": "application/json" } });
});
