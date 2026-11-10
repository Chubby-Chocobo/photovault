---
description: PhotoVault 1.0 specification, copied verbatim from GitHub issue #1 (source of truth for FR/NFR codes)
source: https://github.com/Chubby-Chocobo/photovault/issues/1
---

# PhotoVault — Spec bản 1.0 (bản rút gọn cho GitHub issue)
 
> macOS menu-bar app dùng cá nhân. Bundle ID `com.annh.photovault` (cố định — quyền TCC gắn với bundle ID).
> **[VERIFY]** = giả định chưa kiểm chứng: xác minh bằng tài liệu chính thức hoặc spike M0; kết luận ghi vào `docs/spikes/` hoặc `docs/decisions/`.
> Mã FR giữ nguyên như spec đầy đủ (`photovault-spec.md`).
 
## 1. Bối cảnh & ràng buộc
 
Chức năng tương tự Dropbox Camera Uploads: **iPhone → iCloud Photos → Photos trên Mac → PhotoVault → Google Drive (+ NAS/ổ ngoài)**. Chọn Mac vì iOS không cho app bên thứ ba chạy nền liên tục.
 
- Photos ở chế độ **Optimize Mac Storage**: phần lớn bản gốc chỉ có trên iCloud.
- Thư viện **lớn hơn nhiều lần** dung lượng trống của ổ Mac; không dùng SSD ngoài cho library.
- Có ảnh/video import từ máy ảnh và drone (RAW Sony/Nikon/Canon/Leica/DJI, video vài GB).
- Google: **Gmail cá nhân** (OAuth External → bắt buộc Production mode). iCloud ADP tắt. Không có Apple Developer trả phí.
- Owner chấp nhận chưa có bản sao off-site thứ hai.
## 2. Mục tiêu / phi mục tiêu
 
**Mục tiêu:**
1. Backup bản gốc + bản chỉnh sửa lên Google Drive và 0..n thư mục local/NAS, với rule nội dung riêng cho từng đích.
2. Layout: mỗi ngày một thư mục `YYYY-MM-DD` trong từng nhánh (`Camera Uploads`, `Screenshots`, `Saved`); thư mục ngày của ảnh chụp có tên địa danh khi đủ điều kiện (sửa đổi 2026-11-09, issue #12, quyết định 0023).
3. Sidecar JSON + XMP; trên Drive có view bằng shortcut: `By device`, `By place`, `Favorites` và `By lens` (mặc định tắt).
4. Lần chạy đầu chọn: toàn bộ / từ một ngày / chỉ ảnh mới.
5. Không upload trùng, kể cả khi mất DB hoặc library bị rebuild. Chịu được crash, sleep, mất mạng, NAS bị ngắt.
6. Không làm đầy ổ Mac.
7. Phát hiện backup bị mất; không im lặng.
8. Quyền tối thiểu: Photos (không Full Disk Access), `drive.file` cho đích backup; nhập Google Drive thêm `drive.readonly` (chỉ đọc, quyết định 0030); Dropbox chỉ đọc; chỉ thư mục hoặc file do owner chọn.
9. Nhiều nguồn, cùng một cách tổ chức: Photos là nguồn liên tục duy nhất (sửa đổi 2026-11-10, quyết định 0029); có thể nhập một lần từ một thư mục trên Mac, Google Drive hoặc Dropbox (sửa đổi 2026-11-10, quyết định 0026). Cơ chế để thêm nguồn liên tục sau này được thiết kế nhưng chưa làm, xem [continuous-source-extension](../architecture/continuous-source-extension.md) (sửa đổi 2026-11-09, issue #17, quyết định 0024).
**Phi mục tiêu:**
- **Không bao giờ xoá dữ liệu backup** ở bất kỳ đích nào. Không sync hai chiều. Không sửa Photos library.
- Không làm: Google Photos, S3, OneDrive, mã hoá phía client, backend, telemetry, phân phối. (Nguồn liên tục ngoài Photos, gồm Dropbox và Drive của tài khoản Google khác: không làm, để sau ở §15; sửa đổi 2026-11-10, quyết định 0029. Nhập một lần từ Dropbox và Google Drive: quyết định 0026.)
- Không hỗ trợ nhiều library Photos.
## 3. Thuật ngữ
 
| Thuật ngữ | Nghĩa |
|---|---|
| Asset / Resource | Một `PHAsset` / một `PHAssetResource` |
| Primary resource | RAW nếu là cặp RAW+JPEG; ngược lại `.photo` hoặc `.video` |
| Asset key | `c:<cloudId>` hoặc `l:<localId>` — khoá ổn định (8.1); `x:<sha256>` cho file nhập từ thư mục (quyết định 0024) |
| Nguồn | Nơi asset đến: `photos` (liên tục, chính) hoặc một lần nhập `folder-<uuid>` (`asset.source_id`) |
| Import job | Một lần nhập một thư mục: `scanning` → `importing` → `completed`, hoặc `offline` / `cancelled` |
| Kind | `original` · `edited` · `sidecarJson` · `sidecarXmp` |
| Đích | `googleDrive` (đúng 1) · `localFolder` (0..n) |
| Category | `camera` · `screenshot` · `saved` (lưu từ app chat/web) |
| Placement | Category + ngày lưu trữ + `name_stem`, chốt **một lần** cho mỗi asset |
| Archive timezone | Múi giờ cố định để tính ngày/tên (FR-07) |
| Baseline | Change token + thời điểm bắt đầu |
 
## 4. Yêu cầu chức năng
 
### 4.1 Onboarding & cấu hình
 
**FR-01 Onboarding**, đúng thứ tự:
1. Đăng nhập Google.
2. Quyền Photos.
3. Chọn thư mục gốc Drive (mặc định `Camera Uploads`). Thấy root cũ có `appProperties.pvRoot=1` → hỏi dùng lại hay tạo mới; dùng lại thì đánh dấu cần khôi phục (FR-51).
4. Archive timezone.
5. Sync mode.
6. Notification.
7. (Tuỳ chọn) thêm NAS.
8. Tóm tắt: số asset, dung lượng từng đích, dung lượng Mac. Nếu dưới ngưỡng backfill, nói thẳng "cần giải phóng X GB".
9. Bấm **Bắt đầu** → chốt baseline (FR-15) → scan (FR-10) → khôi phục (FR-51) → mới upload.
**FR-02** OAuth Authorization Code + PKCE, mở trình duyệt mặc định, redirect loopback `127.0.0.1:<port>`. Scope: `drive.file`, `openid`, `email`.
 
**FR-03** Refresh token chỉ lưu trong Keychain.
 
**FR-04** `PHPhotoLibrary.requestAuthorization(for: .readWrite)`. Bị từ chối → hướng dẫn mở System Settings, dừng pipeline.
 
**FR-05 Settings** (mặc định):
 
| Setting | Mặc định |
|---|---|
| Video, bản chỉnh sửa, mọi khung burst | Bật (trần toàn cục) |
| Album Hidden | **Tắt** (vẫn scan) |
| Rate export backfill | 20 GB/giờ |
| Backfill chỉ khi cắm sạc | Bật |
| Mọi upload chỉ khi cắm sạc | Tắt |
| Dừng khi mạng expensive | Bật |
| `lowWatermark` / `criticalWatermark` | 15 / 5 GB |
| Staging (giới hạn mềm) | 4 GB |
| Launch at login | Bật |
| Album app chat | WhatsApp, Zalo, Messenger, Telegram, Viber, LINE, Signal, Instagram, Facebook, Threads, X, TikTok |
| Ảnh thiếu EXIF máy ảnh → `saved` | Bật |
| Địa danh | Bật (`vi`, quốc gia nhà `VN`) |
| Sidecar JSON / XMP | Bật / Bật |
| 3 view | Bật |
| Kiểm tra toàn vẹn | 7 ngày |
 
**FR-06 Sync mode** (phạm vi của đích Drive; chi tiết 8.8): `full` / `since(D)` / `newOnly`.
- Hiển thị số asset cho từng lựa chọn; không dùng private API để ước tính dung lượng.
- Ghi chú trên UI: "Ảnh mới = ảnh xuất hiện trong Photos trên Mac sau thời điểm này, kể cả ảnh cũ import sau".
- Mở rộng phạm vi → enqueue thêm. Thu hẹp → huỷ theo asset, chỉ khi **mọi** job của asset ở đích đó còn `pending`/`deferred`. Không xoá gì ở đích.
**FR-07 Archive timezone** = múi giờ máy lúc onboarding, lưu cố định. Đổi trong Settings chỉ áp dụng cho asset chưa đặt.
 
**FR-08 Tài khoản & thư mục gốc:**
- Đổi tên root = `files.update name`.
- Đổi root hoặc đổi tài khoản → xác nhận → reset trạng thái đích Drive → FR-51 nếu đích mới có dữ liệu → chạy lại.
- Đăng xuất → revoke + xoá Keychain; DB giữ nguyên. Đăng nhập lại bằng user ID khác = đổi tài khoản.

**FR-117 Bắt đầu lại (factory reset, quyết định 0025):** Settings › Nâng cao › "Đặt lại từ đầu…" (xác nhận). App đăng xuất Google (xoá Keychain, revoke nếu có mạng), ghi dấu `factory-reset-requested` rồi tự mở lại. Tiến trình mới giữ khoá instance (đợi tối đa 15 giây khoá của tiến trình cũ), trước khi mở DB xoá hết dữ liệu trong thư mục dữ liệu (DB, staging, bản sao DB, log, lịch sử thông báo) và xoá dấu sau cùng; giữ ngôn ngữ giao diện và `drive-daily-cap.json` (Google tính hạn mức ngày theo tài khoản). Crash giữa chừng: lần mở sau làm tiếp. Không đụng gì ở Drive/NAS; owner tự chuyển thư mục backup cũ vào Thùng rác nếu không muốn dùng lại. Nếu không tự mở lại được, app báo việc đặt lại sẽ hoàn tất ở lần mở tiếp theo.
### 4.2 Phát hiện thay đổi
 
**FR-10 Scan metadata** (không export):
- Fetch **mọi** asset với `includeHiddenAssets = true` và `includeAllBurstAssets = true`; ghi `is_hidden`/`burst_identifier`, chỉ không tạo job khi setting tắt. Nhờ vậy, sau khi tra alias/cloud ID, "không có trong DB" luôn nghĩa là **asset vào library sau baseline**.
- Có `scan_state` (`notStarted`/`running`/`complete`) + cursor; resumable. Không xử lý incremental khi scan chưa `complete`.
- macOS 27+: `prefetchAssetExtendedMetadata` [VERIFY].
**FR-11** Backfill chỉ chạy khi scan `complete`; mới nhất trước; incremental luôn được ưu tiên.
 
**FR-12 Incremental** = `fetchPersistentChanges(since:)`.
- Mỗi `PHPersistentChange` là một transaction riêng, commit kèm token của chính change đó. Transaction chỉ thao tác DB — không I/O tới PhotoKit resource hay mạng.
- Asset bị xoá → chỉ ghi `deleted_at`. [VERIFY] availability, cấu trúc change details, lỗi khi token hết hạn.
**FR-13 Reconciliation** (token hết hạn, hoặc owner bấm):
1. Chạy FR-53 trước.
2. Liệt kê mọi asset: không có trong DB → `inserted_at = now`, tạo job theo eligibility; không còn trong library → `deleted_at`.
3. Asset còn lại: cập nhật `is_hidden`/`is_favorite`; `modificationDate` khác → `edit_check_pending` + làm mới sidecar.
4. Dựng lại `album_member`; lưu token mới.
**FR-14 Trigger:** change observer (debounce 30–60 giây), `NSBackgroundActivityScheduler` 60 phút, nút "Sync now", lúc khởi động, wake, có mạng lại, mount volume.
 
**FR-15 Baseline** khi bấm Bắt đầu: lấy token → lưu `baseline_token`, `change_token`, `destination.baseline_at` của Drive → rồi mới scan. Asset được scan có `inserted_at = NULL`. Change "inserted" sau baseline ghi `inserted_at` (kể cả với asset scan đã ghi).
 
### 4.3 Phạm vi, phân loại, resource
 
**FR-19 Phạm vi:** mọi asset trong system library.
- Burst: upload mọi khung (setting).
- Hidden: không upload (setting).
- iCloud Shared Library: có [VERIFY].
- Shared Albums: không [VERIFY].
- Bật setting làm rộng phạm vi → enqueue từ DB theo eligibility, không scan lại.
**FR-20 Category** — "Saved from <app>" không có API công khai, nên dùng heuristic theo thứ tự:
 
| # | Điều kiện | Kết quả |
|---|---|---|
| 1 | `mediaSubtypes` ∋ `.photoScreenshot` (+ screen recording cho video [VERIFY]) | `screenshot` |
| 2 | Thuộc user album có tên khớp **chính xác** (không phân biệt hoa thường, trim) danh sách app chat | `saved` |
| 3 | **Ảnh**, không có cả `TIFF Make` lẫn `TIFF Model`, không có resource RAW | `saved` |
| 4 | Còn lại | `camera` |
 
- Category **chính thức ngay lúc scan** cho: quy tắc 1, quy tắc 2, mọi video, asset có RAW.
- Chỉ ảnh còn lại mới có category tạm `camera` và cần **classify**: `requestData` primary → `CGImageSourceCreateIncremental` → đọc xong TIFF properties thì `cancelDataRequest` [VERIFY M0-5]. Nếu buộc phải tải hết file thì giữ file trong staging để upload luôn.
- Chỉ classify khi asset có thể được ít nhất một đích cần, dưới `camera` **hoặc** `saved`.
- **Không export resource nào khác trước khi chốt placement.**
- Category đổi → tính lại tập đích hai chiều (thêm và huỷ job) + tính lại đếm ngày.
- Quy tắc 3 không áp dụng cho video (tránh xếp video drone vào `saved`). Rủi ro: ảnh scan có thể vào `saved` — ghi README.
- Đổi rule phân loại chỉ áp dụng cho asset chưa đặt.
**FR-21 Resource:**
 
| Resource | Upload |
|---|---|
| `.photo`, `.alternatePhoto` | luôn |
| `.pairedVideo` | luôn (thuộc nhóm "Ảnh") |
| `.video` | nếu video bật |
| `.fullSizePhoto`, `.fullSizePairedVideo` | nếu bản chỉnh sửa bật |
| `.fullSizeVideo` | nếu bản chỉnh sửa + video bật |
| `.adjustmentData` | không upload; chỉ làm cổng kiểm tra chỉnh sửa (FR-46) |
| Loại khác (`.adjustmentBase*`, `.photoProxy`…) | không; ghi log |
 
- "RAW" xác định theo UTI (`public.camera-raw-image`), không theo resource type.
- [VERIFY M0-1b] mapping với file thật `.ARW`, `.NEF`, `.CR3`, `.DNG`, DJI.
**FR-22** Giữ nguyên file gốc byte-for-byte; không convert, không strip metadata.
 
**FR-23 Lỗi export** — bộ đếm duy nhất ở `resource.export_attempts`:
- Lỗi item → retry với backoff. Quá 8 lần → các job chờ resource đó chuyển `deferred` (ghi `deferred_since` **chỉ khi đang NULL**), thử lại mỗi 24 giờ; quá 30 ngày → `skipped`.
- Lỗi vĩnh viễn → `skipped` ngay. Lỗi mức đích không tính (8.14).
### 4.4 Export & staging
 
**FR-30** `PHAssetResourceManager.requestData(...)`, `isNetworkAccessAllowed = true`. App tự ghi từng chunk, tính MD5 + SHA-256 trong lúc stream (không đọc lại file), giữ request ID để `cancelDataRequest`. `writeData` chỉ là dự phòng [VERIFY].
 
**FR-31 Disk guard:**
- Kiểm tra trước khi export và mỗi 256 MB; chạm `criticalWatermark` → huỷ request, xoá file dở, resource về `none`, `disk_cancel_count++` (không tính lỗi).
- Chỉ bắt đầu export mới khi staging + đang ghi < 4 GB. Ngoại lệ: staging rỗng và không có export nào → luôn cho **một** export. Quyết định qua một actor duy nhất.
- Không có API kích thước trước → phát hiện bằng quan sát: sau 2 lần huỷ mà `bytes_received_at_cancel + free lúc bắt đầu < critical + 5 GB` → `deferred(tooLargeForDisk)`, ngoài chu trình 30 ngày; chỉ thử lại khi free ≥ kích thước đã biết + 5 GB, hoặc owner bấm thử lại.
**FR-32** Dọn staging theo 8.9.3; khởi động thì xoá file mồ côi.
 
**FR-33** Rule "bỏ qua > X GB" áp dụng khi đang stream; mọi đích cần file đều đã vượt → huỷ sớm.
 
**FR-34** Đọc metadata chỉ từ primary resource:
- ImageIO: Make, Model, LensModel, DateTimeOriginal, OffsetTime.
- AVFoundation: `com.apple.quicktime.make/model` [VERIFY].
- Lưu vào `asset`; không đọc được thì để trống, không phải lỗi job.
### 4.5 Layout & tên (mọi đích)
 
**FR-40 Cấu trúc:**
- `camera`: `<Root>/Camera Uploads/YYYY-MM-DD[ <Địa danh>]/` — mọi ngày có ảnh đều có thư mục riêng. Ngày có ảnh ở nhiều tỉnh/thành được tách thành mỗi tỉnh một thư mục `YYYY-MM-DD <Địa danh>` (trừ FR-81: hai nhóm cùng tên dùng chung một thư mục; nhóm không tên, hộp bao > 300 km, dùng chung thư mục không tên) (FR-81, FR-83) (sửa đổi 2026-11-10, issue #27, quyết định 0028).
- `<Root>/Screenshots/YYYY-MM-DD/` và `<Root>/Saved/YYYY-MM-DD/`: không địa danh.
- Tên root mặc định: `PhotoVault`.
- Không có ngày → `Unknown date/` trong từng nhánh.
- `By device/`, `By place/`, `Favorites/` (chỉ Drive) là view, không chứa file thật.
- Mọi file của một asset nằm cùng một thư mục (vì dùng placement đã chốt).
**FR-41 Tên file:** `name_stem = YYYY-MM-DD HH.mm.ss_<originalStem>`.
- `originalStem` lấy từ primary resource; đuôi file lấy từ chính resource đó (giữ hoa/thường; rỗng thì suy từ UTI).
- Edited: ` (edited)` + đuôi theo UTI (không dùng `FullSizeRender`).
- Sidecar: `<stem>.json`, `<stem>.xmp`. Không có ngày: `undated_<stem>`.
- Ví dụ: `2026-11-08 14.03.22_IMG_4821.HEIC/.MOV`, `… (edited).HEIC`, `2026-11-08 09.15.40_DSC01234.ARW/.JPG`.
**FR-42 Chuẩn hoá:**
- NFC. Thay `/ \ : * ? " < > |` và ký tự điều khiển bằng `_`; bỏ dấu chấm/khoảng trắng cuối.
- Giới hạn theo **byte UTF-8**, cắt ở ranh giới grapheme: `originalStem` ≤ 120 byte, mỗi thành phần đường dẫn ≤ 240 byte.
- `name_stem` cấp phát **một lần cho mỗi asset**, dùng chung mọi đích. Duy nhất theo `(placement_category, placement_day, lower(nfc(stem)))`; trùng thì thêm ` (1)`, ` (2)`…
### 4.6 Google Drive
 
**FR-43 appProperties:**
- File: `pvAssetId` (vượt giới hạn 124 byte cho key+value [VERIFY] → `h:` + 32 hex đầu của SHA-256), `pvResType`, `pvKind`, `pvCategory`, `pvSchema=1`.
- Thư mục và shortcut: `pvSchema`, `pvLogical` (đường dẫn logic; dài thì hash), `pvView`; shortcut thêm `pvAssetId`. Phục vụ khôi phục (8.15).
- `description` dạng "Camera: … · Lens: … · Place: …", cập nhật khi tên thiết bị/địa danh đổi.
**FR-44 Upload resumable:**
- Chunk là bội số 256 KiB (mặc định 8 MiB). File ID sinh trước, ghi vào job **trước** khi tạo session. Resume bằng `PUT Content-Range: bytes */N` → `308`.
- Session mất hoặc hết hạn → **trước tiên** `files.get(id, md5Checksum, trashed)`: khớp → `done`; khác → `files.update` media; chưa có → session mới, cùng ID.
- Staging mất mà session còn → export lại, so `session_md5`; khớp thì resume.
- Mọi create/update/move yêu cầu `fields=id,md5Checksum,trashed,parents`.
- [VERIFY] thời hạn session; có cần header `Authorization` (mặc định cứ gửi).
**FR-45 Checksum:** `done` chỉ khi `md5Checksum` khớp. Lệch → `files.update` media trên **cùng ID**, tối đa 3 lần → `skipped(checksumMismatch)`. Thử lại vẫn trên cùng ID; không bao giờ tạo file thứ hai.
 
**FR-46 Bản chỉnh sửa:**
- Không bao giờ ghi đè file gốc. Tối đa một file edited cho mỗi loại resource edited.
- **Cổng kiểm tra** (worker riêng, ngoài transaction; transaction chỉ đặt `edit_check_pending`):
  1. `PHAsset.hasAdjustments` false và trước đó cũng false → bỏ qua.
  2. Băm `.adjustmentData` (vài KB), so `adjustment_hash`; không đổi → không export.
  3. Đổi → tăng `content_gen` → export → MD5 khác → `files.update` media file edited (chưa có thì tạo).
- [VERIFY M0-2] `.adjustmentData` dùng được ở chế độ Optimize; fallback = so `modificationDate` + export, có rate limit.
- Revert trong Photos → giữ file edited.
- Không bật `keepRevisionForever`; README ghi bản edited cũ có thể mất sau ~30 ngày [VERIFY].
**FR-47 Thư mục & toàn vẹn:**
- `generateIds` (`type=files` cho file/thư mục, `type=shortcuts` cho shortcut) → ghi ID vào DB → tạo. Gặp "đã tồn tại" → `files.get` kiểm tra (`parents`/`targetId`/MD5), không mặc nhiên coi là thành công [VERIFY M0-3].
- Tạo thư mục qua một actor tuần tự hoá theo đích.
- Mỗi chu kỳ: `files.get` root. Root bị xoá/trash → `paused(rootMissing|rootTrashed)` + hỏi owner ("Tôi đã khôi phục" / "Upload lại vào thư mục mới"). **Không tự tạo lại root.**
- Thư mục backup con: kiểm tra `trashed` lần đầu dùng trong phiên **và** qua response của mọi lệnh ghi.
  - Trash → `paused(folderTrashed)`, xoá cờ đã kiểm tra của chuỗi cha, hỏi owner.
  - `404` → xoá cache cả nhánh logic, tạo lại khi cần, đánh dấu file trong nhánh `missingRemote`, báo owner.
- **Thư mục view** không chịu luật tạm dừng: bị trash hoặc `404` → xoá cache, shortcut bên trong thành `userRemoved`.
- Tuỳ chọn "Khôi phục giúp tôi": `trashed=false` cho item do app tạo.
- Kiểm tra toàn vẹn (7 ngày, hoặc nút): list item của app, so DB → `missingRemote`, báo số lượng; owner xác nhận mới upload lại.
**FR-48 Dung lượng:** Drive `about.get storageQuota` [VERIFY với `drive.file`]; local đọc dung lượng volume. Kiểm tra mỗi 6 giờ khi backfill; < 5% hoặc < 5 GB → cảnh báo; hết chỗ → `paused(full)`.
 
**FR-49 Giới hạn:**
- Upload Drive ≤ 700 GB / 24 giờ trượt → `paused(dailyCapReached)`.
- Token bucket chung cho **mọi lệnh ghi** Drive (create, update, move, shortcut, metadata); lệnh metadata/view ưu tiên thấp hơn upload; tốc độ chốt sau M0-3.
### 4.7 Định danh & khôi phục
 
- **FR-50** Asset key (8.1).
- **FR-51 Khôi phục từ đích** — bắt buộc khi DB rỗng mà đích có dữ liệu, khi dùng lại root, khi thêm lại NAS cũ (có `.photovault/destination.json`), hoặc owner bấm. **Chỉ chạy khi scan `complete`.** Thuật toán 8.15; trong lúc đó đích không nhận upload.
- **FR-118 Bố cục cũ (0.1.0), quyết định 0025:** không migration và không bao giờ di chuyển hay xoá dữ liệu ở đích ("sync lại, không migrate").
  - *DB cũ:* khi mở, nếu bất kỳ `upload_job.remote_logical_parent` hoặc `remote_folder.logical_path` khớp `(camera|screenshot|saved)/<YYYY>[/…]`, kết quả `kv.legacy_layout = 1` được lưu một lần. Khi đó chu kỳ sync, khôi phục khởi động và các lệnh ghi job/move không làm gì; trạng thái tổng là "cần bắt đầu lại" (thẻ đỏ ở menu bar, nút mở Settings › Nâng cao, Sync now bị khoá, không thông báo). DB mới sau FR-117 không bị chặn.
  - *Thư mục gốc cũ:* khi onboarding, thêm đích hoặc đổi root/tài khoản gặp một root có thư mục năm `YYYY` ở cấp gốc hoặc dưới `Screenshots`/`Saved`, app không đề nghị dùng lại; báo đó là bản sao lưu 0.1.0, cách xử lý là chuyển vào Thùng rác hoặc chọn thư mục khác/tạo root mới. FR-51 từ chối một root như vậy (`notReady(.legacyLayout)`) trước khi ghi gì.
- **FR-52** `VACUUM INTO` mỗi 24 giờ và trước migration (giữ 7 bản). DB hỏng → bản sao gần nhất + FR-51.
- **FR-53** Mỗi chu kỳ, theo batch ≤ 500: `cloudIdentifierMappings` cho asset `l:` có `cloud_id IS NULL`. Bắt buộc chạy hết trước reconciliation.
- **FR-54 Một instance:** `flock` độc quyền trên `<container>/photovault.lock`. Instance thứ hai báo "đang chạy" rồi thoát.
### 4.8 UI
 
**FR-60 Menu bar** (`MenuBarExtra`, `LSUIElement`):
- Trạng thái chung; một dòng cho mỗi đích (enum 8.9.2, số chờ, lần thành công cuối).
- Tiến độ backfill: số asset xong/tổng, GB đã upload (không có tổng GB), ETA theo số asset. Chỉ hiện khi backfill chưa xong (xong < tổng); xong rồi thì popover không còn gì về backfill (FR-125). Cùng một quy tắc cho mọi việc một lần (backfill và import từ thư mục Mac, Google Drive, Dropbox): còn việc (đang đọc hoặc chỉ còn upload) thì hiện thẻ, xong thì ẩn (`PopoverJobVisibility`).
- Đếm `pending`/`deferred`/`skipped`/`missingRemote`.
- Hành động: Sync now · Pause/Resume (tất cả hoặc từng đích) · Open Drive · Reveal NAS · Hoạt động gần đây · Settings · Log · Quit.
**FR-61 Notification** (mỗi loại × mỗi đích ≤ 1 lần / 12 giờ): mất quyền Photos; cần đăng nhập lại; đích sắp đầy/đầy; thư mục bị xoá/trash; toàn vẹn thiếu; checksum lệch; NAS offline > 7 ngày; bookmark hỏng; ổ Mac đầy > 24 giờ; không sync được > 24 giờ.
 
**FR-62** `SMAppService.mainApp`.
 
**FR-63** Hoạt động gần đây: 500 sự kiện (đổi tên, di chuyển, file thiếu, đổi trạng thái, khôi phục, tiến độ). Sự kiện thường lệ không đẩy mất sự kiện hiếm: đổi tên và di chuyển của một đích gộp vào một dòng trong mỗi giờ, số file upload gộp một dòng mỗi ngày, trạng thái đổi rồi quay lại trong 2 giờ thì bỏ dòng. Tiến độ: số file upload trong ngày, và một dòng khi backfill xong (FR-125). Dòng sự kiện có thể ghi tên thư mục, không bao giờ ghi tên file hay toạ độ.
 
### 4.9 Local/NAS
 
**FR-70** Owner chọn thư mục qua `NSOpenPanel`, app lưu security-scoped bookmark. Cho phép nhiều đích. "Test connection" = ghi/đọc/xoá `.photovault-test`. Không tự mount SMB.
 
**FR-71** Thêm đích → hỏi phạm vi riêng; `baseline_at` = lúc thêm; nội dung cũ được export lại từ Photos (có rate limit). Xoá đích → xoá trạng thái trong DB, không xoá gì ở đích. Tạm dừng độc lập.
 
**FR-72 Rule theo đích:**
- Category (3 loại) · Ảnh (gồm video Live Photo) / Video / RAW · Gốc / Edited · Sidecar JSON / XMP · bỏ qua file > X GB.
- Setting toàn cục là **trần** (AND). Bật thêm → enqueue; tắt → huỷ theo asset.
- Ví dụ README: Drive = `camera` + `saved`; NAS = tất cả; SSD ngoài = chỉ bản gốc + JSON.
**FR-73 Ghi file local:**
- `.photovault/tmp/<uuid>.part` → `F_FULLFSYNC` (`ENOTSUP` → `fsync`) → đọc lại kiểm SHA-256 → đặt vào vị trí cuối.
- Vị trí cuối chưa có file của app → không ghi đè: `renamex_np(RENAME_EXCL)` → `link()` + `unlink` → kiểm tra-rồi-rename trong khoá thư mục. README nêu khe hở TOCTOU với tiến trình ngoài.
- Đã có file cùng hash → `done`.
- File khác nội dung mà DB không có hash của app → file gốc ghi thành `<stem> (conflict-xxxxxx)…`; edited/sidecar → `skipped(foreignFile)`.
- Ghi đè edited/sidecar **chỉ khi** hash file ở đích = `job.uploaded_hash`; khác → `skipped(foreignModified)`.
- Không theo symlink. Read-back trên SMB chỉ là best-effort.
**FR-74** `.photovault/destination.json` (id, createdAt, schema). Thêm lại thư mục có file này → hỏi dùng lại → FR-51.
 
**FR-75** Offline/bookmark hỏng → `unavailable`; kiểm tra lại mỗi 5 phút và khi `didMountNotification`; bookmark hỏng thì có nút chọn lại [VERIFY bookmark SMB qua remount/reboot].
 
**FR-76** Toàn vẹn: duyệt cây, so path + size; mỗi lần băm lại mẫu 1% (≤ 5 GB) để phát hiện bit rot.
 
### 4.10 Địa danh cho thư mục ngày
 
- **FR-80** Chỉ áp dụng cho thư mục ngày của nhánh `camera`.
- **FR-81** Xét asset `camera` có GPS; không có asset nào có GPS → không đặt tên. Nhóm theo `isoCountryCode` + `administrativeArea`, so bằng **khoá locale `en`**; mỗi nhóm một thư mục, đặt tên theo FR-82. Thư mục chính thuộc nhóm đông nhất; hai nhóm bằng nhau thì thuộc nhóm có ảnh sớm nhất của ngày (không ưu tiên quốc gia); thư mục đã có vẫn giữ theo tên/khoá nên ngày đã tách không bị xáo (sửa đổi 2026-11-10, issue #27, quyết định 0028).
  - Asset không có GPS, ô không có tỉnh (biển), hoặc ảnh ẩn khi "upload ảnh ẩn" tắt vào nhóm của asset có định danh gần nhất theo thời gian chụp (bằng nhau → asset sớm hơn, rồi `asset_key` nhỏ hơn). Asset đã xoá không được xếp lại: giữ thư mục đang ở.
  - A → B → A là hai nhóm. Không có ngưỡng số ảnh tối thiểu. Hai nhóm cùng tên hiển thị dùng chung một thư mục; nhóm có hộp bao > 300 km không có tên (dùng chung thư mục không tên).
  - Nhóm lớn nhất giữ thư mục chính `camera/<ngày>`; nhóm khác là thư mục phụ `camera/<ngày>@<slot>` (slot ổn định theo khoá tỉnh).
  - Khi đã biết ≥ 2 tỉnh, mọi ô phải có đáp án `en` rồi mới tách; ít hơn thì tính như trước (một tỉnh → hành vi cũ, kể cả khi hộp bao > 300 km mà còn ô chưa có đáp án thì chờ `waitingGeocode`).
- **FR-82** Cùng `locality` → hiển thị locality, ngược lại hiển thị tỉnh; khác quốc gia nhà thì thêm tên nước. Tên thư mục: `YYYY-MM-DD <Địa danh>`. Ngôn ngữ cố định (`PlaceNameRule`, quyết định 0023):
  - Tên nước: tiếng Anh chuẩn ("Vietnam", "Japan").
  - Nơi ở Việt Nam: tiếng Việt, bỏ tiền tố cấp tỉnh/thành ("Thành phố", "TP.", "Tỉnh", "Thủ đô") → "Hà Nội", "Lâm Đồng"; tiền tố phường/xã giữ nguyên ("P. Cửa Nam").
  - Nơi ở nước ngoài: tên tiếng Anh, kèm tên bản địa trong ngoặc khi khác ("Kyoto (京都市)").
- **FR-83** Chỉ đặt tên và tách khi ngày đã kết thúc ≥ 6 giờ. Tập asset đổi → tính lại → đổi tên hoặc chuyển nhóm (thêm, đổi, bỏ địa danh; file đã backup được chuyển bằng `move_job`) (sửa đổi 2026-11-10, issue #27, quyết định 0028).
  - Chế độ chỉ-quốc-gia (`kv.place_country_only = 1`): ngày đã tách giữ nguyên (không đổi slot, tên hay tách thêm); ngày chưa tách đặt tên theo quy tắc một nơi. Hết chế độ → tính lại.
  - Chỉ `PlaceNamer` đổi slot, và khôi phục (§8.15; đổi múi giờ lưu trữ xoá slot), trừ ảnh mới vào ngày đã tách (chưa có file): lấy slot theo khoá `en` của ô, không có thì theo asset gần nhất theo thời gian.
  - Thư mục phụ đã rỗng không bị xoá. Nhóm có tên còn nằm trên đĩa dưới dạng tên của thư mục khác (đổi tên chưa chạy xong) tạm ở lại thư mục hiện tại và ngày được tính lại sau.
- **FR-84 Geocoding:**
  - Dùng `CLGeocoder.reverseGeocodeLocation(_:preferredLocale:)` (hoặc `MKMapItem.placemark`) sau protocol `ReverseGeocoding`; chấp nhận cảnh báo deprecated. `MKAddressRepresentations` **không** có `administrativeArea` nên không dùng được.
  - [VERIFY M0-6] Nếu mất các trường có cấu trúc → giảm cấp xuống chỉ quốc gia, báo owner.
  - Ô lưới ~0,01°; cache `(geo_cell, locale)` vĩnh viễn; tối đa **20 request/phút**, backoff khi throttle (Apple ~50/phút, không dành cho batch).
  - Bounding box > 300 km → không cùng tỉnh, không cần geocode. > 30 ô → chọn 30 ô đại diện.
  - Phạm vi: mọi ô của asset `camera` có GPS. Ưu tiên ô cho thư mục ngày, sau đó ô mới nhất trước. Mỗi ô tối đa 2 request (`en` + ngôn ngữ thứ hai: `vi` ở Việt Nam, ngôn ngữ chính của nước sở tại ở nơi khác, bỏ qua khi đó là tiếng Anh; lưu dưới khoá `local`) → 10.000 ô ≈ 17 giờ, rải nhiều ngày. Không chặn upload.
- **FR-85** Toạ độ làm tròn ~1 km được gửi tới Apple; ghi rõ trong Settings và README; tắt được.
### 4.11 Sidecar
 
**FR-90** `<stem>.json` + `<stem>.xmp` cạnh file gốc; bật/tắt toàn cục và theo đích. Sinh trong bộ nhớ, deterministic. **Nội dung khác nhau theo đích**; hash lưu ở `job.uploaded_hash`.
 
**FR-91 JSON** (schema trong `docs/sidecar-schema.md`):
- Định danh: `schemaVersion`, `assetKey`, `localIdentifier`, `cloudIdentifier`.
- Ngày giờ: `creationDate` (UTC), `archiveLocalDateTime`, `archiveTimezone`, `modificationDate`.
- PhotoKit: `mediaType`, subtypes, kích thước, duration, `category`/`reason`, `isFavorite`, `isHidden`, burst.
- Vị trí: `location`; `place` khi ô đã geocode.
- `camera` (make, model, deviceName, lens); `albums`.
- `caption` + `keywords`: chỉ macOS 27+ qua `PHAssetExtendedMetadata` (**không có title**) [VERIFY]; cũ hơn ghi `"extendedMetadata":"unavailable"`.
- `resources` của **đích này** (type, kind, tên gốc, tên backup, size, md5, sha256, state).
**FR-92 XMP** — chỉ metadata không có sẵn trong file gốc:
- Favorite → `xmp:Rating=5`. `dc:description` = caption, `dc:subject` = keywords.
- `lr:hierarchicalSubject`: `PhotoVault|Album|…` và `PhotoVault|Category|…`.
- `photoshop:City/State/Country`.
- Không ghi ngày giờ, GPS, EXIF.
- Phải đọc được bằng `exiftool`. Lightroom chỉ đọc `.xmp` ngoài cho RAW độc quyền. digiKam mặc định tìm `file.ext.xmp` [VERIFY] — ghi README.
**FR-93 Cập nhật:**
- Sinh lần đầu khi **mọi** job bản gốc của asset ở đích đó đã kết thúc (`done`/`skipped`).
- Sinh lại khi: một job resource chuyển `done`; asset updated; album đổi ([VERIFY], nếu không thì 7 ngày một lần); geocode xong; tên thiết bị đổi; reconciliation.
- Chỉ upload khi hash đổi.
- **Không ghi** khi ở đích đã có file mà DB chưa có hash của app, hoặc hash khác lần ghi trước → `skipped(foreignFile|foreignModified)`.
**FR-94** README ghi: không có People/Memories; caption/keywords chỉ từ macOS 27; Lightroom có thể ghi vào `.xmp`.
 
### 4.12 View bằng shortcut (chỉ Drive)
 
**FR-100 Engine:** view = cây `<Root>/<View>/` chứa shortcut (không tốn dung lượng). Mỗi view là một `ViewRule`:
- `filter(asset)`
- `groupPath` (mỗi cấp gồm **khoá ổn định** + tên hiển thị)
- `target`
- `membershipTriggers`
Mỗi view bật/tắt riêng; thêm view mới = thêm rule.
 
**FR-101 Target:**
- Một shortcut cho mỗi asset trong mỗi view, trỏ tới primary resource theo rule của Drive (RAW nếu Drive nhận RAW).
- Chỉ tạo khi target đã `done`: `targetId` chỉ đặt được lúc `files.create`, nên không tạo tạm rồi đổi.
- Target đổi → trash shortcut cũ, tạo shortcut mới.
- Không có shortcut cho edited/sidecar/video Live Photo. Ưu tiên thấp nhất.
**FR-102 Thành viên động:**
- Không còn thuộc view → **trash shortcut** (`trashed=true`); đổi nhóm → move.
- Shortcut không phải dữ liệu backup; file đích không bao giờ bị đụng.
- Owner xoá shortcut hoặc thư mục view, hoặc gặp `404` → `userRemoved`, không tạo lại cho đến khi "Dựng lại view".
**FR-103 Ràng buộc:**
- [VERIFY M0-3] `drive.file` có cho tạo/move/trash shortcut không; nếu không → tắt view, **không** nâng scope.
- Shortcut trỏ theo ID nên không hỏng khi file di chuyển hoặc đổi tên.
- Số item tăng theo mỗi view [VERIFY giới hạn My Drive] → Settings ước tính và cảnh báo.
- Bật view → backfill từ DB. Tắt view → giữ nguyên cây. "Dựng lại view" = đưa cây về đúng trạng thái mong muốn.
- Ảnh bị xoá khỏi Photos vẫn còn bản backup nên giữ shortcut ở mọi view (By device, Favorites, By place, By lens); view không tạo shortcut mới cho ảnh đã xoá.
**FR-104 `By device/<Thiết bị>/YYYY-MM-DD/`:**
- Thành viên: asset `camera` có `camera_model`; không có nhóm Unknown.
- Khoá `make|model` chuẩn hoá. Tên mặc định `<Make> <Model>` (bỏ lặp hãng), cộng bảng `Resources/device-names.json` (ví dụ `ILCE-7M4` → `Sony A7 IV`; [VERIFY] từng mã).
- **Đổi tên** nhóm = đổi tên thư mục; trùng tên nhóm khác → báo lỗi, gợi ý gộp. **Gộp** = gán model sang nhóm khác → move shortcut.
- `group_id` deterministic = hash của `make|model` đầu tiên.
**FR-105 `Favorites/YYYY-MM-DD/`:** mọi category có `isFavorite`. Bật → tạo; tắt → trash.
 
**FR-106 `By place/<Quốc gia>/<Tỉnh>/YYYY-MM-DD/`:**
- Thành viên: asset `camera` có GPS và ô đã geocode ra quốc gia + tỉnh.
- Khoá = `isoCountryCode` + `administrativeArea` ở locale **`en`**; tên hiển thị theo FR-82 (tên nước tiếng Anh).
- Kết quả geocode cố định; nút "Làm mới địa danh" xoá cache rồi geocode lại.
**FR-107 `By lens/<Ống kính>/YYYY-MM-DD/` (quyết định 0027):**
- Thành viên: asset `camera` có `lens_model` không rỗng; không có thư mục Unknown. Ảnh đã xoá khỏi Photos vẫn giữ shortcut như các view khác.
- Tên = EXIF LensModel đã chuẩn hoá: bỏ khoảng trắng thừa; chuỗi điện thoại dạng `<máy> back <…> camera <phần còn lại>` (iPhone, Pixel…) thành `<máy> <phần còn lại>`, `<máy> front <…> camera <phần còn lại>` thành `<máy> front <phần còn lại>`; khẩu độ `f/N` viết `fN` ở mọi ống kính (ví dụ `iPhone 15 Pro 6.86mm f1.78`, `EF 50mm f1.8 STM`) để tên không có `/`; ống kính khác chỉ được gọn khoảng trắng. Giá trị giữ chỗ (chỉ có dấu câu như `----`, hoặc `0.0 mm f/0.0`) coi như không có ống kính, không tạo thư mục. Tên được làm sạch như tên thư mục khác (FR-42).
- Khoá nhóm = hash của tên thư mục (đã làm sạch, NFC, viết thường), nên biến thể chỉ khác hoa/thường hay khoảng trắng gom vào một thư mục và hai nhóm không bao giờ trùng tên thư mục. Tên thư mục giữ như lúc tạo: không bao giờ đổi tên (cả khi tạo hay chuyển shortcut).
- Cài đặt `viewByLensEnabled`, **mặc định tắt** (JSON cũ không có khoá này đọc ra tắt). Bật/tắt/dựng lại theo FR-103. Đổi tên và gộp nhóm ống kính để sau.

### 4.13 Nguồn & nhập một lần (sửa đổi 2026-11-09, issue #17, quyết định 0024; bổ sung 2026-11-10, quyết định 0026)

**FR-110 Danh sách nguồn:** Settings › Nguồn có "Nguồn liên tục" (Photos, luôn đứng đầu) và "Nhập một lần" (các import job: đang chạy trước, đã xong sau). Photos vẫn cần quyền và baseline trước khi một import chạy.
**FR-111 Nhập từ thư mục:** owner chọn thư mục bằng `NSOpenPanel`; app giữ security-scoped bookmark chỉ-đọc, duyệt đệ quy, bỏ file ẩn, package (kể cả `.photoslibrary`) và symlink, không bao giờ ghi vào thư mục. Chỉ nhận ảnh và video (RAW gồm trong đó).
**FR-112 Gom nhóm:** trong cùng một thư mục, file cùng tên (không phân biệt hoa thường, không kể đuôi) là một asset: RAW + một ảnh → `.photo` + `.alternatePhoto` (primary là RAW); ảnh + video chỉ khi content identifier của Apple khớp → Live Photo. Còn lại mỗi file một asset. `.AAE`, `.XMP`, `.THM`, `.json` bị bỏ qua và đếm là "bỏ qua".
**FR-113 Metadata và ngày:** ngày = EXIF `DateTimeOriginal` (+ `OffsetTimeOriginal`, không có thì múi giờ lưu trữ) → ngày tạo của video → ngày sớm hơn của (ngày tạo, ngày sửa) file; vị trí từ EXIF GPS hoặc ISO 6709; hãng/máy/lens từ TIFF/EXIF. Category theo FR-20 với metadata đã đọc, không bao giờ tạm thời; screenshot = EXIF `UserComment` "Screenshot"; thư mục cha trùng tên app chat tính là album (quy tắc 2).
**FR-114 Không trùng:** file là trùng khi khoá `x:` đã có hoặc khi một asset đang sống có resource cùng SHA-256. Khi chưa có hash, chỉ với asset Photos chưa export và chỉ khi ngày của file lấy từ EXIF/metadata video (không phải ngày file): cùng giây chụp, cùng tên gốc (không phân biệt hoa thường) và cùng kích thước ảnh (hai chiều theo thứ tự nào cũng được) hoặc thời lượng (±0,5 giây). Không bao giờ bỏ một file khác nội dung vì đoán. File trùng chỉ được đếm. Asset nhập là "mới đến" (`inserted_at` = lúc nhập, job `incremental`).
**FR-115 Huỷ:** ngừng nhập; file chưa quyết định → `cancelled`; asset của job có job chưa xong bị coi như đã xoá (job pending/deferred bị huỷ, file đã upload giữ nguyên). Nhập lại cùng thư mục sẽ nhặt lại phần thiếu.
**FR-116 Tiến độ và tóm tắt:** Settings và menu bar hiện: đọc (đã xử lý / tìm thấy) và upload (job xong / job của import, mọi đích), số trùng, bỏ qua, lỗi. Khi xong có đúng một dòng trong Hoạt động gần đây (chỉ số, không tên) và một thông báo macOS (có thể nêu tên thư mục). Thư mục không truy cập được (ổ rút ra) giữ riêng job đó ở `offline` và tự tiếp tục; Photos không bị ảnh hưởng.
**FR-119 Nhập từ Google Drive (quyết định 0026):** Settings › Nguồn › Nhập ảnh… › Từ Google Drive… mở luồng Google Picker trên trình duyệt: đăng nhập bằng tài khoản Google owner chọn (có thể khác tài khoản đích), đăng nhập qua loopback `127.0.0.1`, cùng client Desktop với đăng nhập Drive. Hai lần đồng ý Google cho cùng một tài khoản (quyết định 0030): bước 1 (Picker) chỉ xin `drive.file` vì Google không cho gộp scope khác với Picker; bước 2 ("Bước 2/2: cho phép đọc thư mục đã chọn") đăng nhập OAuth thường chỉ xin `drive.readonly` với `login_hint` là tài khoản bước 1, rồi kiểm tra cùng tài khoản (sai tài khoản thì từ chối: "chọn đúng tài khoản đã dùng để chọn thư mục"). Token giữ lại cho import là token `drive.readonly`; token `drive.file` của bước 1 bị bỏ (không revoke). Huỷ ở bước nào cũng không lưu gì. Đăng nhập của đích backup vẫn chỉ `drive.file`. Owner chọn file và/hoặc thư mục. App liệt kê file đã chọn và mọi thứ bên trong thư mục đã chọn (đệ quy tới tối đa 64 cấp thư mục; thư mục sâu hơn bị bỏ qua, không báo lỗi; phân trang theo `nextPageToken`, gồm Shared drive); file vừa được chọn riêng vừa nằm trong thư mục đã chọn chỉ đọc một lần; thư mục chọn trùng nằm trong thư mục khác cũng chỉ duyệt một lần. Nếu Google không cấp `drive.file` ở bước 1 hoặc `drive.readonly` ở bước 2 (owner bỏ chọn ô đó) thì đăng nhập bị từ chối kèm thông báo và không lưu gì. Khi import xong hoặc bị huỷ và không còn upload nào của nó đang chờ, đang chạy, hoãn hay "thiếu ở đích" (re-upload sau này cũng cần đọc nguồn), app xoá token `import-<id>` và bỏ adapter; đích thêm sau đó, hoặc upload lại sau khi release, đi qua luồng "Đăng nhập lại" (FR-121). Chỉ token trên máy bị xoá; quyền trong tài khoản Google vẫn còn tới khi owner gỡ tại myaccount.google.com/permissions. Import không tìm thấy ảnh hay video nào đọc được vẫn kết thúc nhưng nói rõ lý do (FR-123). Bỏ qua Google Docs, shortcut, file trong thùng rác và file có `appProperties` khoá `pv…` (do app tải lên). Tên trùng trong cùng thư mục nhận đường dẫn khác nhau. Chỉ đọc: không ghi gì vào Drive của owner. **Ưu tiên Google Drive cho máy tính (quyết định 0031):** nếu app Google Drive cho máy tính đã cài (`com.google.drivefs`), mục này mở hộp chọn thư mục tại `~/Library/CloudStorage` (tiêu đề "Chọn thư mục Google Drive (đồng bộ trên máy này)") và chạy import thư mục Mac như FR-111 trên thư mục đồng bộ — không OAuth, không màn hình "chưa xác minh"; hộp có nút "Dùng trình duyệt thay thế". Thư mục nằm trong `GoogleDrive-<email>/` thì cấu hình lưu `syncedProvider = googleDrive` và email (chỉ để hiển thị), dòng import ghi "Google Drive (trên máy này) · <email>"; không có token để xoá hay đăng nhập lại. Luồng trình duyệt ở trên là dự phòng khi chưa cài app; trước khi mở trình duyệt, app luôn hiện hộp "Tiếp tục / Huỷ" nói rằng Google sẽ báo "chưa xác minh", đây là app của owner (Nâng cao › Đi tới PhotoVault) và cách tránh (cài Google Drive cho máy tính). File chỉ có trên mạng được tải về khi đọc (đọc thường, lỗi hết giờ thì thử lại như lỗi đọc khác).
**FR-120 Nhập từ Dropbox (quyết định 0026):** owner đăng nhập Dropbox một lần (PKCE, redirect `http://localhost:53682/oauth2/callback`, chỉ `files.metadata.read`, `files.content.read`, `account_info.read`), rồi chọn thư mục hoặc toàn bộ Dropbox trong trình duyệt thư mục của app (chỉ hiện thư mục). Liệt kê đệ quy theo cursor, tải file stream xuống đĩa. Không có App key trong build thì mục Dropbox bị tắt kèm gợi ý, không crash. **Ưu tiên app Dropbox (quyết định 0031):** nếu app Dropbox đã cài (`com.getdropbox.dropbox`), mục này mở hộp chọn thư mục tại `~/Library/CloudStorage` và import như thư mục Mac (`syncedProvider = dropbox`, dòng ghi "Dropbox (trên máy này)"), không cần App key; nút "Dùng trình duyệt thay thế" mở luồng OAuth ở trên.
**FR-121 Mất quyền (quyết định 0026):** token bị thu hồi (`invalid_grant`, hoặc 401 vẫn lỗi sau một lần làm mới) → import đang mở chuyển `offline` với lý do "cần đăng nhập lại" và giữ job; hành động đăng nhập lại chạy lại luồng bắt đầu. Import đã đóng: job export chờ mỗi giờ, không ghi lỗi và không tính là sync thất bại; dòng import hiện "Đăng nhập lại" (`signInRequired`), và đăng nhập đúng tài khoản cũ thì các job chạy ngay ở chu kỳ sau. Cũng áp dụng khi mất token lúc khởi động (`invalid_client` tính như `invalid_grant`). File không còn trên nguồn trong khi nguồn vẫn trả lời thì vẫn bị bỏ qua (`resourceMissing`). Lỗi mạng không phải mất quyền: import đang mở giữ `offline` và tự tiếp tục (FR-116).
**FR-122 Token (quyết định 0026):** mỗi import cloud giữ refresh token riêng trong Keychain (`import-<sourceId>`) và được đăng ký lại khi khởi động nếu token còn. Tài khoản Dropbox dùng để duyệt thư mục được lưu riêng. Đăng xuất hoặc đổi tài khoản không làm hỏng import đã xong. Token Google Drive (và Dropbox) của import bị xoá khi import đã đóng và mọi upload của nó đã kết thúc (FR-119). Bắt đầu lại (FR-117) xoá mọi token này.
**FR-123 Riêng tư nhập cloud (quyết định 0026):** log và Hoạt động gần đây không có tên file, đường dẫn, id thư mục hay email. Email và tên thư mục chỉ hiện trong Settings, thẻ menu bar và thông báo hoàn tất. Import (mọi loại) không tìm thấy ảnh hay video nào đọc được thì dòng Settings, thông báo hoàn tất và dòng Hoạt động nói rõ "không có ảnh hay video nào mà app đọc được"; với Google Drive có thêm gợi ý nhập lại (Nhập ảnh… › Từ Google Drive…).
**FR-124 File cloud chưa đọc được (quyết định 0026):** một file cloud đọc lỗi tạm thời (mạng rớt, throttle, 5xx, hạn mức tải của Drive) hoặc chưa đủ chỗ trống trên đĩa để tải thì nhóm của nó nằm lại `pending` và import vẫn đọc các nhóm khác. Thiếu chỗ trống thì dòng import hiện lý do "chờ chỗ trống" (`diskFull`) và file không bao giờ bị đánh dấu lỗi vì thế. Mỗi nhóm đọc lỗi có thời gian chờ riêng: 30 giây, gấp đôi mỗi lần, tối đa 1 giờ; nhóm chưa từng lỗi được đọc trước, nhóm đang lỗi đọc sau theo giờ thử lại, nên vài file cứng đầu không chặn phần còn lại. Một nhóm bị bỏ cả nhóm (file đánh dấu lỗi "read", số "lỗi" hiện trên dòng, owner nhập lại thư mục để thử lần nữa) khi đã lỗi ít nhất 10 lần và giữa lần lỗi đầu và lần lỗi mới nhất cách nhau ít nhất 24 giờ giờ thật. Một lần lỗi chỉ được tính nếu lượt đó nhà cung cấp trả lời được probe; probe không kết nối được thì import chuyển sang offline, probe trả lời bận thì import tạm dừng 30 giây, cả hai trường hợp đều không tính gì. Bộ đếm nằm trong bộ nhớ nên mở lại app thì tính lại: app mở lại thường xuyên hơn một lần mỗi ngày có thể không bao giờ bỏ nhóm cứng đầu, và import đó mở cho đến khi owner huỷ. Ngắt mạch chỉ giới hạn thời gian một lượt: sau 3 nhóm liên tiếp chưa từng lỗi mà nay lỗi, lượt của nguồn đó dừng và chờ 30 giây; nhóm đang lỗi không được tính vào đó. Đánh đổi chấp nhận: nếu chỉ phần tải file hỏng hơn một ngày trong khi API vẫn trả lời, file có thể bị đánh dấu lỗi và owner nhập lại thư mục. Khi import cloud còn đang đọc, app kiểm tra lại mỗi 5 phút.
**FR-125 Backfill là việc một lần (quyết định của owner):** menu bar chỉ hiện thông tin sống. Mọi việc một lần, cả backfill lẫn import, hiện thẻ khi còn việc (đang đọc hoặc chỉ còn upload; import ở trạng thái `importing` cho tới khi upload xong) và biến mất khi xong; thẻ backfill hiện khi còn asset chưa xong. Backfill coi là xong khi không còn job backfill nào mở (`pending`, `uploading`, `deferred`, `missingRemote`; job `cancelled` hay `skipped` không giữ lại), còn ít nhất một asset có job backfill, không asset cũ nào mà một đích còn cần phân loại (ảnh ngoài phạm vi mọi đích, hoặc bị cài đặt loại, không giữ lại) và chu kỳ đã hết việc. Đích owner đã tạm dừng (`paused(userPaused)`) không giữ backfill mở, vì việc của nó chờ owner; các chờ khác (offline, hết chỗ, `deferred`) vẫn là việc sống nên thẻ vẫn hiện. Engine phát hiện một lần ở cuối chu kỳ như vậy và ghi trong một transaction: dấu `kv` (`backfill.completed_*`, `backfill.notify_pending`; mốc là id lớn nhất của job backfill chưa huỷ theo từng đích, vì id của các đích đan xen nhau; đích bị tạm dừng giữ mốc cũ và việc nó làm sau khi tiếp tục là một lần ghi nhận riêng; id chỉ tăng nên xoá job cũ, thêm lại đích hay thử lại file bị bỏ qua không làm lặp hay mất lần ghi nhận), một dòng Hoạt động gần đây ("Backfill xong: N ảnh · X GB", chỉ số và dung lượng, không tên) và cờ thông báo. App đăng đúng một thông báo macOS cùng nội dung nếu hệ thống cho phép, rồi báo engine đã xử lý; mở lại app không đăng lại, app tắt giữa lúc đăng và lúc báo thì đăng lại một lần cùng mã nên thay banner cũ. Backfill mới (thêm đích sau này) chạy rồi xong thì ghi nhận lần nữa. File mà khôi phục sau khi mất database ghép với dữ liệu đã có ở đích (ghi thành job backfill đã xong nhưng không upload gì) không phải là backfill: mốc của đích được đẩy qua chúng, không dòng Hoạt động, không thông báo; chu kỳ khôi phục vừa ghép vừa upload file còn thiếu thì chỉ tính các file đã upload. Người dùng nâng cấp mà backfill đã xong từ trước: lần chu kỳ đầu tiên đánh dấu đã xong, không thông báo, không thêm dòng Hoạt động, lấy giờ của job backfill xong cuối cùng. Settings › Nguồn, dòng Photos: "Đang backfill: x / y" khi đang chạy, "Backfill: xong lúc <ngày giờ> · N ảnh" sau đó, như dòng của import đã xong. Số ảnh là số ảnh có job backfill đã xong từ lần ghi nhận trước (ảnh bị bỏ qua không tính); dung lượng là tổng dung lượng các job đó (một ảnh lên hai đích tính hai lần).

## 5. NFR
 
- **NFR-01** Crash ở bất kỳ thời điểm nào không làm mất dữ liệu hay sinh file trùng.
- **NFR-02** Chặn idle sleep khi có job chạy (`beginActivity(.idleSystemSleepDisabled)`); không chặn sleep khi gập máy.
- **NFR-03** Idle: CPU ≈ 0, RAM < 100 MB. Tối đa 2 export, 2 upload mỗi đích; QoS `.utility`.
- **NFR-04** Backoff có jitter 1 giây → 30 phút; phân loại lỗi theo 8.14.
- **NFR-05** `NWPathMonitor`; tôn trọng mạng expensive/constrained.
- **NFR-06** Token chỉ ở Keychain, không log; chỉ gọi Google và geocoder của Apple.
- **NFR-07** `os.Logger` + file log xoay vòng 5 × 5 MB (tối đa 25 MB, file cũ nhất tự xoá), timestamp UTC đến mili-giây; mỗi job có ID để trace. "Xem log" mở cửa sổ đọc log trong app (lọc mức, tìm, sao chép, mở thư mục).
- **NFR-08** Scan hàng chục nghìn asset không treo UI.
- **NFR-09** Mỗi resource export một lần cho mọi đích đang khả dụng.
## 6. Môi trường
 
- Swift 6, SwiftUI; macOS 14+ (chốt sau M0-2); GRDB; AppAuth hoặc tự viết PKCE + loopback (ghi lý do); `URLSession`; ImageIO, AVFoundation, `CLGeocoder`; SPM.
- **Signing:**
  - **Không** dùng "Sign to Run Locally" (ad-hoc): mỗi lần build lại mất quyền TCC.
  - Dùng Personal Team (Apple ID miễn phí) [VERIFY M0-4 thời hạn và entitlement]; chạy từ `/Applications/PhotoVault.app`.
  - Hardened Runtime + App Sandbox. Entitlement: `personal-information.photos-library`, `network.client`, `network.server` [VERIFY], `files.user-selected.read-write`, `files.bookmarks.app-scope`.
  - `NSPhotoLibraryUsageDescription`; `LSUIElement`. Không cần Location Services [VERIFY].
- **Google Cloud** (owner tự làm, README hướng dẫn): bật Drive API và Google Picker API → consent screen External + scope `drive.file`/`openid`/`email`, thêm `drive.readonly` (chỉ cho nhập Google Drive, quyết định 0030) → **Publish "In production"** (Testing thì refresh token hết hạn sau 7 ngày; "unverified app" là bình thường [VERIFY]) → OAuth client loại Desktop → secret đặt trong `Config/Secrets.xcconfig` (gitignored, có file `.example`).
## 7. Kiến trúc
 
Pipeline: `ChangeTracker → Classifier → SQLite → ExportWorker → fan-out → {GoogleDriveDestination, LocalFolderDestination}`. Thành phần phụ trợ:
- `LayoutPolicy` (DynamicLayout), `PlaceNamer`, `SidecarBuilder`, `ViewBuilder`, `RecoveryService`
- `IntegrityChecker`, `ResourceGuard`, `AuthService`, `Store`, `MetadataReader`
- `UI`, `Logging`
`PhotosSource`, `Destination`, `LayoutPolicy`, `ReverseGeocoding` nằm sau protocol để test bằng fake.
 
**Mở rộng sau này:** loại đích mới = implement `Destination` (khai báo capability); layout mới = `LayoutPolicy`; view mới = `ViewRule`; mã hoá = lớp `Transform` (bản 1.0 là identity).
 
## 8. Thiết kế chi tiết
 
### 8.1 Asset key & placement
 
**Asset key:**
1. Có cloud identifier → `c:<cloudId>`; ngược lại → `l:<localId>`.
2. Key **không bao giờ đổi**; cloud ID phát hiện sau được ghi vào alias.
3. Gặp `localIdentifier` lạ (library rebuild, đăng xuất iCloud) → tra cloud ID → **gắn lại** vào asset cũ; không có thì là asset mới.
4. FR-53 bổ sung cloud ID cho asset `l:`.
5. [VERIFY M0-2] cloud ID có ổn định qua rebuild/đăng xuất iCloud không; độ dài.
6. File nhập từ thư mục (FR-111), Google Drive (FR-119) hoặc Dropbox (FR-120) → `x:<sha256 của file primary>` (64 ký tự hex thường; vừa `pvAssetId` 124 byte). Cùng nội dung cho cùng khoá ở mọi lần nhập; `localId` = `<sourceId>/<đường dẫn tương đối của primary>`. Với nguồn liên tục trong tương lai, kế hoạch đề xuất (chưa implement, không phải quy tắc đã chốt) là dùng `x:` như trên thay cho `s:<sourceId>/<itemId>` của quyết định 0024; xem [continuous-source-extension](../architecture/continuous-source-extension.md).
**Placement** (`placement_category`, `placement_day` hoặc `unknown`, `name_stem`):
- Chốt ngay khi có category chính thức, trước khi export bất kỳ resource nào để upload.
- Dùng cho mọi file của asset ở mọi đích.
- Sửa ngày trong Photos, đổi timezone, đổi rule → **không** đổi placement đã chốt.
### 8.2 Schema (cột chính)
 
- **`destination`**: `id` ('gdrive' | 'local-<uuid>'), `kind`, `display_name`, `status`, `status_reason`, `scope_mode`, `scope_since`, **`baseline_at`**, `rules_json`, `config_json` (root ID / bookmark), `account_id`, `account_email`.
- **`asset`** (PK `asset_key`):
  - Định danh & thời gian: `local_id` UNIQUE, `cloud_id`, `creation_date`, `modification_date`.
  - Loại & category: `media_type`, `media_subtypes`, `category`, `category_reason`, `category_provisional`.
  - Placement: `placement_category`, `placement_day`, `name_stem`, `placed_at`.
  - Thư mục phụ của ngày tách (migration `v6-day-place`) (sửa đổi 2026-11-10, issue #27, quyết định 0028): `place_slot` (NULL = thư mục chính `camera/<ngày>`; khác NULL = `camera/<ngày>@<slot>`, slot `p`/`r` + ≥ 12 chữ số hex). Bảng `day_place(day, slot, place_key, place_name)` cho các thư mục phụ; thư mục chính vẫn ở `day_stat`. Index `move_job(destination_id, subject)`. Từ bản này `Store.open` từ chối CSDL có migration mới hơn (`StoreError.newerSchema`); không hạ cấp xuống 0.3.0.
  - Thuộc tính: `is_hidden`, `is_favorite`, `burst_identifier`, `location_lat/lon`, `geo_cell`, kích thước, `duration`, `camera_make/model`, `lens_model`.
  - Chỉnh sửa: `has_adjustments`, `adjustment_hash`, `edit_check_pending`.
  - Vòng đời: **`inserted_at`** (NULL = có sẵn tại baseline Drive), `first/last_seen_at`, `deleted_at`.
  - Index theo `cloud_id`, `(placement_day, category)`, và hash của asset key (cho `h:`).
  - Nguồn (sửa đổi 2026-11-09, quyết định 0024): `source_id` (mặc định `photos`), index `(source_id, deleted_at)`; `resource(sha256)` có index để tra trùng.
  - Nguồn: `source_id` (mặc định `photos`; migration `v5-sources`), index `(source_id, deleted_at)`.
- **`source`** (quyết định 0024): `id` ('photos' | 'folder-<uuid>'), `kind`, `mode` (continuous | oneTime), `display_name`, `config_json` (bookmark chỉ-đọc), `status` (scanning | importing | offline | completed | cancelled), `status_reason`, `created_at`, `listed_at`, `finished_at`.
- **`import_item`** (PK `source_id, rel_path`): `group_key`, `uti`, `size_bytes`, ngày tạo/sửa của file, `state` (pending | imported | duplicate | unsupported | failed | cancelled), `asset_key`, `is_primary`, `date_source`, `reason`.
- **`asset_alias`**: `alias` → `asset_key`.
- **`name_alloc`**: PK `(placement_category, placement_day, norm_stem)`.
- **`album_member`**: `(album_local_id, album_title, asset_key)`.
- **`resource`** (PK `asset_key, res_type`; không chứa sidecar): `kind`, `is_raw`, `original_filename`, `uti`, `size_bytes`, **`content_gen`**, `md5`, `sha256`, `staging_gen`, `staging_path` (`…/<res_type>.<gen>`), `staging_state` (none/exporting/ready), `export_count`, `export_attempts`, `export_deferred_since`, `bytes_received_at_cancel`, `disk_cancel_count`, `last_used_at`.
- **`upload_job`** (UNIQUE `destination_id, asset_key, res_type`):
  - Phân loại: `kind`, `origin` (incremental | refresh | reupload | backfill | destinationBackfill), `state`, `state_reason`.
  - Vị trí ở đích: `remote_logical_parent`, `remote_name`, `remote_id` (Drive ID; local suy từ path logic), `session_ref`, `session_md5`.
  - Tiến độ: `uploaded_hash`, **`target_gen`**, **`done_gen`**, `mismatch_count`, `attempts` (chỉ lỗi upload mức item), `next_attempt_at`, `deferred_since`, `last_error`.
- **`day_stat`** (chỉ `camera`): `day`, `count`, `promoted`, `place_key`, `place_name`, `place_state` (pending/waitingGeocode/named/unnamed).
- **`geo_cache`**: PK `(geo_cell, locale)` → `iso_country`, `country`, `administrative_area`, `locality`.
- **`remote_folder`**: PK `(destination_id, logical_path)` → `remote_id`, `display_name`, `verified_session`. Đường dẫn logic **không chứa tên hiển thị**: `camera`, `camera/2026-11-08`, `screenshot/2026-11-08`, `view/byDevice/<group>/2026-11-08`, `view/byPlace/VN/<area>/2026-11-08`, `view/favorites/2026-11-08`. Ở local, đường dẫn thật luôn tính lúc chạy từ `display_name`.
- **`move_job`**: `op` (moveFile | renameFolder), `subject`, `from_value`, `to_value`, `state` (pending/inProgress/done/failed).
- **`device_group`** (`group_id` deterministic, `display_name`) + **`device_model`** (`make_model_key` → `group_id`); **`view_folder_group`** (view, `group_key`, `display_name`).
- **`shortcut`** (PK `destination_id, view, asset_key`): `target_id`, `shortcut_id`, `parent_logical`, `state` (pending/done/movePending/trashPending/trashed/failed/userRemoved).
- **`activity`**; **`kv`** (baseline/change token, `scan_state`, cursor, `archive_timezone`, `schema_version`).
### 8.3 State machine
 
- **Resource:** `none → exporting → ready → none` (khi giải phóng staging).
- **Job:** `pending · uploading · done · deferred · skipped · cancelled · missingRemote`. "Sẵn sàng upload" = `pending` với resource `ready` và `staging_gen = target_gen`.
| Từ → Đến | Khi | Ghi chú |
|---|---|---|
| pending → uploading | resource ready, đích khả dụng | |
| uploading → done | checksum khớp | `done_gen = target_gen`, xoá session |
| uploading → uploading | checksum lệch | `files.update` cùng ID, `mismatch_count++`; > 3 → `skipped` (giữ `remote_id`) |
| uploading → pending | staging bị giải phóng / mất | giữ `remote_id`, session |
| uploading → pending | lỗi upload mức item | `attempts++` |
| pending → deferred | `attempts` > 8 hoặc `export_attempts` > 8 | `deferred_since` chỉ ghi khi NULL |
| * → pending | lỗi mức đích | **không** tăng `attempts` |
| deferred → pending | sau 24 giờ hoặc owner bấm | `attempts = 0` |
| deferred → skipped | > 30 ngày (trừ `tooLargeForDisk`) | |
| skipped → pending | owner bấm thử lại | reset bộ đếm; **giữ** `remote_id` |
| done → pending (refresh) | `target_gen` tăng | giữ `remote_id`, cập nhật tại chỗ |
| done → missingRemote → pending (reupload) | toàn vẹn thiếu → owner xác nhận | xoá `remote_id`/hash, giữ `remote_name` |
| pending/deferred ↔ cancelled | thu hẹp (mọi job của asset còn pending/deferred) / mở rộng | |
 
- **Cập nhật khi đang chạy:** chỉ tăng `target_gen`; xong mà `done_gen < target_gen` → `pending` (refresh). Không bao giờ mất bản cập nhật cuối.
- **Staging theo thế hệ:** không ghi đè file đang được upload khác đọc.
- **Upsert:** `ON CONFLICT DO UPDATE` — cancelled/skipped (khi thử lại) → pending; done/đang chạy → chỉ tăng `target_gen` khi nội dung đổi.
- Ghi DB **trước** side effect.
- Khởi động: resource `exporting` → `none`; job `uploading` → FR-44.
- Job sidecar không cần resource.
- `move_job`: pending → inProgress → done; > 8 lỗi → failed. Chỉ lỗi của chính move mới tính lần thử. Giới hạn tốc độ (403 rateLimitExceeded/userRateLimitExceeded, 429), lỗi máy chủ (5xx) và lỗi tạm thời đưa move về pending không tính lần thử, đích lùi lại (chung với upload) và lượt move của đích đó dừng. Move đã lỗi trước đó xếp sau các move chưa lỗi để không chặn trần 500. Khi khởi động, move file (`moveFile`) `failed` được đặt lại pending, đổi tên thư mục thì không (move không còn áp dụng vì file đã ở đúng thư mục thì bị bỏ qua).
- `shortcut`: create/move/trash; đổi target → trash + tạo mới; `404` → `userRemoved`.
### 8.4 Một chu kỳ sync
 
1. Kiểm tra điều kiện chung (quyền Photos, mạng, nguồn điện, nhiệt) và điều kiện từng đích (credential, khả dụng, chưa đầy, root ổn).
2. **ChangeTracker:** scan chưa xong → tiếp tục scan. Ngược lại → mỗi change một transaction thuần DB: upsert asset (gắn lại `local_id` lạ, ghi `inserted_at`), cập nhật cờ, `album_member`, phân loại, `day_stat`, upsert job theo eligibility, `edit_check_pending`, tăng `target_gen` sidecar, kích hoạt view, lưu token.
3. **Classify** → chốt placement. Sau đó **ImportStage** (sửa đổi 2026-11-09, quyết định 0024): với mỗi import job `scanning` — liệt kê thư mục, đọc từng nhóm file ngoài transaction, một transaction cho mỗi nhóm (loại trùng, tạo asset với category cuối cùng, placement, job), rồi `importing` → `completed` khi không còn file chờ và không còn job `pending`/`uploading`.
4. **ExportWorker** — chỉ asset đã chốt placement, primary trước. Ưu tiên: incremental > refresh > reupload > backfill (mới nhất trước). Chỉ export khi có đích khả dụng cần. Rate limiter áp cho backfill **và** mọi lần export lại (`export_count ≥ 1`). Có disk guard. Sau khi export: hash + EXIF.
5. Worker cổng chỉnh sửa.
6. **Fan-out:** layout từ placement + `day_stat` (trong transaction), đảm bảo thư mục (actor; khoá thư mục ở local), upload, verify. Layout không phụ thuộc việc promote nên promote không tạo `move_job`; chỉ tách ngày theo tỉnh (bước 9, FR-81) mới tạo `move_job`.
7. Mọi job gốc của asset ở một đích đã kết thúc → job sidecar; mỗi lần có thêm resource `done` → tăng `target_gen` sidecar. Drive: tạo shortcut khi target `done`.
8. MoveWorker.
9. PlaceNamer → nhóm theo tỉnh, gán slot, `renameFolder` cho thư mục đổi tên, `moveFile` cho file đã backup đổi nhóm (sidecar kèm theo; tối đa 500 move mỗi đích mỗi lượt, `EngineTuning.maxMovesPerPass`) + làm mới sidecar/description + view `By place` (sửa đổi 2026-11-10, issue #27, quyết định 0028).
10. FR-53.
11. Cập nhật UI qua observable state.
### 8.5 Dung lượng ổ Mac — rủi ro số 1
 
Export bản gốc ở chế độ Optimize có thể khiến Photos giữ bản gốc trong library mà app không kiểm soát được. Owner chấp nhận backfill chậm (nhiều ngày đến nhiều tuần).
 
- Đo cả `volumeAvailableCapacity` (dung lượng trống thật — dùng cho critical) lẫn `…ForImportantUsage`, trên volume staging và volume home [VERIFY volume của library]. Chỉ số cho `lowWatermark` chốt theo M0-1.
- Token bucket 20 GB/giờ cho backfill và mọi lần export lại; incremental lần đầu chỉ chịu disk guard.
- Dưới low → dừng export bị rate limit; dưới critical → dừng mọi export và huỷ export đang chạy. Chạy lại khi ≥ low + 5 GB; kiểm tra mỗi 15 phút.
- Export bị rate limit chỉ chạy khi cắm sạc; dừng khi Low Power Mode hoặc `thermalState ≥ .serious`.
- Dừng > 24 giờ → notification.
- Nếu M0-1 cho thấy Photos **không bao giờ** dọn bản gốc đã tải → ghi `docs/decisions/`, **dừng và báo owner**.
### 8.6 Ngày giờ
 
Luôn dùng archive timezone, không dùng `TimeZone.current`. `creationDate` sai do đồng hồ máy ảnh → giữ nguyên.
 
### 8.7 Thư mục ngày (mọi nhánh, mọi đích)

1. Mọi file nằm trong thư mục ngày của `placement_day` ngay từ lần upload đầu; layout không phụ thuộc số lượng ảnh. Ngày có ảnh ở nhiều tỉnh được tách theo FR-81 sau khi ngày kết thúc ≥ 6 giờ, và chỉ lúc đó mới có `move_job` vì tách ngày (sửa đổi 2026-11-10, issue #27, quyết định 0028).
2. `day_stat.promoted` chỉ còn nghĩa "ngày này được đặt tên địa danh": bật ở asset `camera` đầu tiên của ngày, `place_state = pending`. Không demote.
3. Count vẫn tính lại từ DB (cho tiến độ và địa danh), không cộng dồn.
4. Không bao giờ xoá thư mục ngày; đổi tên (địa danh) không đổi đường dẫn logic. Thư mục phụ của ngày tách có đường dẫn `camera/<ngày>@<slot>`, là anh em của thư mục chính, và cũng không bị xoá khi rỗng (sửa đổi 2026-11-10, issue #27, quyết định 0028).
5. Đổi từ layout `Năm/Tháng` cũ không có migration: app chặn DB cũ và owner dùng "Đặt lại từ đầu" rồi sync lại vào root mới (quyết định 0023, 0025; FR-117, FR-118).
### 8.8 Phạm vi & eligibility (tính thuần tuý, theo từng đích)
 
```
inWindow = asset.inserted_at IS NOT NULL AND asset.inserted_at >= dest.baseline_at
eligible = asset.deleted_at IS NULL AND passesGlobalSettings AND passesRules(dest)
  AND ( mode='full'
     OR (mode='since'   AND (archive_day >= since OR inWindow))
     OR (mode='newOnly' AND inWindow) )
```
 
- `inserted_at`: NULL nếu có sẵn tại baseline; = thời điểm change "inserted"; = lúc reconciliation phát hiện.
- Đích thêm sau với `newOnly` chỉ nhận asset vào library sau lúc thêm.
- Bỏ ẩn hay đổi setting không đổi `inserted_at`.
- Ảnh cũ import sau mốc → được upload ở cả `newOnly` và `since`.
- Asset nhập từ thư mục (FR-111) có `inserted_at` = lúc nhập, nên đi vào cửa sổ của `newOnly`/`since`; job của chúng là `incremental` (không qua bucket backfill và cổng nguồn điện).
- Đổi phạm vi/rule/setting → tính lại; hợp lệ → upsert job; không còn hợp lệ → `cancelled` (theo 8.3).
### 8.9 Đích
 
**8.9.1 `Destination` protocol:**
- `capabilities`, `checkAvailability`, `ensureFolder`
- `upload`, `resumeUpload`, `replaceContent` (edited, sidecar, sửa checksum lệch)
- `move`, `renameFolder`, `list`, `quota`
- **Không có hàm xoá.**
**8.9.2 Trạng thái đích:** `active` · `paused(r)` · `unavailable(r)` · `error(r)`, với `r` ∈ `userPaused`, `full`, `dailyCapReached`, `offline`, `bookmarkInvalid`, `reauthRequired`, `signedOut`, `rootMissing`, `rootTrashed`, `folderTrashed`, `recovering`.
 
**8.9.3 Staging nhiều đích:**
- Export một lần, upload song song.
- Xoá staging khi mọi job ở các đích **đang khả dụng** đã xong. Không giữ file chờ đích offline; đích đó sẽ export lại sau (có rate limit).
- Hết hạn khi **rảnh**: 2 giờ không có upload nào đang truyền thì giải phóng; upload đang truyền không bao giờ bị cắt.
**8.9.4 Local:**
- Khoá theo thư mục logic: ghi file lấy khoá đọc, đổi tên lấy khoá ghi.
- Đổi tên an toàn khi crash: ghi `move_job` (inProgress) → rename → commit `display_name` + done. Khởi động: tên mới có, tên cũ không → commit; tên cũ còn → thử lại; cả hai đều không → báo kiểm tra toàn vẹn.
- Thư mục trung gian chỉ tạo qua `ensureFolder`.
### 8.10 Phân loại
 
So tên album chính xác, không so chuỗi con. Ưu tiên screenshot hơn album chat.
 
### 8.11 Thuật toán địa danh
 
1. Trigger: ngày được promote / ngày kết thúc ≥ 6 giờ / tập asset đổi / geocode của một ô trong ngày về.
2. Không có GPS → `unnamed`.
3. Các ô đã có đáp án `en` cho thấy ≤ 1 tỉnh → quy tắc một nơi như trước (bước 3a–7), kể cả trạng thái tạm; hộp bao > 300 km mà còn ô chưa có đáp án → `waitingGeocode`. Cho thấy ≥ 2 tỉnh → mọi ô phải có `en` (`waitingGeocode` nếu thiếu), rồi nhóm theo khoá `en`; asset không định danh vào nhóm gần nhất theo thời gian; mỗi nhóm chạy bước 3a–7 riêng (sửa đổi 2026-11-10, issue #27, quyết định 0028).
   - 3a. Bounding box > 300 km → `unnamed`.
4. > 30 ô → chọn 30 ô đại diện (gồm các ô cực bắc/nam/đông/tây).
5. Geocode các ô còn thiếu (`waitingGeocode`).
6. Ô thiếu tỉnh → bỏ qua; mọi ô đều thiếu → `unnamed`.
7. Mọi ô cùng khoá `en` → `named`.
8. `DaySlotPolicy` ánh xạ nhóm lên thư mục: theo tên hiển thị (tên đang có hoặc còn trên đĩa), theo khoá, thư mục chính còn trống, thư mục mới; không bao giờ hai thư mục cùng tên. Tên đổi → `renameFolder` ở mỗi đích; nhóm đổi thư mục → `moveFile` (+ sidecar) + làm mới sidecar/description.
### 8.12 Sidecar
 
Deterministic (khoá sắp xếp, số định dạng cố định, không có thời điểm sinh). Cặp RAW+JPEG dùng một `.xmp` + một `.json`. Sidecar JSON của asset nhập từ thư mục có thêm khối `"source": {kind, name, path, dateSource}` (sửa đổi 2026-11-09, quyết định 0024); sidecar của asset Photos không đổi một byte.
 
### 8.13 Engine view
 
- Trigger (upload xong, Favorite, EXIF, geocode, bảng thiết bị, dựng lại) → tính trạng thái mong muốn `(thuộc?, đường dẫn logic, target_id)` → so bảng `shortcut`:
  - thiếu và target đã `done` → tạo
  - khác thư mục → move
  - khác target → trash + tạo
  - thừa → trash
  - `userRemoved` → giữ nguyên
- Tên hiển thị từng cấp lấy từ `view_folder_group` và ngày; đổi tên thì không đụng shortcut.
- Thư mục view mang `pvLogical`/`pvView`, không chịu luật pause.
- Ngày của thư mục view lấy từ `placement_day`; asset không có ngày không thuộc view nào.
- Target bị `missingRemote` → tạo lại shortcut sau khi upload lại.
- Kiểm tra toàn vẹn cũng list view: owner đã xoá → `userRemoved`; app tạo mà DB không biết → trash.
- Ưu tiên trash/move > tạo; mọi job view đứng sau upload.
### 8.14 Phân loại lỗi
 
- **Mức đích:** `401` sau refresh, `invalid_grant`, mất mạng, unmount, quota/`ENOSPC`, rate limit/`429` lặp lại dù đã qua token bucket, `5xx` liên tiếp → đổi trạng thái đích hoặc backoff đích; job về `pending`, **không** tăng `attempts`.
- **Mức item:** export lỗi, resource không tồn tại, checksum lệch, file bị từ chối → `attempts` (8.3).
- **Tạm thời:** retry trong lượt tối đa 3 lần.
- `401` → refresh 1 lần. `404` session → session mới. `404` thư mục cha → FR-47.
### 8.15 Khôi phục từ đích
 
Tiền đề: scan `complete` + FR-53 xong.
 
1. `paused(recovering)`.
2. List item có `pvSchema=1` (Drive) [VERIFY thấy được sau khi cài lại app] hoặc duyệt cây + sidecar (local).
3. Dựng `remote_folder` từ `pvLogical` (local: từ cấu trúc thư mục `Camera Uploads/<ngày>[ <địa danh>]`, `Screenshots/<ngày>`, `Saved/<ngày>`, tách phần địa danh). Thư mục ngày của `camera` tồn tại → `promoted`, `place_name`.
   - Ngày tách (sửa đổi 2026-11-10, issue #27, quyết định 0028): mỗi thư mục ngày `camera` được gán đường dẫn logic bởi `DaySlotBinding`, cho mọi loại đích. Đích có app properties (Drive) được khôi phục trước; đích local chờ trong khi còn đích Drive cần khôi phục (trạng thái `paused(waitingForDrive)`), nhưng chỉ khi chờ đó có thể kết thúc: Drive còn truy cập được hoặc chỉ mất mạng tạm thời, đã đăng nhập, còn thư mục gốc, không có quyết định của owner đang mở, và tối đa 30 phút; ngoài các trường hợp đó đích local tự khôi phục với slot tạm. Danh sách local chỉ đoán được thư mục nào là thư mục chính: (1) theo id thư mục của một hàng `remote_folder` sẵn có; (2) theo tên hiển thị của slot đã biết (`day_stat`, `day_place`); (3) dự phòng: `pvLogical` trên Drive, thư mục đầu tiên theo khoá tên là `camera/<ngày>` trên local, còn lại `@r…`.
   - Không bao giờ re-point hàng mà thư mục của nó còn trong danh sách; chỉ hàng cũ (thư mục không còn, ví dụ CSDL phục hồi từ bản backup trước khi tách) được re-point. Ghi làm hai đường dẫn cùng một id, hoặc hai thư mục tranh một đường dẫn → bỏ qua, ghi nhật ký và báo một dòng hoạt động; file trong đó không được nhận vào lần khôi phục này: chúng ở nguyên chỗ cũ trên đích (không bao giờ bị xoá) và asset được upload lại vào thư mục đúng.
   - `place_slot` của asset lấy từ thư mục chứa file chính (không có thì thư mục chứa nhiều file nhất, hoà → thư mục chính), khi placement được đọc từ file hoặc ngày chưa từng tách trong CSDL này. Đổi múi giờ lưu trữ khi khôi phục xoá `day_place` và `place_slot`.
   - **3d.** Ngày có slot tạm (đích local khôi phục một mình đã đoán thư mục chính, `ProvisionalSlots`): khi Drive được khôi phục sau đó và qua bước kiểm tra khớp, app gán lại hàng local, job, slot và rename/move đang mở theo slot của Drive (thư mục Drive theo slot giữ nhiều asset nhất, rồi theo tên). Thư mục Drive khác tên slot thì đổi tên, file không chuyển nếu hai đích giữ cùng asset.
   - **3e.** Gán hai bước cho mọi đích: mọi thư mục của ngày được gán trước theo id và tên; thư mục lạ ở local được gán vào slot đã biết chứa nhiều asset nhất (theo asset key trong sidecar, `DaySlotBinding`), chỉ khi đó mới đoán (`@r…`) và cách đoán không bao giờ lấy đường dẫn của slot đã biết. Giới hạn: thư mục local tên lạ không có asset nào được nhận diện là phép đoán; file của nó có thể chuyển ở đích đó (không bao giờ ở Drive).
4. Ghép file theo thứ tự:
   1. `pvAssetId`/`assetKey` (kể cả dạng `h:`, tra theo index hash) hoặc alias;
   2. cloud/local ID trong sidecar;
   3. vân tay `creationDate` + `originalFilename` + `pixelWidth×Height`/`duration` — **không cần tải file**; còn nhiều ứng viên thì export (có rate limit) để so.
5. Ghép được → `asset` (key khác thì ghi alias), job `done`, placement suy từ vị trí + tên, `name_alloc`.
6. Shortcut có `pvView` + `pvAssetId` → bảng `shortcut`; `group_id` deterministic. Engine chỉ bổ sung phần thiếu, không trash hàng loạt.
7. Không ghép được → log; **không** đụng tới.
8. Xong → `active`, enqueue phần còn thiếu.
## 9. Bảo mật
 
- Không backend/analytics/crash reporter.
- Token chỉ ở Keychain; revoke khi đăng xuất.
- Quyền: Photos, network, notification, thư mục do owner chọn; file và thư mục Google Drive do owner chọn trong Picker (`drive.file`; khi nhập thêm `drive.readonly`, quyết định 0030); Dropbox chỉ đọc. **Không** Full Disk Access, **không** đọc trực tiếp `Photos Library.photoslibrary`.
- Toạ độ làm tròn ~1 km gửi Apple (tắt được).
- Sidecar chứa vị trí/album → nhắc owner cân nhắc rule theo đích.
- Hidden mặc định không upload. Không mã hoá phía client (README nói rõ).
## 10. Milestones
 
**M0 — Spike** (bắt buộc làm trước; **dừng và báo owner sau M0**; kết quả ghi `docs/spikes/`):
 
| Spike | Nội dung |
|---|---|
| M0-1 | Export 20–50 GB asset chỉ có trên iCloud bằng `requestData`: library có phình/có tự dọn không, diễn biến hai chỉ số dung lượng theo thời gian (đến 24 giờ sau) → chốt rate, watermark |
| M0-1b | `requestData` có trả đúng byte gốc, có huỷ được không; mapping resource/UTI/tên cho RAW-only, RAW+JPEG, Live Photo, burst, drone, bản chỉnh sửa |
| M0-2 | Change history (inserted/updated; export có tự sinh "updated" không; album; Hidden; Shared Library/Albums; screenshot/screen recording); `.adjustmentData`; cloud ID (ổn định qua rebuild, độ dài); `PHAssetExtendedMetadata` |
| M0-3 | Drive: OAuth; resumable 4 GB qua sleep và mất mạng; `about.get`; shortcut tạo/move/trash/untrash với `drive.file`; `generateIds` theo type; lỗi khi ID đã tồn tại; tạo dưới thư mục cha đã trash; giới hạn `appProperties`; revision; list sau khi cài lại; tốc độ ghi bền vững → token bucket |
| M0-4 | Personal Team + sandbox + entitlement + TCC qua nhiều lần build; bookmark SMB qua remount/reboot; `RENAME_EXCL`/`F_FULLFSYNC` trên APFS/exFAT/SMB |
| M0-5 | EXIF bằng ImageIO cho HEIC/JPG/ARW/NEF/CR3/DNG; AVFoundation cho iPhone/Sony/DJI; classify bằng đọc header rồi huỷ (bao nhiêu byte với asset trên iCloud); `hasAdjustments` |
| M0-6 | `CLGeocoder`: trường có cấu trúc, mức throttle, chất lượng tên ở VN (`vi`/`en`), độ ổn định của khoá `en`; 20 ví dụ thật |
 
- **M1** Core với Drive: Store + backup DB, Auth, PhotosSource (scan có `scan_state`, change từng transaction, export streaming), asset key/alias/placement, Classifier, MetadataReader, GoogleDriveDestination (resumable, checksum, `generateIds`, kiểm tra root), DynamicLayout + chuẩn hoá tên, Pipeline (8.3, 8.14, ưu tiên, rate limiter, fan-out), ResourceGuard, FR-54. Chạy được 3 sync mode + backfill + incremental.
- **M2** UI: onboarding, menu bar, Settings, notification, Hoạt động gần đây, login item, đổi mode/tài khoản/root.
- **M3** Local/NAS: ghi atomic không ghi đè, khoá, đổi tên an toàn, bookmark, `destination.json`, rule và phạm vi theo đích, staging nhiều đích.
- **M4** Tổ chức & metadata: thư mục ngày, classify, cổng chỉnh sửa, PlaceNamer, sidecar, engine view + 3 view, `description`.
- **M5** Hardening: Recovery (FR-51/52/53), reconciliation, kiểm tra toàn vẹn, "Dựng lại view", retry deferred/skipped, toàn bộ test, README.
## 11. Test
 
**Unit** (dùng fake): mọi chuyển trạng thái 8.3 (upsert, reset cột, `target_gen`); recovery sau crash; phân loại lỗi; asset key/gắn lại; placement; classify + tập đích hai chiều; tên (NFC, byte, ký tự cấm, hoa/thường, trùng); promote/move/race; eligibility 8.8; địa danh (thiếu GPS, khác tỉnh, cùng tỉnh khác thành phố, nước ngoài, vùng biển, > 300 km); sidecar deterministic; XMP; rule + trần toàn cục; staging (đích offline, hết hạn khi rảnh); rate limiter; disk guard (file lớn, hai export cùng lúc); timezone; tên thiết bị; recovery (3 cách ghép, `h:`).
 
**Integration** (thủ công):
- Drive: folder song song, `generateIds`, resume, sửa checksum, update, move, rename, shortcut, `appProperties`, quota, trash root/con, list sau khi cài lại.
- Local (APFS, exFAT, SMB): ghi không ghi đè, file lạ chiếm sẵn đường dẫn, rename khi đang ghi, unmount.
**Kịch bản** (kết quả ghi `docs/test-report.md`):
 
| # | Kịch bản → Kỳ vọng |
|---|---|
| T1–T3 | `newOnly` không upload ảnh cũ; `since(30 ngày)` mới nhất trước; `newOnly` → `full` không upload trùng |
| T4 | Chụp ảnh trong lúc scan, với cả 3 mode → luôn được upload |
| T4b | Token hết hạn, chụp 50 ảnh rồi mở lại (`newOnly`/`since`) → đủ 50 ảnh; ảnh vừa bỏ ẩn không bị coi là mới |
| T5 | Import ảnh cũ sau mốc → được upload |
| T6 | ≥ 1.000 asset đủ loại → đủ file, burst đủ khung, Hidden không lên |
| T7 | RAW-only + video drone > 4 GB → lên cả hai đích, checksum và EXIF y hệt |
| T8 | Upload > 2 giờ → không bị cắt |
| T9 | Camera + screenshot cùng ngày → `Camera Uploads/<ngày>` và `Screenshots/<ngày>` đúng ở Drive và NAS, không move |
| T11 | Đổi timezone hệ thống → vẫn theo archive timezone |
| T12 | Sửa ngày rồi sửa ảnh → edited/sidecar cùng thư mục với bản gốc |
| T13 | Sửa, sửa lại, Favorite, album, Revert → một file edited mỗi loại; Favorite chỉ cập nhật sidecar |
| T14–T15 | Ổ đầy (watermark, huỷ export); rút sạc / Low Power → backfill dừng, incremental vẫn chạy |
| T16–T17 | `kill -9` / gập máy ở mọi bước → không trùng, không mất, không còn `.part`, thư mục không bị tách đôi |
| T18 | Mạng/NAS chập chờn → không job nào bị đẩy sang deferred/skipped |
| T19 | Root/tháng bị trash → dừng và hỏi; ngày bị xoá hẳn → tạo lại + báo |
| T20 | Xoá file ở đích + "Kiểm tra ngay" → báo đúng số |
| T21–T22 | Thu hồi Google / đổi tài khoản; thu hồi quyền Photos |
| T23 | Xoá ảnh trên iPhone → backup vẫn còn |
| T24 | Build lại 3 lần → không hỏi lại quyền, bookmark vẫn dùng được |
| T25 | Đổi tên root |
| T26 | NAS offline 3 ngày → Drive vẫn nhận, staging không phình, NAS nhận bù (có rate limit) |
| T27 | Rule theo đích; ảnh tạm `camera` hoá ra `saved` vẫn đến đích chỉ nhận `saved` (kể cả khi đó là đích duy nhất) |
| T27b | RAW+JPEG khi Drive không nhận RAW; Live Photo với 2 export song song → không kẹt |
| T27c | NAS `newOnly` thêm sau khi Drive đang `full` |
| T28 | Đà Lạt (iPhone + RAW không GPS) → có tên; đi 2 tỉnh → mỗi tỉnh một thư mục (nhóm lớn nhất giữ thư mục chính); import thêm vào ngày đã tách → file đã có không chuyển; ảnh mới có thể vào sai thư mục rồi được chuyển một lần khi `PlaceNamer` sửa lại (sửa đổi 2026-11-10, issue #27, quyết định 0028) |
| T29 | Zalo/Safari → `Saved`; video drone không vào `Saved` |
| T30 | JSON đúng theo đích; không ghi đè `.xmp` bị sửa ngoài hoặc `.xmp` Lightroom có sẵn; sidecar sinh lại khi edited xong |
| T30b | Sửa 2 lần trong 1 phút khi đang upload → đích có bản cuối |
| T31 | Xoá DB → khôi phục, không upload lại, không xáo trộn view |
| T32 | Rebuild library → gắn lại theo cloud ID |
| T33–T34 | File lạ ở NAS → `(conflict-…)`; `IMG_0001` vs `img_0001`, tên tiếng Việt (NFC) |
| T35 | By device: shortcut mở đúng file, đổi tên, gộp |
| T36 | Geocode ≤ 20/phút, ưu tiên ô của thư mục ngày |
| T37 | Favorites: bật, tắt (trash), owner tự xoá |
| T38 | By place: VN/Nhật; không GPS; đổi ngôn ngữ chỉ đổi tên thư mục |
| T39 | Tắt/bật/dựng lại view; xoá thư mục view không làm dừng Drive |
| T40 | Trash thư mục tháng khi app đang chạy → phát hiện ở lần ghi kế; "Khôi phục giúp tôi" |
| T41 | Hai instance → instance sau thoát |
| T42 | Tên tiếng Việt rất dài trên SMB → cắt theo byte |
| T43 | Mac tắt > 1 tuần khi đang upload → kiểm tra ID trước, không tạo file trùng |
 
## 12. Tiêu chí chấp nhận
 
- [ ] Mọi FR hoạt động như mô tả, hoặc có ghi chú lý do trong `docs/decisions/`.
- [ ] T1–T43 đạt.
- [ ] Mọi [VERIFY] có kết luận.
- [ ] Có các điểm mở rộng ở mục 7.
- [ ] Có `docs/sidecar-schema.md`.
- [ ] README: build, Google Cloud, signing, NAS, cấu hình, giới hạn đã biết (`saved` là heuristic; caption/keywords chỉ từ macOS 27; bản edited cũ trên Drive mất sau ~30 ngày; NAS offline thì tải lại; checksum SMB là best-effort; Lightroom và `.xmp`), gỡ cài đặt.
- [ ] Không có secret trong git.
## 13. Mặc định đáng chú ý
 
- Burst: mọi khung. Hidden: không upload.
- Shared Library: có. Shared Albums: không.
- Mỗi loại resource edited tối đa 1 file, cập nhật tại chỗ.
- Thư mục ngày không demote. Placement chốt một lần.
- Không giữ staging chờ đích offline. Quy tắc EXIF chỉ áp dụng cho ảnh.
- View: không có nhóm Unknown. Favorites gồm mọi category. By place chỉ nhánh `camera` có GPS.
- Watermark 15 / 5 GB (chỉnh sau M0-1).
**Câu hỏi mở:** Google One có đủ dung lượng không? (owner tự kiểm tra; app có FR-48)
 
## 14. Quy tắc cho agent
 
- Làm M0 trước, **dừng và báo cáo**.
- [VERIFY] khác spec → ghi `docs/decisions/`, không âm thầm làm khác.
- Không thêm dependency ngoài mục 6 nếu không ghi lý do.
- Code production-grade, không có placeholder `TODO`, có test cho logic lõi.
- Không commit secret, không push, không thao tác ngoài thư mục project.
- **Không bao giờ xoá dữ liệu backup.** Chỉ được phép:
  - thay nội dung edited/sidecar (sidecar chỉ khi chưa bị công cụ khác sửa);
  - sửa nội dung file vừa upload mà checksum lệch;
  - di chuyển file; đổi tên thư mục do app tạo (ngày, root, view);
  - cập nhật `description`/`appProperties`;
  - move/trash **shortcut** của view;
  - untrash item do app tạo khi owner chọn;
  - xoá file `.part` và `.photovault-test` ở local.
- Mỗi milestone: build sạch, test pass, cập nhật README/CHANGELOG, tóm tắt việc đã làm và rủi ro còn lại.
## 15. Để sau bản 1.0
 
- S3-compatible với layout stable `YYYY/MM` (không move), multipart + resume, key không có quyền xoá, Object Lock.
- OneDrive, WebDAV, Immich.
- Nguồn liên tục ngoài Photos (Dropbox, OneDrive, S3, Flickr, Drive của tài khoản Google khác): Photos là nguồn liên tục duy nhất theo quyết định 0029. Cơ chế thêm nguồn được thiết kế trong [continuous-source-extension](../architecture/continuous-source-extension.md) và chưa làm; Google Takeout và Photos Picker cho tài khoản Google khác (quyết định 0024, issue #17). Nhập một lần từ Google Drive và Dropbox đã làm (quyết định 0026).
- Mã hoá phía client.
- View `Albums`.
- Layout gom sự kiện/chuyến đi.
- Tool khôi phục về Photos.
- Rule chọn lọc nâng cao.
- Di chuyển file khi owner sửa ngày.
- Heartbeat/Telegram.
- Gợi ý giải phóng iCloud.
- View cho NAS.
 
