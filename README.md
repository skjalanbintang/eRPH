# eRPH SKJB

Sistem Rancangan Pengajaran Harian untuk **SK Jalan Bintang, Miri**.
Laman: https://skjalanbintang.github.io/erph/

## Ciri utama
- **Guru:** jadual waktu, borang RPH lengkap, janaan AI (Gemini) untuk satu RPH atau **RPH sehari**, hantar satu/semua, tarik balik, refleksi, cetak/PDF.
- **Pentadbir:** semakan dengan ulasan (Sahkan / Minta Pembetulan / Ulasan), sahkan pukal, **tarikh akhir** (peraturan lalai + tarikh khas ikut minggu, sekat atau tanda lewat), pemantauan + CSV, daftar guru (seorang / pukal), set semula kata laluan, hebahan.
- **Notifikasi:** loceng dalam aplikasi (masa nyata) + **notifikasi push telefon/komputer** (PWA). Peringatan automatik kepada guru yang belum lengkap pada 7 pagi & 8 malam.

## Seni bina
- `index.html` — aplikasi satu fail (Supabase JS dari CDN).
- `sw.js`, `manifest.json`, ikon — PWA & push.
- `supabase/migrations/` — skema, RLS, trigger notifikasi, pg_cron.
- `supabase/functions/jana-rph` — panggil Gemini (kunci di pelayan).
- `supabase/functions/hantar-push` — Web Push (dipanggil oleh pg_net).

Projek Supabase: `erph-skjb` (ap-southeast-1).

## Aktifkan AI
Pentadbir → **Tetapan → Janaan AI** → tampal kunci dari https://aistudio.google.com/apikey.

## iPhone
Notifikasi push di iPhone hanya berfungsi selepas eRPH ditambah ke Skrin Utama (Kongsi → Tambah ke Skrin Utama).
