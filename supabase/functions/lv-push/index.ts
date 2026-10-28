// lv-push: sends Web Push notifications to the OTHER partner when a message is inserted.
// Called by the lv_notify() database trigger via pg_net, authenticated with the x-push-secret header.
//
// STATUS: this is the rotated version. It is NOT deployed yet. The deployed version (v1) still uses the
// old key pair. Deploy this only after the secret VAPID_PRIVATE_KEY has been added in
// Supabase Dashboard -> Edge Functions -> Secrets. The private key must never be written in this file.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

// Public key (safe to publish; it is also in src/index.html as VAPID).
const VAPID_PUBLIC = 'BGGAlYD5fJoQh7HEhKLLp4GvrMcFmD5KrCRTJgOCL5ir3LlNeK9GXvOXCGCuL89TR7wwP0hNmwY4IQgGezyRVkE';
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY');
const SUBJECT = 'https://our-question-game.vercel.app';

let ready = false;
if (VAPID_PRIVATE) {
  try {
    webpush.setVapidDetails(SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
    ready = true;
  } catch (_e) {
    ready = false; // key pair mismatch or malformed secret: fail closed
  }
}

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: cfg } = await sb.from('lv_cfg').select('v').eq('k', 'push_secret').single();
  if (!cfg || req.headers.get('x-push-secret') !== cfg.v) return new Response('no', { status: 401 });
  if (!ready) return new Response(JSON.stringify({ error: 'push key not configured' }), { status: 503, headers: { 'Content-Type': 'application/json' } });

  const m = await req.json();
  const { data: subs } = await sb.from('lv_push').select('endpoint,sub,preview').neq('uid', m.uid);
  let sent = 0;
  await Promise.all((subs || []).map(async (s) => {
    const body = m.kind === 'photo' ? '\u{1F4F7} Photo'
      : m.kind === 'voice' ? '\u{1F399}️ Voice note'
      : m.kind === 'q' ? 'Asked you a question'
      : (s.preview ? m.body : 'New message');
    try {
      await webpush.sendNotification(s.sub, JSON.stringify({ t: m.name || 'Us', b: body }), { TTL: 3600, urgency: 'high' });
      sent++;
    } catch (e) {
      // Only drop subscriptions the push service says are gone.
      if (e.statusCode === 404 || e.statusCode === 410) await sb.from('lv_push').delete().eq('endpoint', s.endpoint);
    }
  }));
  return new Response(JSON.stringify({ sent }), { headers: { 'Content-Type': 'application/json' } });
});
