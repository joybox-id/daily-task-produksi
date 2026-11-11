# Daily Task Produksi · Joybox

Web untuk tim produksi Joybox. Karyawan mengisi **rencana kerja di pagi hari** dan **realisasi + foto bukti di sore hari**. Supervisor bisa melihat ringkasan per karyawan, estimasi jam kerja (*workload analysis*), grafik, dan estimasi hak lembur.

- **Web:** GitHub Pages (`index.html`, `config.js`)
- **Database & foto:** Supabase (`supabase/setup.sql`). Web hanya memanggil satu fungsi, `public.api`, dan tabelnya tidak bisa dibaca langsung dari luar.

## Cara hitung

| Komponen | Rumus |
|---|---|
| Waktu produktif | standar waktu per unit × qty (standar dari produk paling rumit per jenis) |
| Waktu kerja | waktu produktif ÷ efektivitas (default 80%) |
| Waktu tidak efektif | waktu kerja − waktu produktif |
| Total jam kerja | waktu kerja + istirahat (default 60 menit) |
| Estimasi hak lembur | total jam kerja − jam kerja normal (default 8 jam, sudah termasuk istirahat) |

Semua angka di atas, termasuk lama penyimpanan foto (default 90 hari), bisa diubah di menu **Pengaturan** di akun supervisor.

## Pemasangan

1. Buka [supabase.com](https://supabase.com), masuk dengan GitHub, lalu buat project baru (region Singapore, paket Free).
2. Buka **SQL Editor → New query**, tempel seluruh isi `supabase/setup.sql`, lalu klik **Run**. File ini aman dijalankan ulang.
3. Ambil **Project URL** dan **publishable/anon key** dari tombol **Connect** atau Project Settings → API, lalu isi ke `config.js`.
4. Aktifkan **GitHub Pages** di Settings → Pages → *Deploy from a branch* → `main` / `(root)`.

## Akun awal

| Username | Password awal | Peran |
|---|---|---|
| ulis | Ulis1234 | Karyawan |
| aul | Aul1234 | Karyawan |
| hana | Hana1234 | Karyawan |
| yuni | Yuni1234 | Karyawan |
| spv | Supervisor1234 | Supervisor |

Password disimpan dalam bentuk hash (bcrypt) dan sesi login berlaku 12 jam. Setelah login pertama, setiap akun diminta mengganti password.
